import Darwin
import Foundation

@main
struct HostPolicyTests {
    static func expectDenied(_ text: String, operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Expected host policy rejection: \(text)")
        } catch let error as VPhoneLaunchpadHostPolicyError {
            precondition(error.message.contains(text), "Unexpected rejection: \(error.message)")
        } catch {
            fatalError("Unexpected error: \(error)")
        }
    }

    static func main() throws {
        // Each required bit independently gates admission. Unrelated policy
        // bits cannot grant admission or invalidate a permitted configuration.
        for configuration in [0, 1 << 12, 1 << 31] as [UInt32] {
            expectDenied("SIP debugging restrictions are enabled") {
                try VPhoneLaunchpadHostPolicy.requireReady(configuration: configuration)
            }
        }
        for configuration in [1 << 2, (1 << 2) | (1 << 31)] as [UInt32] {
            expectDenied("Research Guests are disabled") {
                try VPhoneLaunchpadHostPolicy.requireReady(configuration: configuration)
            }
        }
        for configuration in [0x1004, 0x1005, UInt32.max] as [UInt32] {
            try VPhoneLaunchpadHostPolicy.requireReady(configuration: configuration)
        }

        let ready: VPhoneLaunchpadHostPolicy.CSRQuery = {
            $0.pointee = 0x1004
            return 0
        }
        let configuration = try VPhoneLaunchpadHostPolicy.activeConfiguration(query: ready)
        precondition(configuration == 0x1004)
        try VPhoneLaunchpadHostPolicy.requireReady(configuration: configuration)

        expectDenied("csr_get_active_config is unavailable") {
            try VPhoneLaunchpadHostPolicy.requireReady(
                configuration: VPhoneLaunchpadHostPolicy.activeConfiguration(query: nil),
            )
        }
        let failed: VPhoneLaunchpadHostPolicy.CSRQuery = {
            // A failed call cannot grant permission even if it filled the
            // output with an otherwise permitted configuration.
            $0.pointee = 0x1004
            errno = EIO
            return -1
        }
        expectDenied("csr_get_active_config failed (status -1, errno \(EIO))") {
            try VPhoneLaunchpadHostPolicy.requireReady(
                configuration: VPhoneLaunchpadHostPolicy.activeConfiguration(query: failed),
            )
        }
        print("Host policy tests passed: required bits, unrelated bits, missing symbol, query failure")

        if CommandLine.arguments.dropFirst().contains("--live") {
            let current = try VPhoneLaunchpadHostPolicy.activeConfiguration()
            print(String(format: "Current host CSR configuration: 0x%08x", current))
            try VPhoneLaunchpadHostPolicy.requireReady()
            print("Current host policy permits admission")
        }
    }
}
