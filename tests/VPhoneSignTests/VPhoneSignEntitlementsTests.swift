import Foundation
import Testing
@testable import VPhoneSign

/// Reading entitlements back, and the two things a signer must not get wrong
/// about them: what libplist would have written, and what it would have
/// refused.
@Suite("Entitlements")
struct VPhoneSignEntitlementsTests {
    // MARK: - Dumping

    /// `ldid -e`, which the installers use a dozen times over to carry a
    /// binary's entitlements across a re-sign. It prints each slice's blob
    /// one after another, so a fat file prints several and a file with none
    /// prints nothing.
    @Test("dump matches ldid -e byte for byte")
    func dumpMatchesLdid() throws {
        let ldid = try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed")
        // the ones with entitlements carry the interesting cases: a long
        // sandbox profile in a <data>, arrays, integers, and several slices
        let corpus = VPhoneSignLdidHarness.carryingEntitlements
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) } + VPhoneSignLdidHarness.corpus
        var withEntitlements = 0
        for source in corpus {
            let theirs = try VPhoneSignLdidHarness.run(ldid, ["-e", source.path]).out
            let ours = try VPhoneSigner.entitlements(ofFileAt: source, usesExternalLdid: false)
                .reduce(Data(), +)
            #expect(theirs == ours, "\(source.lastPathComponent): \(theirs.count) vs \(ours.count) bytes")
            if !theirs.isEmpty { withEntitlements += 1 }
        }
        #expect(withEntitlements > 0, "nothing in the corpus had entitlements, so nothing was compared")
    }

    @Test("a file this signed reads back the entitlements it was given")
    func roundTrip() throws {
        let source = try #require(VPhoneSignLdidHarness.corpus.first)
        let directory = try VPhoneSignLdidHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try VPhoneSignLdidHarness.copy(source, into: directory, as: "binary")
        let plist = VPhoneSignParityTests.sampleEntitlements
        try VPhoneSigner.sign(fileAt: file, options: .init(identifier: "binary", entitlements: plist))

        let read = try VPhoneSigner.entitlements(ofFileAt: file, usesExternalLdid: false)
        let slices = try VPhoneSignBlobs(fileAt: file).slices.count
        #expect(read.count == slices)
        // libplist rewrites the document it was given; what must survive is
        // the list, so it is compared after a parse rather than as bytes
        for blob in read {
            let ours = try PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any]
            let original = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            #expect(NSDictionary(dictionary: ours ?? [:]) == NSDictionary(dictionary: original ?? [:]))
        }
    }

    // MARK: - What the writer must agree with libplist about

    @Test("the XML writer keeps the order libplist keeps, not Foundation's")
    func keepsInsertionOrder() throws {
        // "b" before "a": Foundation would sort them, libplist would not, and
        // the bytes are hashed into the signature
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>zeta</key>
        \t<true/>
        \t<key>alpha</key>
        \t<true/>
        </dict>
        </plist>

        """.utf8)
        let entitlements = try VPhoneSignEntitlements(xml: plist)
        let written = String(decoding: try entitlements.xml(), as: UTF8.self)
        let zeta = try #require(written.range(of: "zeta"))
        let alpha = try #require(written.range(of: "alpha"))
        #expect(zeta.lowerBound < alpha.lowerBound, "the keys were sorted")
    }

    @Test("a merge replaces a key where it stands and appends a new one")
    func mergeKeepsPositions() throws {
        var base = try VPhoneSignEntitlements(xml: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        \t<key>first</key><string>old</string>
        \t<key>second</key><true/>
        </dict></plist>
        """.utf8))
        base.merge(try VPhoneSignEntitlements(xml: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        \t<key>first</key><string>new</string>
        \t<key>third</key><true/>
        </dict></plist>
        """.utf8)))
        #expect(base.entries.map(\.key) == ["first", "second", "third"])
        #expect(base.entries[0].value == .string("new"))
    }

    /// The executable segment flags ldid derives. Getting these wrong is
    /// silent: the binary signs, and then the guest refuses to debug it or
    /// lets it do something it should not.
    @Test("executable segment flags follow the entitlements")
    func executableSegmentFlags() throws {
        let entitlements = try VPhoneSignEntitlements(xml: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        \t<key>get-task-allow</key><true/>
        \t<key>dynamic-codesigning</key><true/>
        \t<key>com.apple.private.amfi.can-execute-cdhash</key><true/>
        </dict></plist>
        """.utf8))
        #expect(entitlements.executableSegmentFlags(mainBinary: true) == 0x1 | 0x10 | 0x40 | 0x100)
        #expect(entitlements.executableSegmentFlags(mainBinary: false) == 0x10 | 0x40 | 0x100)
    }

    // MARK: - <integer>, which is where the reader was wrong

    /// Every spelling of an `<integer>` that ldid takes, compared against the
    /// blobs ldid writes for it rather than against what this signer thinks
    /// it should write.
    ///
    /// This is the test that was missing. The reader used to accept only a
    /// positive decimal, justified by a comment saying ldid's DER "cannot
    /// spell zero or a negative one" — and the suite pinned that in place by
    /// asserting `<integer>0</integer>` must be refused, without ever asking
    /// ldid. ldid spells zero `020100` and minus one `0208ffffffffffffffff`,
    /// and `/usr/sbin/spindump` ships a zero, so the production path failed
    /// on real input while the tests stayed green.
    @Test(
        "every <integer> ldid takes is carried the way ldid carries it",
        arguments: [
            "0", // 020100 — the one that broke spindump
            "-1", // 0208ffffffffffffffff, the same bits as 2^64-1
            "007", // strtoull in base 0: octal, so 7
            "0x10", // and hex, so 16
            "0777", // 511
            "0X1F", // 31
            "+42",
            "-0",
            "-0x10",
            "1",
            "42",
            "128", // one byte with the top bit set, and no DER sign pad
            "256", // two bytes
            "2033844765", // as /usr/libexec/lsd carries it
            "4014732562", // above Int32.max, as promotedcontentd carries it
            "9223372036854775807", // Int64.max
            "-9223372036854775808", // Int64.min
            "9223372036854775808", // above Int64.max: libplist prints it unsigned
            "18446744073709551615", // UInt64.max
            "  42  ", // libplist skips the space around it
        ]
    )
    func integerSpellingsMatchLdid(_ spelling: String) throws {
        let ldid = try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed")
        let source = try #require(VPhoneSignLdidHarness.corpus.first)
        let directory = try VPhoneSignLdidHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>k</key><integer>\(spelling)</integer></dict></plist>
        """.utf8)
        let file = directory.appendingPathComponent("entitlements.plist")
        try plist.write(to: file)

        let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: "binary")
        let result = try VPhoneSignLdidHarness.run(ldid, ["-S\(file.path)", theirs.path])
        #expect(result.status == 0, "ldid refused <integer>\(spelling)</integer>: \(result.error)")

        let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-binary")
        try VPhoneSigner.sign(fileAt: ours, options: .init(identifier: "binary", entitlements: plist))

        // the whole file, since a difference in either blob moves every
        // CDHash with it; the two blobs are then named individually, because
        // the DER drops the sign and the XML keeps it, so a reader that got
        // one right could still have the other wrong
        let whole = try Data(contentsOf: theirs), oursWhole = try Data(contentsOf: ours)
        #expect(
            whole == oursWhole,
            "<integer>\(spelling)</integer>: \(VPhoneSignLdidHarness.difference(whole, oursWhole))"
        )
        let left = try VPhoneSignBlobs(fileAt: theirs), right = try VPhoneSignBlobs(fileAt: ours)
        #expect(left.slices.count == right.slices.count)
        for (index, pair) in zip(left.slices, right.slices).enumerated() {
            // slot 5 is the XML the next `-M` reads back, slot 7 the DER AMFI reads
            for slot in [UInt32(5), 7] {
                #expect(pair.0[slot] != nil, "ldid wrote no slot \(slot)")
                #expect(
                    pair.0[slot] == pair.1[slot],
                    """
                    <integer>\(spelling)</integer> slice \(index) slot \(slot): \
                    \(VPhoneSignLdidHarness.difference(pair.0[slot] ?? Data(), pair.1[slot] ?? Data()))
                    """
                )
            }
        }
    }

    /// A list this signer cannot write back the way libplist would is
    /// refused, rather than signed into something that grants the guest
    /// different things from what the file said.
    ///
    /// ldid refuses both of these itself — `der(plist_t)` answers "Invalid
    /// plist entry type" and exits 1 for `PLIST_REAL` and `PLIST_DATE` — so
    /// the claim is checked against ldid here rather than asserted.
    @Test(
        "what ldid's DER has no room for is refused, as ldid refuses it",
        arguments: ["<date>2020-01-01T00:00:00Z</date>", "<real>1.5</real>"]
    )
    func refusesWhatItCannotCarry(_ value: String) throws {
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>k</key>\(value)</dict></plist>
        """.utf8)
        #expect(throws: VPhoneSignError.self) {
            _ = try VPhoneSignEntitlements(xml: plist)
        }

        let ldid = try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed")
        let source = try #require(VPhoneSignLdidHarness.corpus.first)
        let directory = try VPhoneSignLdidHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("entitlements.plist")
        try plist.write(to: file)
        let binary = try VPhoneSignLdidHarness.copy(source, into: directory, as: "binary")
        let result = try VPhoneSignLdidHarness.run(ldid, ["-S\(file.path)", binary.path])
        #expect(result.status != 0, "ldid accepted \(value), so refusing it is wrong")
    }

    /// The spellings the two libplists read differently.
    ///
    /// Every released libplist — 2.3 through the 2.7 the shipped ldid links —
    /// reads an `<integer>` with `strtoull(str, NULL, 0)` and checks nothing
    /// after it, so it takes each of these and produces a number. libplist's
    /// master branch added the checks that make all of them parse errors.
    /// Refusing is the side that cannot seal a number the next ldid would
    /// have refused to write, and none of these is a shape a real
    /// entitlements list has. `--1` is the odd one out: both libplists read
    /// it as 1, and it is refused anyway because nothing writes it.
    ///
    /// No claim about the installed ldid is made here: it accepts these
    /// today. That is the point of refusing them.
    @Test(
        "an <integer> the two libplists disagree about is refused",
        arguments: [
            "42abc", // released reads 42; master stops on the trailing text
            "abc", // released reads 0
            "", // an empty tag: released reads 0, master refuses it
            "08", // released reads 0 and stops on the 8, octal having no 8
            "99999999999999999999999", // released clamps to ULLONG_MAX on ERANGE
            "-18446744073709551615", // released wraps it; master calls it out of range
            "0x", // a hex prefix with no digits: released reads the 0 and stops
            "--1", // the one both agree on and this refuses anyway; see integer(_:)
        ]
    )
    func refusesWhatTwoLibplistsReadDifferently(_ spelling: String) throws {
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>k</key><integer>\(spelling)</integer></dict></plist>
        """.utf8)
        #expect(throws: VPhoneSignError.self) {
            _ = try VPhoneSignEntitlements(xml: plist)
        }
    }

    @Test("a binary plist is refused rather than read as XML")
    func refusesABinaryPlist() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["k": true], format: .binary, options: 0
        )
        #expect(throws: VPhoneSignError.self) {
            _ = try VPhoneSignEntitlements(xml: binary)
        }
    }
}
