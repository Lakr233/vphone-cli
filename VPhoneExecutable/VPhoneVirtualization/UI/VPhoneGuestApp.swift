import AppKit
import Foundation
import VPhoneCoreKit

/// The kit's entry point: turn parsed boot options into a running guest.
///
/// This exists so `vphone-vm`'s `main.swift` stays a parse and a call. The
/// NSApplication wiring is an implementation detail of running a guest, not
/// something an entry point should be spelling out, and keeping it here means
/// `VPhoneVirtualMachineAppDelegate` does not have to be public — which in turn keeps every
/// `NSApplicationDelegate` method it implements internal.
public enum VPhoneGuestApp {
    /// Run the guest. Returns only when the application terminates.
    ///
    /// `@MainActor` because NSApplication is: at the top of `main.swift` that
    /// isolation was implicit, and moving the code into a function loses it.
    @MainActor
    public static func run(_ boot: VPhoneBootCommand) -> Never {
        let app = NSApplication.shared
        let delegate = VPhoneVirtualMachineAppDelegate(command: boot)
        app.delegate = delegate
        app.run()
        // NSApplication.run() does not return through here in practice: the
        // terminate path exits the process. Spelling that out keeps the caller
        // from having to invent a meaningless return value.
        exit(0)
    }
}
