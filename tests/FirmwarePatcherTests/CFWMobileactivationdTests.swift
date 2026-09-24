// CFWMobileactivationdTests.swift — `-[DeviceType should_hactivate]` -> YES.
//
// The bar here is not "the Swift patcher did something". It is that this port
// and `scripts/patchers/cfw_patch_mobileactivationd.py` produce the same bytes
// from the same input, on the real iOS 27.0 / 24A435 iPhone17,3
// `/usr/libexec/mobileactivationd` in `ipsws/ref_extract/macho_pristine/`, and
// that the result passes `codesign -v` — two references, neither of them this
// code. The Python is gone; what it wrote is frozen digest by digest in
// ``MobileactivationdGolden``, so the comparison outlived it. The comparisons
// are still gated on the pristine binary, which is not in the repo.
//
// Outputs are kept on disk, not in a scratch directory that vanishes, so the
// same comparison can be re-run by hand with `cmp`, `shasum` and `codesign`.
// They go wherever `VPHONE_TEST_ARTIFACTS` points, defaulting to a named
// directory under `TMPDIR` — never inside the repository, and never inside
// `ipsws/ref_extract/`, which is the read-only reference tree.

import Capstone
import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixtures

enum MobileactivationdFixture {
    /// The package root, derived from this file rather than the working
    /// directory, which `swift test` does not promise.
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // FirmwarePatcherTests
        .deletingLastPathComponent() // tests
        .deletingLastPathComponent() // <root>

    /// The pristine reference binary. Read-only: every test works on a copy.
    static let pristine = repositoryRoot
        .appending(path: "ipsws/ref_extract/macho_pristine/mobileactivationd")

    /// A second real binary that does not contain the method, for the
    /// not-found path.
    static let launchd = repositoryRoot
        .appending(path: "ipsws/ref_extract/macho_pristine/launchd")

    static let codesign = URL(filePath: "/usr/bin/codesign")

    /// Where comparison artifacts land, so a failure can be picked apart after
    /// the run instead of being re-created from scratch.
    ///
    /// Outside the repository by default. `ipsws/ref_extract/` in particular is
    /// the pristine reference the whole suite compares against; nothing here
    /// ever writes inside it.
    static let artifacts: URL = {
        if let override = ProcessInfo.processInfo.environment["VPHONE_TEST_ARTIFACTS"],
           !override.isEmpty
        {
            return URL(filePath: override).appending(path: "CFWMobileactivationdTests")
        }
        return FileManager.default.temporaryDirectory.appending(path: "CFWMobileactivationdTests")
    }()

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static var hasPristine: Bool {
        exists(pristine)
    }

    static var hasLaunchd: Bool {
        exists(launchd)
    }

    static var hasCodesign: Bool {
        hasPristine && exists(codesign)
    }

    /// SHA-256 as `shasum -a 256` prints it, so a digest asserted here can be
    /// taken again from a shell over the same file.
    static func digest(of url: URL) throws -> String {
        try Data(SHA256.hash(data: Data(contentsOf: url))).hex
    }

    /// A named, writable copy of the pristine binary under ``artifacts``.
    static func copyOfPristine(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let destination = artifacts.appending(path: name)
        if exists(destination) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: pristine, to: destination)
        return destination
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

// MARK: - The frozen reference

/// What `scripts/patchers/` produced on this fixture, recorded before it was
/// deleted.
///
/// Every value below was taken at repo commit `78cbeea`, with
/// `.venv/bin/python3` driving `scripts/patchers/`, over the real iOS 27.0 /
/// 24A435 / iPhone17,3 `mobileactivationd` whose own digest is ``pristine``.
enum MobileactivationdGolden {
    /// `shasum -a 256 ipsws/ref_extract/macho_pristine/mobileactivationd`
    static let pristine = "89233513ce696cd01285f3432f3bcadd065cee07ac73bc5714836d13f24702d8"

    /// `.venv/bin/python3 scripts/patchers/cfw.py patch-mobileactivationd <clone>`
    /// — `ldrb w0, [x0, #0x14] ; ret` at 0x2EC368 replaced with
    /// `mov x0, #1 ; ret`, signature left stale, exactly as `cfw_install.sh`
    /// ran it before `ldid_sign`. Its stdout reported
    /// `Found via symtab: va:0x1002EC368 -> foff:0x2EC368`.
    static let patched = "9f26bf92a2a80133e763c6426949e262ad26d51485b5184548744bd37e1f4095"

    /// The IMP the Python's symbol-table anchor resolved to, from that stdout.
    static let impFileOffset = 0x2EC368

