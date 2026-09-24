// VPhoneFWAEACLI.swift — `fw aea-key` and the two `fw im4p` verbs.
//
// These are the shapes `ipsw` was called in from the CFW installers and from
// fw_prepare.sh, and they are the last of them. `ipsw` is a fine program —
// statically linked Go, nothing but system libraries — but it is a program the
// user has to install with Homebrew before a .app that is supposed to be
// self-contained can finish a job, which is the thing `make check-aux` exists
// to stop.
//
//     ipsw fw aea --key <f>                       ->  vphone-cli fw aea-key <f>
//     ipsw img4 im4p create --type T --version V  ->  vphone-cli fw im4p-create
//     ipsw img4 im4p extract --output O <f>       ->  vphone-cli fw im4p-extract

import ArgumentParser
import FirmwarePatcher
import Foundation
import Img4tool
import VPhoneCore

// MARK: - aea-key

struct VPhoneFWAEAKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aea-key",
        abstract: "Print an .aea archive's symmetric key (replaces `ipsw fw aea --key`)",
        discussion: """
        Prints `base64:…`, which is what `aea decrypt -key-value` takes, and
        what the installers already pipe it into.

        This makes one network request, to the wkms-public.apple.com URL the
        archive itself names. There is no offline path: the key is not in the
        file, by design. Fetching it is what `ipsw fw aea --key` did too.
        """,
    )

    @Argument(help: "The .aea archive", transform: URL.init(fileURLWithPath:))
    var file: URL

    /// Not `AsyncParsableCommand`: this command tree is dispatched synchronously
    /// from main.swift, and an async `run()` there is never called — the default
    /// synchronous one is, which prints help and exits zero. That failure is
    /// silent, so the one await is bridged here instead.
    func run() throws {
        try print(vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: file) })
    }
}

// MARK: - im4p

struct VPhoneFWIM4PCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "im4p-create",
        abstract: "Wrap a file in an IM4P container (replaces `ipsw img4 im4p create`)",
        discussion: """
        --version is the container's description string, which is what ipsw put
        there: `--version 0` writes the one-character description "0". It is not
        a format version, and it is not optional — an IM4P with an empty
        description is not valid.
        """,
    )

    @Argument(help: "The payload to wrap", transform: URL.init(fileURLWithPath:))
    var file: URL

    @Option(name: .customLong("type"), help: "Four-character type code, e.g. isys, trst, msys")
    var fourcc: String

    @Option(name: .customLong("version"), help: "Description string")
    var version: String

    @Option(name: .shortAndLong, help: "Where to write it", transform: URL.init(fileURLWithPath:))
    var output: URL

    func run() throws {
        let im4p = try IM4P(
            fourcc: fourcc, description: version,
            payload: Data(contentsOf: file, options: .mappedIfSafe),
        )
        try im4p.data.write(to: output)
    }
}

struct VPhoneFWIM4PExtractCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "im4p-extract",
        abstract: "Unwrap an IM4P's payload (replaces `ipsw img4 im4p extract`)",
    )

    @Argument(help: "The IM4P container", transform: URL.init(fileURLWithPath:))
    var file: URL

    @Option(name: .customLong("output"), help: "Where to write the payload",
            transform: URL.init(fileURLWithPath:))
    var output: URL

    func run() throws {
        try IM4PHandler.load(contentsOf: file).payload.write(to: output)
    }
}
