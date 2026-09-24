import Darwin
import Foundation

/// Invokes the pinned guest icli binary with an argument vector, never a shell.
/// The caller explicitly opted into the host API via --api-listen.
enum IcliCommand {
    static let queue = DispatchQueue(label: "vphoned.icli.commands", qos: .userInitiated)

    static func execute(_ params: [String: Any]) throws -> [String: Any] {
        guard let arguments = params["argv"] as? [String], !arguments.isEmpty,
              arguments.count <= 64,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 })
        else { throw GuestAPIError.invalidRequest("argv must be 1–64 command arguments") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/icli") else {
            throw GuestAPIError.operationFailed("icli is not installed in this guest image")
        }
        let input: Data
        if let encoded = params["stdin_base64"] as? String {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw GuestAPIError.invalidRequest("stdin_base64 is invalid")
            }
            input = decoded
        } else {
            input = Data((params["stdin"] as? String ?? "").utf8)
        }
        guard input.count <= 1 << 20 else {
            throw GuestAPIError.invalidRequest("stdin exceeds 1 MiB")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphoned-icli-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("stdin")
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        try input.write(to: inputURL)
        let stdinFD = open(inputURL.path, O_RDONLY | O_NOFOLLOW)
        let stdoutFD = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        let stderrFD = open(errorURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard stdinFD >= 0, stdoutFD >= 0, stderrFD >= 0 else {
            if stdinFD >= 0 {
                close(stdinFD)
            }
            if stdoutFD >= 0 {
                close(stdoutFD)
            }
            if stderrFD >= 0 {
                close(stderrFD)
            }
            throw GuestAPIError.operationFailed("Could not prepare icli output")
        }
        defer { close(stdinFD); close(stdoutFD); close(stderrFD) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO)
        var argv = (["/usr/bin/icli"] + arguments).map { strdup($0) as UnsafeMutablePointer<CChar>? }
        argv.append(nil)
        defer { for item in argv {
            if let value = item {
                free(value)
            }
        } }
        var pid: pid_t = 0
        let spawnStatus = argv.withUnsafeMutableBufferPointer { pointer in
            posix_spawn(&pid, "/usr/bin/icli", &actions, nil, pointer.baseAddress, environ)
        }
        guard spawnStatus == 0 else {
            throw GuestAPIError.operationFailed("Could not launch icli (errno \(spawnStatus))")
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                break
            }
            if waited < 0 {
                if errno == EINTR {
                    continue
                }
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                throw GuestAPIError.operationFailed("Could not wait for icli")
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                throw GuestAPIError.operationFailed("icli timed out after 120 seconds")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let stdoutSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        let stderrSize = try FileManager.default.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber
        guard (stdoutSize?.int64Value ?? 0) <= 64 << 20,
              (stderrSize?.int64Value ?? 0) <= 1 << 20
        else {
            throw GuestAPIError.operationFailed("icli output exceeded the API limit")
        }
        let stdout = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let stderr = try Data(contentsOf: errorURL, options: .mappedIfSafe)
        let parsed = try? JSONSerialization.jsonObject(with: stdout, options: [.fragmentsAllowed])
        let code = (status & 0x7F) == 0 ? Int((status >> 8) & 0xFF) : -Int(status & 0x7F)
        return [
            "exit_code": code,
            "output": parsed ?? String(decoding: stdout, as: UTF8.self),
            "stderr": String(decoding: stderr, as: UTF8.self),
        ]
    }
}
