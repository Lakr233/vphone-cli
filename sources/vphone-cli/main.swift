import AppKit
import ArgumentParser
import Foundation

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    default:
        var command = command
        try command.run()
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
