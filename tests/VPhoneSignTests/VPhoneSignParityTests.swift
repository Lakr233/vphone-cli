import Foundation
import Testing
@testable import VPhoneSign

/// The hard gate: what this signer writes and what `ldid` writes are the
/// same bytes.
///
/// Byte equality is the bar rather than "the signature verifies" because the
/// signature's own size lands in the load commands, which are hashed — one
/// byte of slack more than ldid reserves and every CDHash is different. It
/// is also the only bar that carries: the device this signs for runs an AMFI
/// this project patched, and what that accepts cannot be re-derived from
/// first principles. It accepts ldid's bytes.
@Suite("VPhoneSign is byte-identical to ldid")
struct VPhoneSignParityTests {
    private var ldid: URL {
        get throws {
            try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed; install ldid-procursus to run the parity gate")
        }
    }

    // MARK: - Ad-hoc, which is nearly every call

    @Test("ldid -S")
    func adHoc() throws {
        let ldid = try ldid
        let corpus = VPhoneSignLdidHarness.corpus
        // a corpus that shrank to nothing would make every one of these pass
        #expect(corpus.count >= 10, "only \(corpus.count) files: too few to say anything")
        #expect(
            corpus.contains { (try? Data(contentsOf: $0).prefix(4)) == Data([0xCA, 0xFE, 0xBA, 0xBE]) },
            "no fat binary in the corpus"
        )
        for source in corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S", theirs.path])
            #expect(result.status == 0, "ldid -S \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(identifier: name))

