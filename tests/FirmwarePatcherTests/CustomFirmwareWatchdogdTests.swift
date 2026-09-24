// CustomFirmwareWatchdogdTests.swift — parity, anchoring and idempotence for the
// watchdogd hv_vmm_present cache patch.
//
// Two independent references were available for this patch and both are used:
//
//   * `scripts/patchers/cfw_patch_watchdogd.py`, driven exactly as
//     `cfw_install_exp.sh` drove it (`cfw.py patch-watchdogd <binary>`). That
//     Python is gone; what it wrote over the pristine binary is frozen in
//     ``WatchdogdGolden`` below, and the central test grades `CustomFirmwareWatchdogd`
//     against it byte for byte — patched instructions and re-attested code
//     slots alike, because that verb re-attested on its own.
//   * `/usr/bin/codesign`, which recomputes the slot hashes itself. It has no
//     part in this code, so a binary that verifies under it is evidence the
//     re-attestation is right rather than self-consistent.
//
// The fixture is the real `/usr/libexec/watchdogd` from iOS 27.0 (24A435,
// iPhone17,3), at `ipsws/ref_extract/macho_pristine/watchdogd`. That tree is
// read-only reference data: every test here clones what it needs into the
// system temp directory and never writes inside it.

import Capstone
import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixtures

enum WatchdogdFixture {
    /// The package root, derived from this file rather than the working
    /// directory, which `swift test` does not promise.
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // FirmwarePatcherTests
        .deletingLastPathComponent() // tests
        .deletingLastPathComponent() // <root>

    static let pristineDirectory = repositoryRoot.appending(path: "ipsws/ref_extract/macho_pristine")
    static let watchdogd = pristineDirectory.appending(path: "watchdogd")
    /// A Mach-O from the same firmware that does not cache the sysctl — the
    /// negative case.
    static let seputil = pristineDirectory.appending(path: "seputil")

    static let codesign = URL(filePath: "/usr/bin/codesign")

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// SHA-256 as `shasum -a 256` prints it, so a digest in this run's output
    /// can be compared against one taken from a shell.
    static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hex
    }

    static var hasWatchdogd: Bool {
        exists(watchdogd)
    }

    static var hasSeputil: Bool {
        exists(seputil)
    }

    static var hasCodesign: Bool {
        hasWatchdogd && exists(codesign)
    }

    /// A private copy of `source` the caller may modify freely. Deliberately
    /// outside the working tree.
    static func scratchCopy(of source: URL, named name: String) throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "CustomFirmwareWatchdogdTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// The `__TEXT,__text` section, or a thrown error — never a silent empty
    /// result, which a test would read as "nothing to check".
    static func text(in data: Data) throws -> MachOSectionInfo {
        guard let text = MachOParser.parseSections(from: data)["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("fixture has no __TEXT,__text")
        }
        return text
    }

    /// Every `bl` in `__TEXT,__text` whose target resolves to `_sysctlbyname`.
    /// Computed here, not by the patcher, so "the anchor rejects the other
    /// calls" is measured against an independent count.
    static func sysctlCallSites(in data: Data) throws -> [UInt64] {
        let text = try text(in: data)
        guard let symbols = CustomFirmwareWatchdogdSymbolTargets(data: data) else {
            throw PatcherError.invalidFormat("fixture has no symbol table")
        }
        let start = Int(text.fileOffset)
        let body = data.subdata(in: start ..< start + Int(text.size))

        var found: [UInt64] = []
        for instruction in ARM64Disassembler().disassemble(body, at: text.address)
            where instruction.mnemonic == "bl"
        {
            guard let target = ARM64Encoder.decodeBranchTarget(
                insn: CustomFirmwareWatchdogd.word(of: instruction), pc: instruction.address,
            ) else { continue }
            if symbols.name(forBranchTarget: target) == "_sysctlbyname" {
                found.append(instruction.address)
            }
        }
        return found
    }
}

// MARK: - The frozen reference

/// What `scripts/patchers/` produced on this fixture, recorded before it was
/// deleted.
///
/// Every value below was taken at repo commit `78cbeea`, with
/// `.venv/bin/python3` driving `scripts/patchers/`, over the real iOS 27.0 /
/// 24A435 / iPhone17,3 `/usr/libexec/watchdogd` whose own digest is
/// ``pristine``.
enum WatchdogdGolden {
    /// `shasum -a 256 ipsws/ref_extract/macho_pristine/watchdogd`
    static let pristine = "0309b868a214f9841279db3e2ef901f26e8c05b2dc616eeb551f2b2f0e06207f"

