import Foundation

// MARK: - Code Signer

/// Host-side code signing using bundled ldid + signcert.p12.
/// Preserves existing entitlements when re-signing.
@MainActor
class VPhoneSigner {
    private let ldidURL: URL
    private let signcertURL: URL

    init?(bundle: Bundle = .main) {
        guard let execURL = bundle.executableURL else { return nil }
        let macosDir = execURL.deletingLastPathComponent()
        let resourcesDir = macosDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")

        ldidURL = macosDir.appendingPathComponent("ldid")
        signcertURL = resourcesDir.appendingPathComponent("signcert.p12")

        let fm = FileManager.default
        guard fm.fileExists(atPath: ldidURL.path),
              fm.fileExists(atPath: signcertURL.path)
        else { return nil }
    }

    // MARK: - Sign Binary

    /// Re-sign a single Mach-O binary in-memory. Preserves existing entitlements.
    func resign(data: Data, filename: String) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-cli-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let binaryURL = tempDir.appendingPathComponent(filename)
        try data.write(to: binaryURL)

        try await signFile(at: binaryURL, tempDir: tempDir)

        return try Data(contentsOf: binaryURL)
    }

    /// Re-sign a Mach-O binary on disk in-place. Preserves existing entitlements.
    func signFile(at url: URL, tempDir: URL) async throws {
        let entsResult = try await run(ldidURL, arguments: ["-e", url.path])
        let entsXML = entsResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let cert = signcertURL.path

        var args: [String]
        if !entsXML.isEmpty, entsXML.hasPrefix("<?xml") || entsXML.hasPrefix("<!DOCTYPE") {
            let entsFile = tempDir.appendingPathComponent("ents-\(UUID().uuidString).plist")
            try entsXML.write(to: entsFile, atomically: true, encoding: .utf8)
            args = ["-S\(entsFile.path)", "-M", "-K\(cert)", url.path]
        } else {
            args = ["-S", "-M", "-K\(cert)", url.path]
        }

        let result = try await run(ldidURL, arguments: args)
        guard result.status == 0 else {
            throw SignError.ldidFailed(url.lastPathComponent, result.stderr)
        }
        print("[sign] signed \(url.lastPathComponent)")
    }

    // MARK: - Mach-O Detection

    /// Recursively find all Mach-O files in a directory.
    func findMachOFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  Self.isMachO(at: url)
            else { continue }
            results.append(url)
        }
        return results
    }

    static func isMachO(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return magic == 0xFEED_FACF // MH_MAGIC_64
            || magic == 0xCFFA_EDFE // MH_CIGAM_64
            || magic == 0xFEED_FACE // MH_MAGIC
            || magic == 0xCEFA_EDFE // MH_CIGAM
            || magic == 0xCAFE_BABE // FAT_MAGIC
            || magic == 0xBEBA_FECA // FAT_CIGAM
    }

    // MARK: - Process Runner

    struct ProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let execPath = executable.path
        let args = arguments
        let dirPath = currentDirectory?.path

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = args
            if let dirPath {
                process.currentDirectoryURL = URL(fileURLWithPath: dirPath)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return ProcessResult(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                status: process.terminationStatus
            )
        }.value
    }

    // MARK: - Errors

    enum SignError: Error, CustomStringConvertible {
        case ldidFailed(String, String)

        var description: String {
            switch self {
            case let .ldidFailed(file, msg): "failed to sign \(file): \(msg)"
            }
        }
    }
}
