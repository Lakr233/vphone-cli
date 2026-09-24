// vphone-vm — the process that actually runs a guest.
//
// This is the only binary in the project signed with the private
// virtualization entitlements (Resources/VPhoneVirtualization.entitlements), and it is
// deliberately the smallest thing that can hold them: it parses the boot
// options, becomes an NSApplication, and hands off to VPhoneVirtualMachineAppDelegate.
// The unentitled vphone-cli starts this process for the boot.
//
// It takes the boot options directly rather than a `boot` subcommand — this
// binary has exactly one job, so there is nothing to select between.

import ArgumentParser
import VPhoneCoreKit
import VPhoneVirtualMachineKit

VPhoneGuestApp.run(VPhoneBootCommand.parseOrExit())