    /// `.venv/bin/python3 scripts/patchers/cfw.py patch-watchdogd <clone>`
    ///
    /// Unlike the other CFW Mach-O verbs, this one re-attested on its own:
    /// stdout ended `wrote 2 site(s)` and then
    /// `re-attest updated 2 slot(s) across 2 unique (CD, page) pair(s)`,
    /// rewriting slots 4 and 10 (`4f3c398a.. -> f287fa91..` and
    /// `75fa0b5a.. -> ff44ac69..`). So this digest covers both halves.
    static let patched = "963cd44591763ac928f7fb9fab0e50e573bc456e5efe9c17e96fe8d220494b13"

    /// The two code slots that run re-attested.
    static let reattestedSlots = [4, 10]

    /// `cfw.py patch-watchdogd` run a SECOND time over ``patched``: it printed
    /// `all 2 matching site(s) already patched — nothing to do` and left the
    /// file byte for byte alone, so the digest is ``patched`` again. Both
    /// implementations agree that a patched binary needs nothing done to it.
    static let patchedTwice = patched
}

// MARK: - Anchoring

@Suite("watchdogd hv_vmm_present cache — anchoring")
struct CustomFirmwareWatchdogdAnchorTests {
    /// The shape the patch is written against, read off the real binary.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `locates both cache sites`() throws {
        let data = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let sites = try CustomFirmwareWatchdogd.locateSites(in: data)

