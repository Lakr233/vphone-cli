// VPhoneSignCLI.swift — `sign` and `dump-entitlements`, which replace ldid.
//
// ldid is the one program this project shipped that links Homebrew
// (libcrypto.3, libplist-2.0.4), and so the one thing that failed the
// self-contained admission rule. `VPhoneSign` writes the same bytes out of the
// system frameworks; these two commands are the shape the installers called the
// tool in:
//
//     ldid -S"$ent" -M "-K$p12" -I"$id" <file>   ->  vphone-cli sign …
//     ldid -e <file>                             ->  vphone-cli dump-entitlements
//
// Both keep the `--use-ldid` escape hatch (and the VPHONE_USE_LDID environment
// variable behind it), so a regression is recoverable without a rebuild.

import ArgumentParser
import Foundation
import VPhoneSign

// MARK: - sign

struct VPhoneSignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign a Mach-O the way ldid does (replaces `ldid -S -M -K -I`)",
        discussion: """
        Writes, by default, byte for byte what ldid writes: no CMS blob, no
        ad-hoc flag, and the designated requirement ldid synthesises. That is
        what the guest's AMFI is known to accept, and what every call site in
        this repository has always produced. `codesign --verify` rejects it —
        it rejects ldid's own output too, for the same two reasons. Pass
        --apple-adhoc for a signature in Apple's shape instead, which is what
        `codesign --sign -` writes and what codesign will verify.

        The file is replaced by rename(2) over a temporary beside it, with the
        original mode copied across. That is deliberate: most of what this signs
        came out of an IPSW at mode 444, and renaming over such a file needs
        write permission on the directory, not on the file. An interrupted run
        leaves the original untouched rather than half written.

        --merge is ldid's -M: the entitlements given are merged over whatever
        the file already carries, rather than replacing them. Without it, a
        re-sign silently drops the sandbox profile and private entitlements a
        binary like diskimagesiod cannot run without.
        """
    )

    @Argument(help: "The Mach-O to sign, in place", transform: URL.init(fileURLWithPath:))
    var file: URL

    // Long spellings only, deliberately. ldid's short flags take their value
    // attached (-S"$ent", -K"$p12"), which ArgumentParser reads as an unknown
    // option; offering -S and -K here would invite exactly that call and answer
    // it with a parse error about something else.
    @Option(
        name: .customLong("entitlements"),
        help: "Entitlements plist to embed, as the file holds it",
        transform: URL.init(fileURLWithPath:)
    )
    var entitlements: URL?

    @Option(
        name: .customLong("identifier"),
        help: "Signing identifier. Defaults to the file's name, as ldid does."
    )
    var identifier: String?

    @Flag(name: .customLong("merge"), help: "Merge over the file's existing entitlements")
    var merge = false

    @Option(
        name: .customLong("pkcs12"),
        help: "Sign for real with this .p12 (no password) instead of ad-hoc",
        transform: URL.init(fileURLWithPath:)
    )
    var pkcs12: URL?

    @Flag(
        name: .customLong("apple-adhoc"),
        help: "Write an ad-hoc signature in Apple's shape (codesign --sign -) rather than ldid's"
    )
    var appleAdHoc = false

    @Flag(name: .customLong("use-ldid"), help: "Hand the file to the external ldid instead of signing here")
    var useLdid = false

    func run() throws {
        var options = VPhoneSignOptions()
        options.identifier = identifier
        options.entitlements = try entitlements.map { try Data(contentsOf: $0) }
        options.mergesExisting = merge
        options.style = appleAdHoc ? .appleAdHoc : .ldid
        if let pkcs12 {
            // Both halves, and for different readers: the built-in signer wants
            // the opened identity, and --use-ldid wants the container's path
            // because ldid opens it itself. Setting only one of them is how a
            // real signature used to become a silent ad-hoc downgrade; the
            // external path now throws instead, which only works if the path is
            // here to throw about.
            options.identity = try VPhoneSignIdentity(pkcs12: Data(contentsOf: pkcs12), password: "")
            options.identityPath = pkcs12.path
        }
        // nil, not false: nil lets VPHONE_USE_LDID decide, which is the whole
        // point of the environment variable. Passing false would override it.
        options.usesExternalLdid = useLdid ? true : nil

        try VPhoneSigner.sign(fileAt: file, options: options)
    }
}

// MARK: - dump-entitlements

struct VPhoneDumpEntitlementsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-entitlements",
        abstract: "Print a Mach-O's embedded entitlements (replaces `ldid -e`)",
        discussion: """
        Writes the entitlements of every slice that carries any, in slice order,
        exactly as the signature stores them and with nothing in between —
        which is what `ldid -e` does, and what the installers depend on when
        they redirect this into a plist and feed it back to `sign --merge`.

        A slice with no entitlements contributes nothing, so a file with none at
        all prints nothing and still exits zero.
        """
    )

    @Argument(help: "The Mach-O to read", transform: URL.init(fileURLWithPath:))
    var file: URL

    func run() throws {
        // Raw bytes, not print(): the blob is a plist as the signature stores
        // it, and a trailing newline per slice would be a byte ldid did not
        // write into a file that gets parsed.
        let out = FileHandle.standardOutput
        for blob in try VPhoneSigner.entitlements(ofFileAt: file) {
            out.write(blob)
        }
    }
}
