import ArgumentParser
import Foundation
import VPhoneCommandKit
import VPhoneCoreKit

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