        #expect(sites.count == 2, "24A435 watchdogd caches the answer in two functions")
        for site in sites {
            #expect(site.state == .pristine)
            #expect(site.valueRegister == "w8")
            // The gate really is the `cbnz w0` right after the call...
            #expect(site.gateVMA == site.callVMA + 4)
            let gate = try #require(ARM64Disassembler().disassembleOne(
                data.subdata(in: site.gateFileOffset ..< site.gateFileOffset + 4), at: site.gateVMA,
            ))
            #expect(gate.mnemonic == "cbnz")
            // ...and the value really is a `cset`.
            let value = try #require(ARM64Disassembler().disassembleOne(
                data.subdata(in: site.valueFileOffset ..< site.valueFileOffset + 4), at: site.valueVMA,
            ))
            #expect(value.mnemonic == "cset")
            #expect(value.aarch64?.conditionCode == AArch64CC_NE)
        }
    }

    /// The cached byte is a zero-filled global, which is why the skipped store
    /// leaves it reading 0 and why forcing the stored value to 1 is the fix.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `cached byte lives in zero filled data`() throws {
        let data = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let sites = try CustomFirmwareWatchdogd.locateSites(in: data)
        let sections = MachOParser.parseSections(from: data)
        let zeroFilled = ["__DATA,__bss", "__DATA,__common"].compactMap { sections[$0] }
        #expect(!zeroFilled.isEmpty)

        for site in sites {
            let inZeroFill = zeroFilled.contains {
                site.cachedByteVMA >= $0.address && site.cachedByteVMA < $0.address + $0.size
            }
            #expect(inZeroFill, "cached byte 0x\(String(site.cachedByteVMA, radix: 16)) must be BSS")
        }
    }

    /// The discriminating test: watchdogd calls `sysctlbyname` five times and
    /// only two of those calls cache the VM-presence answer. An anchor that
    /// matched on "a call followed by cbnz w0" alone would have to be checked
    /// by hand; this states the number.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `rejects the other sysctl call sites`() throws {
        let data = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let calls = try WatchdogdFixture.sysctlCallSites(in: data)
        let sites = try CustomFirmwareWatchdogd.locateSites(in: data)

        #expect(calls.count == 5, "24A435 watchdogd calls sysctlbyname five times")
        #expect(sites.count == 2)
        for site in sites {
            #expect(calls.contains(site.callVMA))
        }
    }

    /// The in-image symbol lookup the anchor rests on, checked on its own: a
    /// stub address in `__auth_stubs` resolves through the indirect symbol
    /// table to the imported name.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `resolves the import through the indirect symbol table`() throws {
        let data = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let symbols = try #require(CustomFirmwareWatchdogdSymbolTargets(data: data))
        let sites = try CustomFirmwareWatchdogd.locateSites(in: data)
        let call = try #require(sites.first)

        let target = try #require(ARM64Encoder.decodeBranchTarget(
            insn: {
                let offset = Int(call.callVMA - 0x1_0000_0000)
                return data.loadLE(UInt32.self, at: offset)
            }(),
            pc: call.callVMA,
        ))
        #expect(symbols.importName(atStub: target) == "_sysctlbyname")
        // An address that is not a stub resolves to nothing rather than to the
        // nearest entry.
        #expect(symbols.importName(atStub: call.callVMA) == nil)
    }

    /// The argument anchor on its own, over a synthesised stream, because the
    /// shipped binary only exercises one of its two branches.
    ///
    /// 24A435 forms the pointer straight into x0, so the indirection path —
    /// the literal built in a scratch register and moved into x0 before the
    /// call — has no coverage from the fixture. It is the path that keeps the
    /// patch working when a later build schedules the argument differently, so
    /// it is checked here instead of assumed.
    @Test
    func `accepts the literal reaching X 0 through A move`() throws {
        let base: UInt64 = 0x1_0000_0000

        func stream(movingInto destination: UInt32?) throws -> [Instruction] {
            var code = Data()
            code += try #require(ARM64Encoder.encodeADRP(rd: 9, pc: base, target: base + 0x4000))
            code += try #require(ARM64Encoder.encodeAddImm12(rd: 9, rn: 9, imm12: 0x453))
            if let destination {
                code += ARM64Encoder.encodeMovX(rd: destination, rm: 9)
            } else {
                code += ARM64.nop
            }
            code += try #require(ARM64Encoder.encodeBL(from: Int(base) + 12, to: Int(base) + 0x100))
            return ARM64Disassembler().disassemble(code, at: base)
        }

        // add x9, … ; mov x0, x9 ; bl — the literal is the call's argument.
        #expect(try CustomFirmwareWatchdogd.passesLiteral(
            inRegister: "x9", from: 1, toCallAt: 3, in: stream(movingInto: 0),
        ))
        // The same shape moving into x1 is some other call's argument.
        #expect(try !CustomFirmwareWatchdogd.passesLiteral(
            inRegister: "x9", from: 1, toCallAt: 3, in: stream(movingInto: 1),
        ))
        // No move at all, and the pointer never reaches x0.
        #expect(try !CustomFirmwareWatchdogd.passesLiteral(
            inRegister: "x9", from: 1, toCallAt: 3, in: stream(movingInto: nil),
        ))
        // The direct form the shipped binary uses needs no move.
        #expect(try CustomFirmwareWatchdogd.passesLiteral(
            inRegister: "x0", from: 1, toCallAt: 3, in: stream(movingInto: nil),
        ))
    }

    /// A Mach-O from the same firmware that never queries the sysctl is a hard
    /// error, not a silent no-op: "no site" and "already patched" must not be
    /// the same answer.
    @Test(.enabled(if: WatchdogdFixture.hasSeputil))
    func `rejects A binary without the cache site`() throws {
        let data = try Data(contentsOf: WatchdogdFixture.seputil)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareWatchdogd.locateSites(in: data)
        }
    }
}

// MARK: - Patching

@Suite("watchdogd hv_vmm_present cache — patching")
struct CustomFirmwareWatchdogdPatchTests {
    /// Both instructions, and nothing else in `__TEXT`.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `rewrites two instructions per site`() throws {
        let original = try Data(contentsOf: WatchdogdFixture.watchdogd)
        var data = original
        let report = try CustomFirmwareWatchdogd.patch(&data, log: nil)

        #expect(report.outcome == .patched)
        #expect(report.sitesWritten == 2)
        #expect(report.records.count == 4)

        let expectedValue = try #require(ARM64Encoder.encodeMovzW(rd: 8, imm16: 1))
        for (index, record) in report.records.enumerated() {
            #expect(record.component == "watchdogd")
            #expect(record.originalBytes.count == 4)
            #expect(record.patchedBytes == (index % 2 == 0 ? ARM64.nop : expectedValue))
            #expect(data.subdata(in: record.fileOffset ..< record.fileOffset + 4) == record.patchedBytes)
        }

