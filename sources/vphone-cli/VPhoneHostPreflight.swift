import ArgumentParser
import Foundation
import VPhoneCore

/// The launch gate shared by direct boot and VM-library boot. It checks the
/// entitled companion itself, so an unentitled CLI starting successfully does
/// not give a false positive.
enum VPhoneHostPreflight {
    static func check() throws -> VPhoneGuestLaunchPlanner {
        let probe = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "kern.hv_vmm_present"],
        )
        if probe.succeeded,
           probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        {
            throw ValidationError("Nested virtualization is unavailable for this VM")
        }
        return try VPhoneGuestLaunchPlanner()
    }
}

struct VPhoneHostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        subcommands: [VPhoneHostPreflightCommand.self],
    )
}

struct VPhoneHostPreflightCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preflight",
        abstract: "Check whether the entitled VM binary can launch on this host",
    )

    @Flag(help: "Suppress the success message") var quiet = false

    func run() throws {
        _ = try VPhoneHostPreflight.check()
        if !quiet {
            print("Host preflight passed: vphone-vm can launch")
        }
    }
}