    /// ``patched``, then
    /// `.venv/bin/python3 -c 'import sys; sys.path.insert(0, "scripts");
    /// from patchers.cfw_macho_codesign import reattest_modified_offsets;
    /// reattest_modified_offsets(sys.argv[1], [0x2ec368, 0x2ec36c])'`
    /// — which reported `wrote cd_index=0 slot 748 (907503ed.. -> 2ea7d714..)`.
    static let patchedAndReattested =
        "df16f1ab4f5e7a3ad7a3a8774d54c0330a1b38d9568ad233e20936e48674973f"

    /// The one code slot that re-attestation rewrote.
    static let reattestedSlot = 748
}

// MARK: - Shell Runner

/// A shell entry point for the patcher, standing in for `vphone-patch` until
/// that binary exists (plan §3.9).
///
/// ```
/// VPHONE_PATCH_FILE=<binary> swift test --filter runPatcherFromEnvironment
/// ```
///
/// patches that one file in place and prints where it landed. It exists so the
/// comparison against ``MobileactivationdGolden``, and the run-it-twice check,
/// can be driven from a shell over files a human picked — `shasum -a 256` on
/// the result reads the same digests — rather than living only inside
/// assertions this same process wrote. Without the variable it does not run.
///
/// `VPHONE_PATCH_RESIGN=0` skips re-attestation, which is what reproduces
/// ``MobileactivationdGolden/patched`` exactly.
@Suite("mobileactivationd should_hactivate — shell runner")
struct CFWMobileactivationdRunnerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_PATCH_FILE"] != nil))
    func `run patcher from environment`() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["VPHONE_PATCH_FILE"])
        let resign = environment["VPHONE_PATCH_RESIGN"] != "0"

        let report = try CFWMobileactivationd.patch(fileAt: URL(filePath: path), resign: resign)

        print(
            "RUNNER outcome=\(report.outcome.rawValue)"
                + " sitesWritten=\(report.sitesWritten)"
                + " va=0x\(String(report.anchor.virtualAddress, radix: 16, uppercase: true))"
                + " foff=0x\(String(report.anchor.fileOffset, radix: 16, uppercase: true))"
                + " section=\(report.anchor.section)"
                + " anchor=\(report.anchor.source.rawValue)"
                + " rehashes=\(report.slotRehashes.count)",
        )
        for rehash in report.slotRehashes {
            print("RUNNER   \(rehash.description)")
            print("RUNNER   slot@0x\(String(rehash.hashFileOffset, radix: 16, uppercase: true))"
                + " = \(rehash.after.hex)")
        }
    }
}

// MARK: - Anchoring

@Suite("mobileactivationd should_hactivate — anchoring")
struct CFWMobileactivationdAnchorTests {
    /// The two routes are independent — `LC_SYMTAB` on one side, the
    /// `__objc_methname` -> `__objc_selrefs` -> relative method list walk on the
    /// other — and they agree. That agreement is the evidence the anchor is the
    /// method and not something that merely sorts first.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `both anchors resolve and agree`() throws {
        let data = try Data(contentsOf: MobileactivationdFixture.pristine)
        let segments = MachOParser.parseSegments(from: data)