        // Outside the two instructions and the two code slots, the file is
        // untouched: the patch is surgical by construction, not by inspection.
        var differing: [Int] = []
        for offset in 0 ..< original.count where original[offset] != data[offset] {
            differing.append(offset)
        }
        let instructionBytes = Set(report.records.flatMap { $0.fileOffset ..< $0.fileOffset + 4 })
        let slotBytes = Set(report.rehashedSlots.flatMap { $0.hashFileOffset ..< $0.hashFileOffset + 32 })
        #expect(Set(differing).isSubset(of: instructionBytes.union(slotBytes)))
        #expect(report.rehashedSlots.count == 2)
    }

    /// Every page that was written gets its slot re-hashed — checked against
    /// the code directory's own slot arithmetic rather than the patcher's.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `reattests the page of every written instruction`() throws {
        var data = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let report = try CustomFirmwareWatchdogd.patch(&data, log: nil)
        let directory = try #require(CustomFirmwareMachOCodeSignature.codeDirectories(in: data)?.first)

        let writtenPages = Set(report.records.map { $0.fileOffset / directory.pageSize })
        #expect(Set(report.rehashedSlots.map(\.pageIndex)) == writtenPages)

        for slot in report.rehashedSlots {
            let range = try #require(directory.slotRange(slot.pageIndex))
            let stored = data.subdata(
                in: directory.slotHashOffset(slot.pageIndex)
                    ..< directory.slotHashOffset(slot.pageIndex) + directory.hashSize,
            )
            #expect(stored == slot.after)
            #expect(slot.pageStart ..< slot.pageEnd == range)
        }
    }

    /// Idempotence. Commit 8eb6c8b fixed exactly this class of bug in this
    /// tree: a shape the patcher had already produced was not recognised. A
    /// second run must change nothing at all — not the instructions, not the
    /// code directory, not one byte of the file.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `second run changes nothing`() throws {
        var data = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let first = try CustomFirmwareWatchdogd.patch(&data, log: nil)
        #expect(first.outcome == .patched)

        let afterFirst = data
        let second = try CustomFirmwareWatchdogd.patch(&data, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(second.sitesWritten == 0)
        #expect(second.records.isEmpty)
        #expect(second.rehashedSlots.isEmpty)
        #expect(data == afterFirst, "a second run must be byte-for-byte a no-op")

        // And the already-patched shape is recognised as such, site by site.
        #expect(second.sites.count == 2)
        #expect(second.sites.allSatisfy { $0.state == .patched })
        #expect(second.sites.map(\.gateVMA) == first.sites.map(\.gateVMA))
        #expect(second.sites.map(\.valueVMA) == first.sites.map(\.valueVMA))
    }

    /// A dry run reports the sites and writes nothing.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `dry run writes nothing`() throws {
        let original = try Data(contentsOf: WatchdogdFixture.watchdogd)
        var data = original
        let report = try CustomFirmwareWatchdogd.patch(&data, dryRun: true, log: nil)
        #expect(report.outcome == .wouldPatch)
        #expect(report.records.count == 4)
        #expect(data == original)
    }

    /// The file-backed entry point, which is what the install script calls.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `patches in place on disk`() throws {
        let file = try WatchdogdFixture.scratchCopy(of: WatchdogdFixture.watchdogd, named: "watchdogd")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let attributes = FileManager.default.attributesOfItem(atPath:)
        let modeBefore = try attributes(file.path)[.posixPermissions] as? NSNumber

        let report = try CustomFirmwareWatchdogd.patch(at: file, log: nil)
        #expect(report.outcome == .patched)

        var expected = try Data(contentsOf: WatchdogdFixture.watchdogd)
        try CustomFirmwareWatchdogd.patch(&expected, log: nil)
        #expect(try Data(contentsOf: file) == expected)

        // watchdogd is installed executable and stays that way: the patch
        // rewrites the file in place rather than replacing it.
        #expect(try attributes(file.path)[.posixPermissions] as? NSNumber == modeBefore)
        #expect(FileManager.default.isExecutableFile(atPath: file.path))
    }

    /// A second run over a file on disk leaves its bytes, and its mtime,
    /// untouched — `.alreadyPatched` must not write at all.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `second run on disk writes nothing`() throws {
        let file = try WatchdogdFixture.scratchCopy(of: WatchdogdFixture.watchdogd, named: "watchdogd")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        try CustomFirmwareWatchdogd.patch(at: file, log: nil)
        let afterFirst = try Data(contentsOf: file)
        let stampAfterFirst = try FileManager.default
            .attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        let second = try CustomFirmwareWatchdogd.patch(at: file, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(try Data(contentsOf: file) == afterFirst)
        #expect(try FileManager.default
            .attributesOfItem(atPath: file.path)[.modificationDate] as? Date == stampAfterFirst)
    }
}

