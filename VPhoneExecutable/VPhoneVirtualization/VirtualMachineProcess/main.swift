// vphone-vm — the process that actually runs a guest.
//
// This is the only binary in the project signed with the private
// virtualization entitlements (Resources/vphone.entitlements), and it is
// deliberately the smallest thing that can hold them: it parses the boot
// options, becomes an NSApplication, and hands off to VPhoneVirtualMachineAppDelegate.
// The unentitled vphone-app launcher and vphone-cli start this process for
// the boot. Neither launcher carries private virtualization entitlements.
//
// It takes the boot options directly rather than a `boot` subcommand — this
// binary has exactly one job, so there is nothing to select between.

import ArgumentParser
import VPhoneCoreKit
import VPhoneVirtualMachineKit

VPhoneGuestApp.run(VPhoneBootCommand.parseOrExit())
