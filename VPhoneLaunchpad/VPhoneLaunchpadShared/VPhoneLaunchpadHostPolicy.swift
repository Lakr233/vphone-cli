import Darwin
import Foundation

/// Host settings needed before admitting the private-entitlement VM binary.
/// Shared by the app's preflight and the root helper so an XPC caller cannot
/// bypass the check.
nonisolated enum VPhoneLaunchpadHostPolicy {
    typealias CSRQuery = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32

    static func requireReady() throws {
        try requireReady(configuration: activeConfiguration())
    }

    static func requireReady(configuration: UInt32) throws {
        // XNU bsd/sys/csr.h: CSR_ALLOW_TASK_FOR_PID and CSR_ALLOW_RESEARCH_GUESTS.
        guard configuration & (1 << 2) != 0 else {
            throw VPhoneLaunchpadHostPolicyError(
                "SIP debugging restrictions are enabled. In macOS Recovery, run csrutil enable --without debug, then reboot.",
            )
        }

        guard configuration & (1 << 12) != 0 else {
            throw VPhoneLaunchpadHostPolicyError(
                "Research Guests are disabled. In macOS Recovery, run csrutil allow-research-guests enable, then reboot.",
            )
        }
    }

    static func activeConfiguration() throws -> UInt32 {
        // The read-only libSystem query returns this running kernel's policy.
        // Unlike csrutil's boot-volume selection, it needs neither an
        // interactive terminal nor administrator privileges on multi-OS Macs.
        guard let library = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw VPhoneLaunchpadHostPolicyError("Unable to check current host security settings: libSystem could not be loaded.")
        }
        defer { dlclose(library) }
        let query = dlsym(library, "csr_get_active_config").map {
            unsafeBitCast($0, to: CSRQuery.self)
        }
        return try activeConfiguration(query: query)
    }

    // Keep the ABI boundary injectable so missing symbols and syscall failures
    // can be tested without altering the host's security configuration.
    static func activeConfiguration(query: CSRQuery?) throws -> UInt32 {
        guard let query else {
            throw VPhoneLaunchpadHostPolicyError("Unable to check current host security settings: csr_get_active_config is unavailable.")
        }
        var configuration: UInt32 = 0
        let status = query(&configuration)
        guard status == 0 else {
            let queryErrno = errno
            throw VPhoneLaunchpadHostPolicyError("Unable to check current host security settings: csr_get_active_config failed (status \(status), errno \(queryErrno)).")
        }
        return configuration
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
