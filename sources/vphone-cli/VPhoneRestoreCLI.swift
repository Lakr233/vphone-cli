import ArgumentParser
import Foundation

struct RestoreGetSHSHCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-get-shsh",
        abstract: "Request restore personalization data with idevicerestore/libirecovery"
    )

    @Argument(help: "VM directory. Defaults to the current directory.", transform: URL.init(fileURLWithPath:))
    var vmDirectory: URL = VPhoneHost.currentDirectoryURL()

    @Option(name: .customLong("ecid"), help: "Optional ECID selector.")
    var ecid: String?

    @Option(name: .customLong("udid"), help: "Optional UDID for logging context.")
    var udid: String?

    mutating func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let normalizedECID = try normalizedECIDValue(ecid ?? env["RESTORE_ECID"])
        let udid = udid ?? env["RESTORE_UDID"]
        let vmDirectory = vmDirectory.standardizedFileURL
        let restoreDirectory = try findRestoreDirectory(in: vmDirectory)
        let shshDirectory = vmDirectory.appendingPathComponent("shsh", isDirectory: true)
        try FileManager.default.createDirectory(at: shshDirectory, withIntermediateDirectories: true)

        print("[*] Requesting personalization data")
        print("    Restore bundle: \(restoreDirectory.path)")
        print("    UDID: \(udid ?? "<unset>")")
        print("    ECID: \(formattedECID(normalizedECID) ?? "<unset>")")

        let ticketURL = try VPhoneRestoreEngine.requestSHSH(
            restoreBundlePath: restoreDirectory.path,
            cacheDirectory: vmDirectory.path,
            udid: udid,
            ecid: normalizedECID
        )
        print("[+] Saved personalization ticket: \(ticketURL.path)")
    }
}

struct RestoreDeviceCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-device",
        abstract: "Restore firmware with idevicerestore/libirecovery"
    )

    @Argument(help: "VM directory. Defaults to the current directory.", transform: URL.init(fileURLWithPath:))
    var vmDirectory: URL = VPhoneHost.currentDirectoryURL()

    @Option(name: .customLong("ecid"), help: "Optional ECID selector.")
    var ecid: String?

    @Option(name: .customLong("udid"), help: "Optional UDID for logging context.")
    var udid: String?

    mutating func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let normalizedECID = try normalizedECIDValue(ecid ?? env["RESTORE_ECID"])
        let udid = udid ?? env["RESTORE_UDID"]
        let vmDirectory = vmDirectory.standardizedFileURL
        let restoreDirectory = try findRestoreDirectory(in: vmDirectory)
        print("[*] Starting DFU restore")
        print("    Restore bundle: \(restoreDirectory.path)")
        print("    SHSH cache: \(vmDirectory.appendingPathComponent("shsh", isDirectory: true).path)")
        print("    UDID: \(udid ?? "<unset>")")
        print("    ECID: \(formattedECID(normalizedECID) ?? "<unset>")")

        try VPhoneRestoreEngine.restore(
            restoreBundlePath: restoreDirectory.path,
            cacheDirectory: vmDirectory.path,
            udid: udid,
            ecid: normalizedECID
        )
        print("[+] Restore submitted successfully")
    }
}

private extension RestoreGetSHSHCLI {
    func normalizedECIDValue(_ rawValue: String?) throws -> UInt64? {
        try RestoreCLIHelpers.normalizedECIDValue(rawValue)
    }

    func findRestoreDirectory(in vmDirectory: URL) throws -> URL {
        try RestoreCLIHelpers.findRestoreDirectory(in: vmDirectory)
    }

    func formattedECID(_ ecid: UInt64?) -> String? {
        RestoreCLIHelpers.formattedECID(ecid)
    }
}

private extension RestoreDeviceCLI {
    func normalizedECIDValue(_ rawValue: String?) throws -> UInt64? {
        try RestoreCLIHelpers.normalizedECIDValue(rawValue)
    }

    func findRestoreDirectory(in vmDirectory: URL) throws -> URL {
        try RestoreCLIHelpers.findRestoreDirectory(in: vmDirectory)
    }

    func formattedECID(_ ecid: UInt64?) -> String? {
        RestoreCLIHelpers.formattedECID(ecid)
    }
}

private enum RestoreCLIHelpers {
    static func normalizedECIDValue(_ rawValue: String?) throws -> UInt64? {
        guard var rawValue, !rawValue.isEmpty else {
            return nil
        }
        rawValue = rawValue.replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
        guard rawValue.range(of: #"^[0-9A-Fa-f]{1,16}$"#, options: .regularExpression) != nil else {
            throw ValidationError("Invalid ECID: \(rawValue)")
        }
        guard let ecid = UInt64(rawValue, radix: 16) else {
            throw ValidationError("Invalid ECID: \(rawValue)")
        }
        return ecid
    }

    static func findRestoreDirectory(in vmDirectory: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(at: vmDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        guard let restoreDirectory = try entries.first(where: { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true && url.lastPathComponent.contains("Restore")
        }) else {
            throw ValidationError("No *Restore* directory found in \(vmDirectory.path)")
        }
        return restoreDirectory
    }

    static func formattedECID(_ ecid: UInt64?) -> String? {
        guard let ecid else {
            return nil
        }
        return "0x\(String(ecid, radix: 16).uppercased())"
    }
}
