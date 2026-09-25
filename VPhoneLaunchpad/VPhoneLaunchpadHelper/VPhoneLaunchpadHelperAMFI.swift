import Darwin
import Foundation

/// The only AMFI operation exposed by the root helper. The client supplies a
/// version, never a path or command line. Both executables come from the
/// root-owned, receipt-verified bundle store.
enum VPhoneLaunchpadHelperAMFI {
    private static let lock = NSLock()

    static func allow(bundleVersion: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try VPhoneLaunchpadHostPolicy.requireReady()

        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(bundleVersion),
              let receipt = VPhoneLaunchpadBundleReceipt.load(version: bundleVersion)
        else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle \(bundleVersion) is not installed. Reinstall it, then try again.")
        }

        let bundle = VPhoneLaunchpadBundleStore.bundle(version: bundleVersion)
        let vm = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-vm")
        let escalator = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-escalator")
        try VPhoneLaunchpadHelperCodeCheck.requireValidBundle(bundle)
        try VPhoneLaunchpadHelperCodeCheck.requireCDHash(vm, receipt.cdhashes["vphone-vm"])

        var info = stat()
        guard lstat(escalator.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              info.st_mode & 0o022 == 0
        else {
            throw VPhoneLaunchpadHelperError("vphone-escalator is missing or is not root-owned. Reinstall VPhone.bundle.")
        }

        let process = Process()
        process.executableURL = escalator
        process.arguments = ["allow", vm.path]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw VPhoneLaunchpadHelperError("Unable to start vphone-escalator: \(error.localizedDescription)")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw VPhoneLaunchpadHelperError(text.isEmpty ? "vphone-escalator failed. Check the host's SIP settings." : text)
        }
    }
}