            let left = try Data(contentsOf: theirs), right = try Data(contentsOf: ours)
            #expect(left == right, "\(name): \(VPhoneSignLdidHarness.difference(left, right))")
        }
    }

    // MARK: - Entitlements

    @Test("ldid -S<entitlements>")
    func entitlements() throws {
        let ldid = try ldid
        for source in VPhoneSignLdidHarness.corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let plist = directory.appendingPathComponent("entitlements.plist")
            try Self.sampleEntitlements.write(to: plist)

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S\(plist.path)", theirs.path])
            #expect(result.status == 0, "ldid -S<ent> \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(
                identifier: name, entitlements: Self.sampleEntitlements
            ))

            let left = try Data(contentsOf: theirs), right = try Data(contentsOf: ours)
            #expect(left == right, "\(name): \(VPhoneSignLdidHarness.difference(left, right))")
        }
    }

    /// `-M` over a list written for the occasion, so that the merge itself is
    /// pinned: a key replaced where it stood and a key appended after it,
    /// which a system binary's own entitlements cannot be relied on to
    /// contain. The unseeded case — a binary's own list, which is what the
    /// installers actually merge over — is `mergedWithoutAFile` and
    /// `mergedOverOwnEntitlements`.
    @Test("ldid -S<entitlements> -M over a seeded signature")
    func merged() throws {
        let ldid = try ldid
        for source in VPhoneSignLdidHarness.corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            // give the file entitlements to merge over, with ldid, so the
            // starting point is not this signer's own work
            let seed = directory.appendingPathComponent("seed.plist")
            try Self.seedEntitlements.write(to: seed)
            let seeded = try VPhoneSignLdidHarness.copy(source, into: directory, as: "seeded-\(name)")
            _ = try VPhoneSignLdidHarness.run(ldid, ["-S\(seed.path)", seeded.path])

            let plist = directory.appendingPathComponent("entitlements.plist")
            try Self.sampleEntitlements.write(to: plist)

            let theirs = try VPhoneSignLdidHarness.copy(seeded, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S\(plist.path)", "-M", theirs.path])
            #expect(result.status == 0, "ldid -S<ent> -M \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(seeded, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(
                identifier: name, entitlements: Self.sampleEntitlements, mergesExisting: true
            ))

            let left = try Data(contentsOf: theirs), right = try Data(contentsOf: ours)
            #expect(left == right, "\(name): \(VPhoneSignLdidHarness.difference(left, right))")
        }
    }

    /// `ldid_sign` in `cfw_install*.sh` is `-S -M` with no entitlements file
    /// at all: whatever the binary already had is re-serialised and kept.
    ///
    /// The file is signed as it came off disk, with no fixture written over
    /// it first. That is the whole point. Seeding a binary with an
    /// author-written plist makes the merge input a list this signer is
    /// already known to read, which is how twenty-eight green tests once sat
    /// beside a production path that aborted on `/usr/sbin/spindump` — its
    /// `<integer>0</integer>` was a shape the fixtures never had. What the
    /// firmware's own binaries carry is the only input this has to survive.
    @Test("ldid -S -M over a binary's own entitlements, which is what cfw_install calls")
    func mergedWithoutAFile() throws {
        let ldid = try ldid
        var merged = 0
        for source in VPhoneSignLdidHarness.corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S", "-M", theirs.path])
            #expect(result.status == 0, "ldid -S -M \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(identifier: name, mergesExisting: true))

            let left = try Data(contentsOf: theirs), right = try Data(contentsOf: ours)
            #expect(left == right, "\(name): \(VPhoneSignLdidHarness.difference(left, right))")
            if try VPhoneSigner.entitlements(ofFileAt: source, usesExternalLdid: false).isEmpty == false {
                merged += 1
            }
        }
        // a corpus of files with no entitlements merges nothing and passes
        #expect(merged >= 8, "only \(merged) files carried entitlements to merge")
    }

    /// The same, with an entitlements file on top: `ldid -S<ent> -M <file>`
    /// over what the binary already carried, which is what the installers
    /// run when they add a key rather than only re-sign.
    @Test("ldid -S<entitlements> -M over a binary's own entitlements")
    func mergedOverOwnEntitlements() throws {
        let ldid = try ldid
        var merged = 0
        for path in VPhoneSignLdidHarness.carryingEntitlements
            where FileManager.default.fileExists(atPath: path)
        {
            merged += 1
            let source = URL(fileURLWithPath: path)
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let plist = directory.appendingPathComponent("entitlements.plist")
            try Self.sampleEntitlements.write(to: plist)

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S\(plist.path)", "-M", theirs.path])
            #expect(result.status == 0, "ldid -S<ent> -M \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(
                identifier: name, entitlements: Self.sampleEntitlements, mergesExisting: true
            ))

            let left = try Data(contentsOf: theirs), right = try Data(contentsOf: ours)
            #expect(left == right, "\(name): \(VPhoneSignLdidHarness.difference(left, right))")
        }
        // Without this the loop body can never run — every path missing on
        // some future macOS — and the test passes having compared nothing.
        // Its sibling `mergedWithoutAFile` carries the same guard.
        #expect(merged >= 8, "only \(merged) of the entitlement-carrying binaries exist here")
    }

    /// `-I`, which a handful of call sites use to sign under an Apple
    /// identifier (`com.apple.seputil` and friends) rather than the file's
    /// name.
    @Test("ldid -I<identifier>")
    func explicitIdentifier() throws {
        let ldid = try ldid
        for source in VPhoneSignLdidHarness.corpus.prefix(4) {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S", "-Icom.apple.seputil", theirs.path])
            #expect(result.status == 0, "ldid -I \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(identifier: "com.apple.seputil"))

            let left = try Data(contentsOf: theirs), right = try Data(contentsOf: ours)
            #expect(left == right, "\(name): \(VPhoneSignLdidHarness.difference(left, right))")
        }
    }

    /// Signing twice must land on the same bytes, or a rebuild of the CFW
    /// would produce a different image every time.
    @Test("signing an already-signed file is idempotent")
    func idempotent() throws {
        for source in VPhoneSignLdidHarness.corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let file = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let once = try VPhoneSigner.sign(fileAt: file, options: .init(identifier: name))
            let twice = try VPhoneSigner.sign(fileAt: file, options: .init(identifier: name))
            #expect(once == twice, "\(name): \(VPhoneSignLdidHarness.difference(once, twice))")
        }
    }

    // MARK: - Fixtures

    /// Covers what the DER and XML writers have to agree with libplist on:
    /// booleans, a nested array of strings, a `<data>` long enough to wrap,
    /// and integers — including the four spellings that the DER and the XML
    /// disagree about. `-1` and `18446744073709551615` are the same eight
    /// bytes in the DER and two different strings in the XML; `0` is one zero
    /// byte and not an empty INTEGER. A fixture whose only integer was `42`
    /// is what let the reader ship taking positive decimals only.
    static let sampleEntitlements = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>platform-application</key>
    \t<true/>
    \t<key>com.apple.private.security.no-sandbox</key>
    \t<true/>
    \t<key>get-task-allow</key>
    \t<true/>
    \t<key>com.apple.private.skip-library-validation</key>
    \t<true/>
    \t<key>com.apple.security.exception.files.absolute-path.read-only</key>
    \t<array>
    \t\t<string>/usr/lib/</string>
    \t\t<string>/System/</string>
    \t</array>
    \t<key>seatbelt-profiles</key>
    \t<data>
    \tAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w
    \tMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9g
    \t</data>
    \t<key>an-integer</key>
    \t<integer>42</integer>
    \t<key>a-zero</key>
    \t<integer>0</integer>
    \t<key>a-negative</key>
    \t<integer>-1</integer>
    \t<key>above-int64-max</key>
    \t<integer>18446744073709551615</integer>
    \t<key>an-array-of-integers</key>
    \t<array>
    \t\t<integer>0</integer>
    \t\t<integer>128</integer>
    \t\t<integer>9223372036854775808</integer>
    \t</array>
    </dict>
    </plist>

    """.utf8)

    /// A different set, so a merge that silently dropped one side would show.
    static let seedEntitlements = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>com.apple.private.cs.debugger</key>
    \t<true/>
    \t<key>an-existing-key</key>
    \t<string>kept</string>
    \t<key>get-task-allow</key>
    \t<false/>
    </dict>
    </plist>

    """.utf8)
}