        let bySymbol = try #require(
            CFWMobileactivationd.symbolVirtualAddress(in: data),
            "LC_SYMTAB should carry -[DeviceType should_hactivate]",
        )
        let byMetadata = try #require(
            CFWMobileactivationd.objcMetadataVirtualAddress(in: data, segments: segments),
            "the ObjC method lists should carry the same IMP",
        )
        #expect(bySymbol == byMetadata)

        let anchor = try CFWMobileactivationd.locateIMP(in: data)
        #expect(anchor.source == .symbolTableAndObjCMetadata)
        #expect(anchor.virtualAddress == bySymbol)
        #expect(anchor.section == "__TEXT,__text", "the IMP must be code, not data")
        #expect(
            MachOParser.vaToFileOffset(anchor.virtualAddress, segments: segments) == anchor.fileOffset,
        )
    }

    /// The selector search must not settle for a suffix of a longer string.
    ///
    /// `DeviceType`'s ivar is `_should_hactivate`, so a plain search for
    /// `should_hactivate\0` — what `scripts/patchers/cfw_patch_mobileactivationd.py`
    /// did at 78cbeea — lands inside the ivar's name, finds no selref for it,
    /// and gives up. The NUL-preceded match finds the real selector instead.
    /// The naive search is reproduced below rather than described, so the
    /// contrast is measured here and does not depend on that Python existing.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `selector lookup skips the ivar name`() throws {
        let data = try Data(contentsOf: MobileactivationdFixture.pristine)
        let sections = MachOParser.parseSections(from: data)
        let selectorVA = try #require(
            CFWMobileactivationd.selectorVirtualAddress(in: data, sections: sections),
        )

        let methname = try #require(sections["__TEXT,__objc_methname"])
        let start = Int(methname.fileOffset)
        let offset = start + Int(selectorVA - methname.address)
        #expect(data[offset - 1] == 0, "the selector must start a string, not end one")

        // That naive search finds an earlier, wrong offset on this binary — so
        // this is not an assertion that passes either way.
        let needle = Data(CFWMobileactivationd.selector.utf8) + Data([0])
        let naive = try #require(data.range(of: needle)?.lowerBound)
        #expect(naive < offset)
        #expect(data[naive - 1] == UInt8(ascii: "_"))
    }

    /// A binary without the method is a hard stop, not a silent skip: every
    /// caller of this patch needs it to have happened.
    @Test(.enabled(if: MobileactivationdFixture.hasLaunchd))
    func `missing method throws`() throws {
        let data = try Data(contentsOf: MobileactivationdFixture.launchd)
        #expect(throws: PatcherError.self) {
            try CFWMobileactivationd.locateIMP(in: data)
        }
    }

    /// The replacement is assembled, not transcribed. `ARM64Encoder`'s MOVZ is
    /// asserted against keystone in `ARM64EncoderTests`; this pins that the
    /// patch asks it for the right instruction, and that the pair reads back as
    /// `mov x0, #1 ; ret`.
    @Test func `replacement is mov X 0 one then ret`() throws {
        let bytes = try CFWMobileactivationd.replacementBytes()
        #expect(bytes.count == 8)
        #expect(bytes == ARM64.movX0_1 + ARM64.ret)

        let decoded = ARM64Disassembler().disassemble(bytes, at: 0, count: 2)
        #expect(decoded.count == 2)
        #expect(decoded[0].mnemonic == "mov")
        #expect(decoded[1].mnemonic == "ret")
        let operands = try #require(decoded[0].aarch64?.operands)
        #expect(operands.count == 2)
        #expect(operands[1].type == AARCH64_OP_IMM)
        #expect(operands[1].imm == 1)
        #expect(ARM64Disassembler().firstRegisterName(decoded[0]) == "x0")
    }

    /// Both words of the getter are re-hashed, so a getter that straddles a
    /// page boundary does not leave the second page's slot stale.
    @Test func `touched offsets cover both words`() throws {
        let anchor = CFWMobileactivationd.Anchor(
            virtualAddress: 0x1_0000_0FFC,
            fileOffset: 0xFFC,
            source: .symbolTable,
            section: "__TEXT,__text",
        )
        let bytes = try CFWMobileactivationd.replacementBytes()
        let offsets = CFWMobileactivationd.touchedOffsets(anchor, bytes)
        #expect(offsets == [0xFFC, 0x1000])
        #expect(Set(offsets.map { $0 / 4096 }).count == 2, "the two words are on different pages")
    }
}

// MARK: - Byte parity with the frozen reference

