// vphone-cli — the user-facing entry point.
//
// This binary carries no entitlements at all, which is the whole point: it
// launches normally on any host, so it is always available to explain what is
// wrong and to arrange whatever the actual work needs. The private
// virtualization entitlements live on `vphone-vm`, which this starts as a
// child when a boot is asked for.
//
// Booting used to happen right here — the process parsed `boot` and then
// became the NSApplication itself, which is why the top-level binary had to
// carry the entitlements and could not start without an AMFI bypass already
// running.

import ArgumentParser
import Foundation
import VPhoneCore

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        // `boot` is a request for a guest, not work this process does. Hand it
        // to vphone-vm and report back whatever the guest exits with.
        let status = try VPhoneGuestLaunchPlanner().run(boot.bootArguments)
        if status != 0 {
            throw ExitCode(status)
        }

    default:
        var runnable = command
        try runnable.run()
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
