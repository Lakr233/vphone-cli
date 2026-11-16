import ArgumentParser
import Foundation
import VPhoneCoreKit

/// The launch gate shared by direct boot and VM-library boot. It checks the
/// entitled companion itself, so an unentitled Command starting successfully does
/// not give a false positive.
public enum VPhoneHostPreflight {
    public static func check() throws -> VPhoneGuestLaunchPlanner {
        let probe = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "kern.hv_vmm_present"],
        )
        let nested = probe.succeeded
            && probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        return try check(isNestedHost: nested)
    }

    /// The decision once the host has been probed; tests drive both outcomes.
    static func check(isNestedHost: Bool) throws -> VPhoneGuestLaunchPlanner {
        if isNestedHost {
            throw ValidationError("This Mac is running inside a VM, so vphone-vm cannot start a guest. Run it on a macOS host that is not itself a VM.")
        }
        return try VPhoneGuestLaunchPlanner()
    }
}
