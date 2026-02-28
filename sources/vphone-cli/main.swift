import AppKit
import Foundation

/// Parse CLI arguments before NSApplication starts so that bad-arg errors
/// print cleanly to the terminal without a run loop ever starting.
let cli = VPhoneCLI.parseOrExit()

let app = NSApplication.shared
let delegate = VPhoneAppDelegate(cli: cli)
app.delegate = delegate
app.run()
