// vphone-vm — the process that actually runs a guest.
//
// This is the only binary in the project signed with the private
// virtualization entitlements (sources/vphone.entitlements), and it is
// deliberately the smallest thing that can hold them: it parses the boot
// options, becomes an NSApplication, and hands off to VPhoneAppDelegate.
// Everything a user types goes through vphone-cli, which carries no
// entitlements at all and starts this binary for the boot.
//
// It takes the boot options directly rather than a `boot` subcommand — this
// binary has exactly one job, so there is nothing to select between.

import ArgumentParser
import VPhoneCore
import VPhoneVMKit

VPhoneGuestApp.run(VPhoneBootCLI.parseOrExit())
