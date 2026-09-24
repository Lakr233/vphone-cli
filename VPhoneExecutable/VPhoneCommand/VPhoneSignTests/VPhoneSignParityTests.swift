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
///
/// ldid is not run here. Every expectation is a digest frozen in
/// `VPhoneSignFixtures`, taken from the real ldid over the committed fixtures;
/// the header of that file says how to re-derive them and why they are frozen
/// rather than compared live.
@Suite("VPhoneSign is byte-identical to ldid")
struct VPhoneSignParityTests {
    // MARK: - Ad-hoc, which is nearly every call

    @Test
    func `ldid -S`() throws {
        let corpus = try VPhoneSignFixtures.fixtures
        // a corpus that shrank to nothing would make every one of these pass
        #expect(corpus.count >= 12, "only \(corpus.count) fixtures: too few to say anything")
        #expect(
            corpus.contains { (try? Data(contentsOf: $0).prefix(4)) == Data([0xCA, 0xFE, 0xBA, 0xBE]) },
            "no fat binary in the corpus",
        )
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let ours = try VPhoneSignFixtures.sign(source, in: directory)
            try VPhoneSignFixtures.expect("\(name).adhoc", matches: Data(contentsOf: ours))
        }
    }

    // MARK: - Entitlements

    @Test
    func `ldid -S<entitlements>`() throws {
        let corpus = try VPhoneSignFixtures.fixtures
        #expect(corpus.count >= 12, "only \(corpus.count) fixtures: too few to say anything")
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let ours = try VPhoneSignFixtures.sign(
                source,
                in: directory,
                entitlements: Self.sampleEntitlements,
            )
            try VPhoneSignFixtures.expect("\(name).entitlements", matches: Data(contentsOf: ours))
        }
    }

    /// `-M` over a signature this signer did not write.
    ///
    /// The seeded fixtures arrive already signed by ldid, each carrying one
    /// real daemon's real entitlements, so the merge's starting point is
    /// nothing anybody here composed. The five `hello-*` files carry none,
    /// which is the other half of the claim: over them the merge has to be a
    /// no-op and land exactly where `ldid -S<ent>` lands.
    @Test
    func `ldid -S<entitlements> -M over a seeded signature`() throws {
        let corpus = try VPhoneSignFixtures.fixtures
        #expect(corpus.count >= 12, "only \(corpus.count) fixtures: too few to say anything")
        var seeded = 0
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            if try VPhoneSigner.entitlements(ofFileAt: source).contains(where: { !$0.isEmpty }) {
                seeded += 1
            }

            let ours = try VPhoneSignFixtures.sign(
                source,
                in: directory,
                entitlements: Self.sampleEntitlements,
                mergesExisting: true,
            )
            try VPhoneSignFixtures.expect("\(name).mergeSample", matches: Data(contentsOf: ours))
        }
        // a corpus of files with nothing to merge merges nothing and passes
        #expect(seeded >= 7, "only \(seeded) fixtures arrived carrying entitlements to merge over")
    }

    /// `ldid_sign` in `cfw_install*.sh` is `-S -M` with no entitlements file
    /// at all: whatever the binary already had is re-serialised and kept.
    ///
    /// The merge input is entitlement XML nobody here wrote. That is the whole
    /// point, and it is why the seeded fixtures carry seven real daemons'
    /// lists rather than something composed for the occasion. Seeding a binary
    /// with an author-written plist makes the merge input a list this signer is
    /// already known to read, which is how twenty-eight green tests once sat
    /// beside a production path that aborted on `/usr/sbin/spindump` — its
    /// `com.apple.trial.status.deployment-environment.allow` is
    /// `<array><integer>0</integer></array>`, and `<integer>0</integer>` was a
    /// shape the fixtures never had. `seeded-spindump` carries that array now,
    /// `seeded-promotedcontentd` a value above `Int32.max`,
    /// `seeded-runningboardd` two different ones and
    /// `seeded-sysdiagnose_helper` six.
    @Test
    func `ldid -S -M over a binary's own entitlements, which is what cfw_install calls`() throws {
        let corpus = try VPhoneSignFixtures.fixtures
        #expect(corpus.count >= 12, "only \(corpus.count) fixtures: too few to say anything")
        var merged = 0
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let carries = try VPhoneSigner.entitlements(ofFileAt: source).contains { !$0.isEmpty }
            if carries {
                merged += 1
            }

            let ours = try VPhoneSignFixtures.sign(source, in: directory, mergesExisting: true)
            try VPhoneSignFixtures.expect("\(name).mergeOwn", matches: Data(contentsOf: ours))

            // and where there was something to carry across, carrying it
            // across has to have changed the result — otherwise a merge that
            // dropped the existing list would match a frozen digest of nothing
            if carries {
                #expect(
                    VPhoneSignFixtures.expected["\(name).mergeOwn"]
                        != VPhoneSignFixtures.expected["\(name).adhoc"],
                    "\(name): ldid's -S -M and its -S agree, so the merge carried nothing",
                )
            }
        }
        // a corpus of files with no entitlements merges nothing and passes
        #expect(merged >= 7, "only \(merged) files carried entitlements to merge")
    }

    /// The same, with an entitlements file on top: `ldid -S<ent> -M <file>`
    /// over what the binary already carried, which is what the installers
    /// run when they add a key rather than only re-sign.
    ///
    /// It runs over the seeded seven alone, where "the binary's own" means
    /// something. Its sibling `merged` covers the same verb over the whole
    /// corpus; what this adds is the guard that every one of the seven really
    /// did arrive with a list, and that merging over it is not the same as
    /// replacing it.
    @Test
    func `ldid -S<entitlements> -M over a binary's own entitlements`() throws {
        let seeded = try VPhoneSignFixtures.seeded
        // Without this the loop body can never run and the test passes having
        // compared nothing. Its sibling `mergedWithoutAFile` carries the same
        // guard.
        #expect(seeded.count >= 7, "only \(seeded.count) seeded fixtures")
        for source in seeded {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            #expect(
                try VPhoneSigner.entitlements(ofFileAt: source).contains { !$0.isEmpty },
                "\(name) carries no entitlements, so there is nothing here to merge over",
            )

            let ours = try VPhoneSignFixtures.sign(
                source,
                in: directory,
                entitlements: Self.sampleEntitlements,
                mergesExisting: true,
            )
            try VPhoneSignFixtures.expect("\(name).mergeSample", matches: Data(contentsOf: ours))

            // merging is not replacing: ldid's own two answers differ
            #expect(
                VPhoneSignFixtures.expected["\(name).mergeSample"]
                    != VPhoneSignFixtures.expected["\(name).entitlements"],
                "\(name): ldid's -S<ent> -M and its -S<ent> agree, so the merge dropped the existing list",
            )
        }
    }

    /// `-I`, which a handful of call sites use to sign under an Apple
    /// identifier (`com.apple.seputil` and friends) rather than the file's
    /// name.
    @Test
    func `ldid -I<identifier>`() throws {
        let corpus = try VPhoneSignFixtures.fixtures
        #expect(corpus.count >= 12, "only \(corpus.count) fixtures: too few to say anything")
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let ours = try VPhoneSignFixtures.sign(source, in: directory, identifier: "com.apple.seputil")
            try VPhoneSignFixtures.expect("\(name).identifier", matches: Data(contentsOf: ours))
        }
    }

    /// The default `-I`: with no identifier set, `VPhoneSigner.sign(fileAt:)`
    /// takes the file's own name, as ldid does.
    ///
    /// Every assertion in this file pins the identifier through
    /// `VPhoneSignFixtures.sign(_:in:…)`, precisely so that no frozen digest
    /// depends on what a temporary copy was called. That leaves one line of
    /// production logic — `options.identifier ?? url.lastPathComponent` —
    /// covered by nothing, so it is covered here, and structurally: the name
    /// is read back out of the CodeDirectory rather than compared to a digest.
    @Test
    func `an unset identifier defaults to the file's name, as ldid does`() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // deliberately not the fixture's name: the claim is that the signer
        // reads the name off the file it was handed
        let name = "named-for-this-test"
        let file = try VPhoneSignFixtures.copy(
            VPhoneSignFixtures.url("hello-arm64"),
            into: directory,
            as: name,
        )
        try VPhoneSigner.sign(fileAt: file)

        let slices = try VPhoneSignBlobs(fileAt: file).slices
        #expect(!slices.isEmpty, "nothing was signed")
        for (index, slice) in slices.enumerated() {
            let blob = try #require(slice[0], "slice \(index) has no CodeDirectory")
            #expect(VPhoneSignBlobs.identifier(ofCodeDirectory: blob) == name, "slice \(index)")
        }
    }

    /// Signing twice must land on the same bytes, or a rebuild of the CFW
    /// would produce a different image every time.
    @Test
    func `signing an already-signed file is idempotent`() throws {
        for source in try VPhoneSignFixtures.fixtures {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let file = try VPhoneSignFixtures.copy(source, into: directory, as: name)
            let once = try VPhoneSigner.sign(fileAt: file, options: .init(identifier: name))
            let twice = try VPhoneSigner.sign(fileAt: file, options: .init(identifier: name))
            #expect(once == twice, "\(name): \(VPhoneSignFixtures.difference(once, twice))")
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
    ///
    /// These exact bytes are what ldid was given when the `.entitlements` and
    /// `.mergeSample` rows of the frozen table were taken. Changing a
    /// character here invalidates both columns.
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
}