// MARK: - Independent references

@Suite("watchdogd hv_vmm_present cache — independent references")
struct CustomFirmwareWatchdogdReferenceTests {
    /// The fixture the frozen digests were taken over. Without this a digest
    /// mismatch below would read as a patcher bug when the real cause is a
    /// different firmware's `watchdogd`.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `fixture matches the goldens`() throws {
        #expect(
            try WatchdogdFixture.digest(Data(contentsOf: WatchdogdFixture.watchdogd))
                == WatchdogdGolden.pristine,
            """
            this is not the 24A435 watchdogd WatchdogdGolden was recorded from \
            — re-derive the goldens before reading a failure below as a \
            patcher bug
            """,
        )
    }

    /// The migration plan's gate for P1.2: the Swift patcher and the Python it
    /// replaced must produce the same bytes from the same input.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `matches the frozen reference byte for byte`() throws {
        var mine = try Data(contentsOf: WatchdogdFixture.watchdogd)
        let report = try CustomFirmwareWatchdogd.patch(&mine, log: nil)

        // Printed so the parity claim is checkable from outside this process:
        // `shasum -a 256` over this patcher's output has to read the same.
        try print("""
        watchdogd parity: \
        pristine=\(WatchdogdFixture.digest(Data(contentsOf: WatchdogdFixture.watchdogd))) \
        golden=\(WatchdogdGolden.patched) \
        swift=\(WatchdogdFixture.digest(mine))
        """)
        #expect(report.sitesWritten == 2)
        #expect(report.rehashedSlots.map(\.pageIndex).sorted() == WatchdogdGolden.reattestedSlots)
        #expect(
            WatchdogdFixture.digest(mine) == WatchdogdGolden.patched,
            "Swift output must be identical to the frozen reference's",
        )
    }

    /// The reference's idempotent path, for the same reason: both
    /// implementations agree that a patched binary needs nothing done to it.
    @Test(.enabled(if: WatchdogdFixture.hasWatchdogd))
    func `agrees with the frozen reference on an already patched binary`() throws {
        let file = try WatchdogdFixture.scratchCopy(
            of: WatchdogdFixture.watchdogd, named: "watchdogd-twice",
        )
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        try CustomFirmwareWatchdogd.patch(at: file, log: nil)
        let afterFirst = try Data(contentsOf: file)
        #expect(WatchdogdFixture.digest(afterFirst) == WatchdogdGolden.patched)

        // The frozen half: the reference, handed this exact file, reported
        // `all 2 matching site(s) already patched — nothing to do` and wrote
        // nothing. This port lands on the same bytes when it re-runs.
        let second = try CustomFirmwareWatchdogd.patch(at: file, log: nil)
        #expect(second.outcome == .alreadyPatched)
        #expect(try WatchdogdFixture.digest(Data(contentsOf: file)) == WatchdogdGolden.patchedTwice)
    }

    /// `codesign` recomputes the page hashes independently of this code. If the
    /// re-attestation were wrong — the short tail slot being the classic way —
    /// this is where it shows.
    @Test(.enabled(if: WatchdogdFixture.hasCodesign))
    func `patched binary still verifies under codesign`() throws {
        let file = try WatchdogdFixture.scratchCopy(
            of: WatchdogdFixture.watchdogd, named: "watchdogd-signed",
        )
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let before = try WatchdogdFixture.run(WatchdogdFixture.codesign, ["-v", "-v", file.path])
        #expect(before.status == 0, "fixture must verify before patching: \(before.output)")

        try CustomFirmwareWatchdogd.patch(at: file, log: nil)

        let after = try WatchdogdFixture.run(WatchdogdFixture.codesign, ["-v", "-v", file.path])
        #expect(after.status == 0, "patched binary must still verify: \(after.output)")
    }
}