@Suite("mobileactivationd should_hactivate — parity and idempotence")
struct CFWMobileactivationdParityTests {
    /// The fixture the frozen digests were taken over. Without this a digest
    /// mismatch below would read as a patcher bug when the real cause is a
    /// different firmware's `mobileactivationd`.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `fixture matches the goldens`() throws {
        #expect(
            try MobileactivationdFixture.digest(of: MobileactivationdFixture.pristine)
                == MobileactivationdGolden.pristine,
            """
            this is not the 24A435 mobileactivationd MobileactivationdGolden \
            was recorded from — re-derive the goldens before reading a failure \
            below as a patcher bug
            """,
        )
    }

    /// Bar 1: identical bytes out of identical bytes in, against the
    /// implementation that was replaced.
    ///
    /// `resign: false` because the Python patcher did not re-sign — the
    /// `ldid_sign` in `cfw_install.sh` does — so this compares like with like.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `matches the frozen reference bytes`() throws {
        let swiftFile = try MobileactivationdFixture.copyOfPristine(named: "swift.bin")

        let report = try CFWMobileactivationd.patch(fileAt: swiftFile, resign: false, log: nil)

        #expect(report.outcome == .patched)
        #expect(report.sitesWritten == 1)
        #expect(report.slotRehashes.isEmpty, "resign: false must not touch the signature")
        #expect(
            try MobileactivationdFixture.digest(of: swiftFile) == MobileactivationdGolden.patched,
            "Swift output must be byte-identical to the reference's",
        )

        // And the one site it changed is the one the reference's symtab anchor
        // named, and the one this patch claims.
        let record = try #require(report.record)
        let pristine = try Data(contentsOf: MobileactivationdFixture.pristine)
        let patched = try Data(contentsOf: swiftFile)
        let differing = (0 ..< pristine.count).filter { patched[$0] != pristine[$0] }
        #expect(!differing.isEmpty)
        #expect(differing.allSatisfy { record.fileOffset ..< record.fileOffset + 8 ~= $0 })
        #expect(record.fileOffset == MobileactivationdGolden.impFileOffset)
        #expect(record.patchID == "mobileactivationd.should_hactivate")
        #expect(record.component == "mobileactivationd")
        #expect(record.patchedBytes == ARM64.movX0_1 + ARM64.ret)
        #expect(record.beforeDisasm.hasSuffix("ret"))
    }

    /// Bar 2: the re-attested output matches the reference's own
    /// re-attestation, slot hash for slot hash, and `codesign -v` accepts it.
    ///
    /// The raw patch does not: `codesign` rejects it, which is what makes this
    /// step load-bearing rather than decorative.
    @Test(.enabled(if: MobileactivationdFixture.hasCodesign))
    func `reattested output matches the frozen reference and verifies`() throws {
        let swiftFile = try MobileactivationdFixture.copyOfPristine(named: "swift-resigned.bin")

        let report = try CFWMobileactivationd.patch(fileAt: swiftFile, resign: true, log: nil)
        let rehash = try #require(report.slotRehashes.first)
        #expect(report.slotRehashes.count == 1)
        #expect(rehash.pageIndex == MobileactivationdGolden.reattestedSlot)

        let swiftBytes = try Data(contentsOf: swiftFile)
        #expect(
            Data(SHA256.hash(data: swiftBytes)).hex == MobileactivationdGolden.patchedAndReattested,
            "re-attested output must match the reference's",
        )

        // The slot hash itself, not just the file: read it back out.
        let slot = rehash.hashFileOffset ..< rehash.hashFileOffset + rehash.after.count
        #expect(swiftBytes[slot] == rehash.after)

        let verified = try MobileactivationdFixture.run(
            MobileactivationdFixture.codesign, ["-v", swiftFile.path],
        )
        #expect(verified.status == 0, "codesign -v rejected the patched binary: \(verified.output)")

        // The contrast: without re-attestation it is rejected.
        let unsigned = try MobileactivationdFixture.copyOfPristine(named: "swift-unsigned.bin")
        try CFWMobileactivationd.patch(fileAt: unsigned, resign: false, log: nil)
        let rejected = try MobileactivationdFixture.run(
            MobileactivationdFixture.codesign, ["-v", unsigned.path],
        )
        #expect(rejected.status != 0, "an un-re-attested patch should not verify")
    }

    /// Bar 3. A second run recognises its own output and writes nothing —
    /// neither an error nor a double-apply. `8eb6c8b` fixed exactly this class
    /// of bug for the DSC gates; it does not get to come back here.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `second run changes nothing`() throws {
        let file = try MobileactivationdFixture.copyOfPristine(named: "swift-idempotent.bin")

        let first = try CFWMobileactivationd.patch(fileAt: file, log: nil)
        #expect(first.outcome == .patched)
        let afterFirst = try Data(contentsOf: file)

        let second = try CFWMobileactivationd.patch(fileAt: file, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.record == nil)
        #expect(second.slotRehashes.isEmpty, "the slot was already correct")
        #expect(second.anchor == first.anchor)
        #expect(try Data(contentsOf: file) == afterFirst)

        let third = try CFWMobileactivationd.patch(fileAt: file, log: nil)
        #expect(third.outcome == .alreadyPatched)
        #expect(try Data(contentsOf: file) == afterFirst)
    }

    /// A patched-but-not-re-attested binary — what the Python left behind, and
    /// what ``MobileactivationdGolden/patched`` is the digest of — is repaired
    /// on the next run rather than reported as already done and left to be
    /// SIGKILLed on first page-in.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `rerun repairs A stale slot`() throws {
        let file = try MobileactivationdFixture.copyOfPristine(named: "swift-stale-slot.bin")
        try CFWMobileactivationd.patch(fileAt: file, resign: false, log: nil)

        let repaired = try CFWMobileactivationd.patch(fileAt: file, resign: true, log: nil)
        #expect(repaired.outcome == .alreadyPatched)
        #expect(repaired.slotRehashes.count == 1, "the stale slot must be recomputed")
        #expect(repaired.record == nil, "no code bytes changed the second time")
    }

    /// A dry run reports the site and leaves the file exactly as it found it.
    @Test(.enabled(if: MobileactivationdFixture.hasPristine))
    func `dry run writes nothing`() throws {
        let file = try MobileactivationdFixture.copyOfPristine(named: "swift-dry-run.bin")
        let before = try Data(contentsOf: file)

        let report = try CFWMobileactivationd.patch(fileAt: file, dryRun: true, log: nil)
        #expect(report.outcome == .wouldPatch)
        #expect(report.sitesWritten == 0)
        #expect(report.anchor.section == "__TEXT,__text")
        #expect(try Data(contentsOf: file) == before)
    }
}
