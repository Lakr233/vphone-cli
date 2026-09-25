import Darwin
import Foundation
import IcliSystem

// MARK: - vphone Environment

/// The environment update keeps the libraries cfw install placed in /usr/lib
/// in step with the host bundle. The host uploads each changed library to
/// the staging directory, then asks for the set to be installed.
extension GuestAPI {
    /// Must match `VPhoneGuestEnvironment.libraries` on the host.
    static let environmentLibraries = [
        "launchdhook-vphone.dylib",
        "SystemHook-vphone.dylib",
        "libvcamcaptured.dylib",
        "libcamfix.dylib",
        "libvlocation.dylib",
    ]
    static let environmentStaging = "/var/root/Library/Caches/vphone-environment"

    static func executeEnvironment(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "environment.status":
            var root = statfs()
            guard statfs("/", &root) == 0 else {
                throw GuestAPIError.operationFailed("statfs(/): \(String(cString: strerror(errno)))")
            }
            let libraries = environmentLibraries.map { name -> [String: Any] in
                let data = try? Data(contentsOf: URL(fileURLWithPath: "/usr/lib/" + name), options: .mappedIfSafe)
                return ["name": name, "sha256": data.map(sha256Hex) ?? NSNull()]
            }
            return [
                "libraries": libraries,
                "staging": environmentStaging,
                "root_read_only": root.f_flags & UInt32(MNT_RDONLY) != 0,
            ]
        case "environment.install":
            return try installEnvironment(params)
        default:
            return nil
        }
    }

    private static func installEnvironment(_ params: [String: Any]) throws -> [String: Any] {
        guard let requested = params["libraries"] as? [[String: Any]], !requested.isEmpty else {
            throw GuestAPIError.invalidRequest("libraries must list the uploaded libraries")
        }
        var names: [String] = []
        for entry in requested {
            let name = try string(entry, "name")
            guard environmentLibraries.contains(name) else {
                throw GuestAPIError.invalidRequest("\(name) is not part of the vphone environment")
            }
            let staged = URL(fileURLWithPath: environmentStaging + "/" + name)
            guard let data = try? Data(contentsOf: staged, options: .mappedIfSafe) else {
                throw GuestAPIError.invalidRequest("Upload \(name) to \(environmentStaging) first")
            }
            guard try sha256Hex(data) == string(entry, "sha256") else {
                throw GuestAPIError.invalidRequest("\(name) does not match its SHA-256")
            }
            names.append(name)
        }

        let rootReadOnly = try withWritableRoot {
            for name in names {
                try installLibrary(from: environmentStaging + "/" + name, to: "/usr/lib/" + name)
            }
        }
        for name in names {
            unlink(environmentStaging + "/" + name)
        }

        // SystemHook loads the camera daemon hook when cameracaptured starts.
        // launchd starts it again for the next camera client.
        var restarted: [Int] = []
        if names.contains("libvcamcaptured.dylib") || names.contains("SystemHook-vphone.dylib") {
            restarted = stopProcesses(named: "cameracaptured")
        }
        return [
            "installed": names,
            "restarted_pids": restarted,
            // launchd loaded its hook at boot and keeps the old copy mapped.
            "reboot_required": !rootReadOnly || names.contains("launchdhook-vphone.dylib"),
            "root_read_only": rootReadOnly,
        ]
    }

    /// Runs `body` with `/` writable, then tries to restore read-only state.
    /// Some APFS guests reject a live read-only remount; the caller must then
    /// request a reboot so jailbreak detection does not keep seeing rootful.
    private static func withWritableRoot(_ body: () throws -> Void) throws -> Bool {
        var root = statfs()
        guard statfs("/", &root) == 0 else {
            throw GuestAPIError.operationFailed("statfs(/): \(String(cString: strerror(errno)))")
        }
        if root.f_flags & UInt32(MNT_RDONLY) != 0 {
            try remountRoot("-w")
        }
        let result = Result { try body() }
        let rootReadOnly: Bool
        do {
            try remountRoot("-r")
            rootReadOnly = true
        } catch {
            NSLog("[environment] root remains writable until reboot: %@", String(describing: error))
            rootReadOnly = false
        }
        try result.get()
        return rootReadOnly
    }

    /// `mode` is `-w` for read-write or `-r` for read-only.
    private static func remountRoot(_ mode: String) throws {
        let arguments = ["/sbin/mount", "-u", mode, "/"]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else {
            throw GuestAPIError.operationFailed("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, errorPipe[0])
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, nil, &argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        close(errorPipe[1])
        guard spawned == 0 else {
            close(errorPipe[0])
            throw GuestAPIError.operationFailed("mount -u \(mode) /: \(String(cString: strerror(spawned)))")
        }
        var errorText = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while errorText.count < 4096 {
            let count = read(errorPipe[0], &buffer, min(buffer.count, 4096 - errorText.count))
            if count <= 0 { break }
            errorText.append(contentsOf: buffer.prefix(count))
        }
        close(errorPipe[0])
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid, status == 0 else {
            let details = String(data: errorText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GuestAPIError.operationFailed("mount -u \(mode) / exited with status \(status): \(details)")
        }
    }

    /// Copies onto the system volume first, so the rename that replaces the
    /// library is atomic. Running processes keep the copy they mapped.
    private static func installLibrary(from source: String, to destination: String) throws {
        let temporary = destination + ".vphoned-" + UUID().uuidString
        try FileManager.default.copyItem(atPath: source, toPath: temporary)
        guard chown(temporary, 0, 0) == 0, chmod(temporary, 0o755) == 0, rename(temporary, destination) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw GuestAPIError.operationFailed("Could not install \(destination): \(reason)")
        }
    }

    private static func stopProcesses(named name: String) -> [Int] {
        let rows = (try? listProcesses(filter: name))?["processes"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row["name"] as? String == name, let pid = row["pid"] as? Int, kill(pid_t(pid), SIGTERM) == 0
            else { return nil }
            return pid
        }
    }
}
