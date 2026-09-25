import Foundation

/// Host settings needed before admitting the private-entitlement VM binary.
/// Shared by the app's preflight and the root helper so an XPC caller cannot
/// bypass the check.
nonisolated enum VPhoneLaunchpadHostPolicy {
    static func requireReady() throws {
        let sip = try output(["status"])
        let debuggingDisabled = sip.contains("Debugging Restrictions: disabled")
            || sip.contains("System Integrity Protection status: disabled")
        guard debuggingDisabled else {
            throw VPhoneLaunchpadHostPolicyError(
                "SIP debugging restrictions are enabled. In macOS Recovery, run csrutil enable --without debug, then reboot.",
            )
        }

        let researchGuests = try output(["allow-research-guests", "status"])
        guard researchGuests.contains("Allow Research Guests status: enabled") else {
            throw VPhoneLaunchpadHostPolicyError(
                "Research Guests are disabled. In macOS Recovery, run csrutil allow-research-guests enable, then reboot.",
            )
        }
    }

    private static func output(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw VPhoneLaunchpadHostPolicyError("Unable to check host security settings: \(error.localizedDescription)")
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw VPhoneLaunchpadHostPolicyError("Unable to check host security settings: \(text)")
        }
        return text
    }
}

nonisolated struct VPhoneLaunchpadHostPolicyError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
