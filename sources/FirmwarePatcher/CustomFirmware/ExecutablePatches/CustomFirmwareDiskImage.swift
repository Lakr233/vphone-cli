// CustomFirmwareDiskimagesiod.swift — force diskimagesiod's DDI mount-completion gate open.
//
// Swift port of `scripts/patchers/cfw_patch_diskimagesiod.py`, driven by
// `cfw.py patch-diskimagesiod <binary>` and, in the shipped installers, by
// `scripts/cfw_install.sh:415` / `cfw-kit/lib/base_stages.sh:188`.
//
// Why the patch exists
// ────────────────────
// `pymobiledevice3 mounter auto-mount` attaches the personalized DDI, then
// MobileStorageMounter waits on diskimagesiod's
// `-[DIDiskArb waitForDAMountWithExpectedCount:diskTracker:]` before it
// performs the real (nobrowse) mount of the DDI volume at /System/Developer.
// That wait spins until `isMountComplete` returns YES, which is
// `callbackReached || (appearedDiskCount >= expectedCount &&
// mountedDiskCount >= mountableDiskCount)`. On the iOS-27-userland /
// 26.4-vphone600-kernel hybrid it never becomes true: only some of the DMG's
// IOMedia ever "appear" to diskimagesiod's DiskArbitration session, and
// diskarbitrationd never auto-mounts the volume, so the wait hangs forever and
// pmd3 times out. diskimagesiod itself does NOT mount the DDI — its
// `-[DIDiskArb mountWithDeviceName:…]` is dead code; it only gates
// MobileStorageMounter. Forcing `isMountComplete` to YES lets the wait return
// immediately so MobileStorageMounter proceeds and mounts the DDI.
//
// Pairs with the JB kernel patches that make the DDI attachable and mountable
// (the DiskImages2 ABI pokes, and the Sandbox `mpo_proc_check_syscall_unix`
// stub that lets MobileStorageMounter's `mount_apfs` issue `mount(2)`).
// No-op-in-effect on version-matched userlands, where the wait completes on its
// own and returning YES early changes nothing observable.
//
// How the site is found
// ─────────────────────
// Nothing here is a hardcoded offset. Two source-backed anchors, in order:
//
//   1. `LC_SYMTAB`: a symbol whose name contains `isMountCompleteWithExpectedCount`.
//      Shipped diskimagesiod is stripped, so this normally misses — it is kept
//      because it is the cheapest and most direct anchor when it does hit.
//   2. ObjC runtime metadata, which survives stripping:
//      selector cstring in `__TEXT,__objc_methname`
//        → its `__objc_selrefs` entry (chained-fixup aware)
//        → the relative method-list entry naming it
//        → that entry's `imp` field, relative-addressed.
//      `__TEXT,__objc_methlist` is walked *structurally* first — a packed run
//      of `{entsizeAndFlags, count}` headers followed by `count` 12-byte
//      `{name, types, imp}` entries, each list 8-byte aligned. The structural
//      walk cannot land mid-entry and cannot mistake a `__const` word for a
//      method. The Python's 4-byte-strided scan is kept behind it, over the
//      same sections the Python tries plus `__objc_methlist` itself, so this
//      port is never less capable than the one it replaces. Either way the
//      result is required to be the *only* entry in the image naming that
//      selector.
//
// The resolved IMP is then checked to land inside `__TEXT,__text` and to decode
// as real instructions before a single byte is written.
//
// What is written
// ───────────────
// `mov x0, #1 ; ret` over the method prologue. Safe: the function returns to the
// caller's (unsigned) LR without ever having pushed a frame, so overwriting
// `pacibsp; stp …` loses nothing that the new epilogue needs. Both words come
// from the encoder — `ARM64Encoder.encodeMovzX` builds MOVZ from its ISA fields
// and `ARM64.ret` is the keystone-derived constant; `CustomFirmwareDiskimagesiodTests`
// asserts the two agree with `ARM64.movX0_1`.
//
// Re-signing
// ──────────
// Off by default, matching the Python and the call site: `cfw_install.sh`
// re-signs the patched binary with `ldid` under the extracted
// `com.apple.diskimagesiod` entitlements, so a slot re-attest here would be
// overwritten moments later. `reattest: true` recomputes the CodeDirectory slot
// hashes through `CustomFirmwareMachOCodeSignature` instead, which is what a caller that
// drops the `ldid` step needs — and what makes `codesign -v` pass on the patched
// file on its own.

import Capstone
import Foundation

/// Forces `-[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:]` to
/// return YES so MobileStorageMounter stops waiting on a mount that will never
/// be reported.
public enum CustomFirmwareDiskImage {
    // MARK: - Identity

    /// The component name the Python records this write under.
    public static let component = "diskimagesiod"

    /// The selector whose implementation is stubbed.
    public static let selector = "isMountCompleteWithExpectedCount:diskTracker:"

    /// The `LC_SYMTAB` fragment strategy 1 looks for. Deliberately shorter than
    /// the selector: a symbol name is `-[DIDiskArb isMountComplete…]`, and the
    /// colon-bearing tail differs between symbol spellings.
    public static let symbolFragment = "isMountCompleteWithExpectedCount"

    /// The method, as it reads in a disassembler.
    public static let method = "-[DIDiskArb \(selector)]"

    /// Record identity, matching the Python's `records.site` label so a captured
    /// reference and this port sort together.
    public static let patchID = "diskimagesiod.is_mount_complete"

    /// `mov x0, #1 ; ret`.
    ///
    /// MOVZ is built from its ISA fields by ``ARM64Encoder/encodeMovzX(rd:imm16:shift:)``;
    /// the `?? ARM64.movX0_1` arm is unreachable (that encoder returns `nil`
    /// only for a shift above 48) and exists so this stays a plain `let` with
    /// no trap in it. `CustomFirmwareDiskimagesiodTests` asserts the two spellings are the
    /// same four bytes.
    public static let replacement: Data =
        (ARM64Encoder.encodeMovzX(rd: 0, imm16: 1) ?? ARM64.movX0_1) + ARM64.ret

    // MARK: - Results

    /// Which anchor found the implementation.
    public enum Anchor: String, Sendable, Equatable {
        /// `LC_SYMTAB` carried the symbol. Only on an unstripped build.
        case symbolTable
        /// Structural walk of `__TEXT,__objc_methlist`.
        case relativeMethodList
        /// The Python's strategy: a 4-byte-strided scan, over `__objc_methlist`
        /// when the structural walk could not follow it, then over the
        /// `__objc_const` sections of the pre-`__objc_methlist` layout.
        case methodListScan
    }

    /// The implementation this patch overwrites.
    public struct Site: Sendable, Equatable {
        /// File offset of the method's first instruction.
        public let fileOffset: Int
        /// Its virtual address, when an anchor produced one.
        public let virtualAddress: UInt64?
        /// How it was found.
        public let anchor: Anchor
        /// The bytes the patch replaces, as found — ``replacement``-many.
        public let original: Data

        /// True when the site already holds this patch's own output.
        public var isAlreadyPatched: Bool {
            original == CustomFirmwareDiskImage.replacement
        }
    }

    /// What a run did.
    public enum Outcome: String, Sendable, Equatable {
        /// The prologue already read `mov x0, #1 ; ret`; nothing was written
        /// there. (A stale slot hash may still have been re-attested.)
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The prologue was replaced.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        public let site: Site
        /// The write, in the shape the Python's reference capture records it.
        /// `nil` unless the prologue bytes actually changed.
        public let record: PatchRecord?
        /// CodeDirectory slots re-attested. Empty unless `reattest` was set,
        /// and empty on a second run because the stored hashes already match.
        public let rehashes: [CustomFirmwareSlotRehash]

        /// The parity number: the Python writes exactly one site, and so must this.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }
    }

    /// Where progress goes when the caller does not say. The Python prints to
    /// stdout and `cfw_install*.sh` captures that, so this does too.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Patching

    /// Stub the mount-completion gate in `data`.
    ///
    /// Idempotent: a buffer that already reads `mov x0, #1 ; ret` at the site
    /// reports ``Outcome/alreadyPatched`` and writes nothing, rather than
    /// failing to recognise a prologue that is no longer there. Re-running is
    /// the normal case — `cfw install` is re-run against an already-installed
    /// volume all the time — and commit `8eb6c8b` exists because a sibling
    /// patcher got this wrong.
    ///
    /// - Parameters:
    ///   - reattest: recompute the CodeDirectory slot hashes for the pages the
    ///     write touched. Off by default; see the file header for why.
    ///   - dryRun: locate and report without writing.
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when the buffer is not a
    ///   64-bit Mach-O or its ObjC metadata is ambiguous, and
    ///   ``PatcherError/patchSiteNotFound(_:)`` when no anchor resolves — both
    ///   have to stop the install rather than be guessed at.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        reattest: Bool = false,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let site = try locate(in: data)
        let patched = replacement
        log?("  \(method) @ \(describe(site))")
        log?("  Before: \(disassemblyText(of: site.original, at: site.virtualAddress))")

        guard !dryRun else {
            log?("  [.] dry-run: would write \(patched.hex) at 0x\(hex(UInt64(site.fileOffset)))")
            return Report(outcome: .wouldPatch, site: site, record: nil, rehashes: [])
        }

        var record: PatchRecord?
        if site.isAlreadyPatched {
            log?("  [=] already `mov x0, #1 ; ret` at 0x\(hex(UInt64(site.fileOffset))); nothing to write")
        } else {
            data.replaceSubrange(site.fileOffset ..< site.fileOffset + patched.count, with: patched)
            record = makeRecord(site: site, patched: patched)
            log?("  After:  \(disassemblyText(of: patched, at: site.virtualAddress))")
        }

        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest {
            // First and last byte of the write: an 8-byte span sits inside one
            // 4 KiB page here, but a page boundary between them would otherwise
            // leave the second page's slot stale.
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(
                &data,
                modifiedOffsets: [site.fileOffset, site.fileOffset + patched.count - 1],
            )
            for rehash in rehashes {
                log?("      [~] \(rehash)")
            }
            if rehashes.isEmpty {
                log?("  [=] code directory slots already current; no re-attest needed")
            }
        }

        let written = data[site.fileOffset ..< site.fileOffset + patched.count]
        guard written == patched else {
            throw PatcherError.patchVerificationFailed(
                "\(method): site at 0x\(hex(UInt64(site.fileOffset))) reads \(Data(written).hex) after write",
            )
        }

        log?("  [+] \(method) forced to YES at 0x\(hex(UInt64(site.fileOffset)))")
        return Report(
            outcome: site.isAlreadyPatched ? .alreadyPatched : .patched,
            site: site,
            record: record,
            rehashes: rehashes,
        )
    }

    /// File-backed form of ``patch(_:reattest:dryRun:log:)``.
    ///
    /// The file is rewritten only when its bytes actually changed, so a
    /// re-run leaves even the modification time alone.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        reattest: Bool = false,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(&data, reattest: reattest, dryRun: dryRun, log: log)
        if !dryRun, report.record != nil || !report.rehashes.isEmpty {
            try data.write(to: url)
        }
        return report
    }

    // MARK: - Locating the implementation

    /// Resolve the method's first instruction without touching the buffer.
    ///
    /// - Throws: ``PatcherError/patchSiteNotFound(_:)`` when every anchor is
    ///   exhausted, ``PatcherError/invalidFormat(_:)`` when the image is not a
    ///   64-bit Mach-O or names the selector from more than one implementation.
    public static func locate(in data: Data) throws -> Site {
        let data = rebased(data)
        guard data.count > 32, data.loadLE(UInt32.self, at: 0) == machMagic64 else {
            throw PatcherError.invalidFormat("\(component): not a 64-bit Mach-O")
        }
        let segments = MachOParser.parseSegments(from: data)
        let sections = MachOParser.parseSections(from: data)
        let textRange = sections[textSectionKey].map {
            Int($0.fileOffset) ..< Int($0.fileOffset) + Int($0.size)
        }

        // Strategy 1 — the symbol table, when the image kept one.
        if let va = MachOParser.findSymbol(containing: symbolFragment, in: data),
           let offset = MachOParser.vaToFileOffset(va, segments: segments),
           let site = makeSite(
               in: data,
               fileOffset: offset,
               virtualAddress: va,
               anchor: .symbolTable,
               textRange: textRange,
           )
        {
            return site
        }

        // Strategy 2 — ObjC metadata, which survives stripping.
        let (impVA, anchor) = try resolveIMPViaObjCMetadata(in: data, sections: sections)
        guard let offset = MachOParser.vaToFileOffset(impVA, segments: segments) else {
            throw PatcherError.invalidFormat(
                "\(method): IMP va 0x\(hex(impVA)) is in no mapped segment",
            )
        }
        guard let site = makeSite(
            in: data,
            fileOffset: offset,
            virtualAddress: impVA,
            anchor: anchor,
            textRange: textRange,
        ) else {
            throw PatcherError.patchSiteNotFound(
                "\(method): IMP at 0x\(hex(impVA)) (foff 0x\(hex(UInt64(offset)))) "
                    + "is outside __TEXT,__text or does not decode as instructions",
            )
        }
        return site
    }

    /// Build a ``Site`` when the candidate offset survives validation, else nil.
    ///
    /// Two checks, both semantic rather than positional: the offset must lie in
    /// the image's executable section, and the words there must decode — unless
    /// they are already this patch's own output, which is the idempotent case.
    static func makeSite(
        in data: Data,
        fileOffset: Int,
        virtualAddress: UInt64?,
        anchor: Anchor,
        textRange: Range<Int>?,
    ) -> Site? {
        let length = replacement.count
        guard fileOffset >= 0, fileOffset + length <= data.count else { return nil }
        if let textRange, !(textRange.contains(fileOffset) && textRange.contains(fileOffset + length - 1)) {
            return nil
        }

        let original = Data(data[fileOffset ..< fileOffset + length])
        let site = Site(
            fileOffset: fileOffset,
            virtualAddress: virtualAddress,
            anchor: anchor,
            original: original,
        )
        if site.isAlreadyPatched {
            return site
        }

        // `skipData` is on in the shared disassembler, so an undecodable word
        // arrives as a data pseudo-instruction (id 0) instead of ending the
        // stream — which is what makes this a usable "is this code?" test.
        let decoded = ARM64Disassembler().disassemble(
            original,
            at: virtualAddress ?? UInt64(fileOffset),
        )
        guard decoded.count == length / 4, decoded.allSatisfy({ $0.id != 0 }) else { return nil }
        return site
    }

    // MARK: - Recording

    private static func makeRecord(site: Site, patched: Data) -> PatchRecord {
        PatchRecord(
            patchID: patchID,
            component: component,
            fileOffset: site.fileOffset,
            virtualAddress: site.virtualAddress,
            originalBytes: site.original,
            patchedBytes: patched,
            beforeDisasm: disassemblyText(of: site.original, at: site.virtualAddress),
            afterDisasm: disassemblyText(of: patched, at: site.virtualAddress),
            description: "\(method) -> mov x0, #1; ret",
        )
    }

    // MARK: - Section helpers

    static let machMagic64: UInt32 = 0xFEED_FACF

    /// Executable section every anchor's answer has to land in.
    static let textSectionKey = "__TEXT,__text"

    /// Where modern toolchains put packed relative method lists.
    static let methodListSectionKey = "__TEXT,__objc_methlist"

    /// Sections the strided fallback scan walks, in order: the packed method
    /// lists again, then the older layouts where method lists sit inside
    /// `class_ro_t` records. The Python's list, plus `__objc_methlist`.
    static let scannedSectionKeys = [
        methodListSectionKey,
        "__DATA_CONST,__objc_const",
        "__DATA,__objc_const",
        "__AUTH_CONST,__objc_const",
    ]

    /// Selector cstrings live in the first of these that the image has.
    static let stringSectionKeys = ["__TEXT,__objc_methname", "__TEXT,__cstring"]

    /// `{uint32 entsizeAndFlags, uint32 count}`.
    static let methodListHeaderSize = 8
    /// Lists are laid out back to back on an 8-byte boundary.
    static let methodListAlignment = 8
    /// `entsizeAndFlags` bit 31 — entries are relative, not pointers.
    static let relativeMethodListFlag: UInt32 = 0x8000_0000
    /// The entry-size field, with the flag bits masked off.
    static let methodListEntrySizeMask: UInt32 = 0xFFFC
    /// `{int32 name, int32 types, int32 imp}`.
    static let relativeMethodEntrySize = 12
    /// `DYLD_CHAINED_PTR_64` rebase: `target` is the low 36 bits.
    static let chainedRebaseTargetMask: UInt64 = 0x0000_000F_FFFF_FFFF

    static func section(_ sections: [String: MachOSectionInfo], _ keys: String...) -> MachOSectionInfo? {
        for key in keys {
            if let section = sections[key] {
                return section
            }
        }
        return nil
    }

    /// The image's preferred load address: the `__TEXT` segment's `vmaddr`,
    /// read off the section table so no extra segment walk is needed.
    static func imageBase(_ sections: [String: MachOSectionInfo]) -> UInt64 {
        sections[textSectionKey].map { $0.address - UInt64($0.fileOffset) } ?? 0
    }

    /// Map a file offset back to a virtual address through the section table.
    ///
    /// Zero-fill sections (`__bss`, `__common`) carry a file offset of 0 and
    /// would otherwise claim the Mach-O header, so they are skipped. The
    /// candidates are walked in file order rather than in the dictionary's,
    /// which has no defined order — two runs over the same bytes must resolve
    /// the same address.
    static func virtualAddress(ofFileOffset offset: Int, sections: [String: MachOSectionInfo]) -> UInt64? {
        for section in sections.values.sorted(by: { $0.fileOffset < $1.fileOffset }) {
            let start = Int(section.fileOffset)
            guard start > 0 else { continue }
            if offset >= start, offset < start + Int(section.size) {
                return section.address + UInt64(offset - start)
            }
        }
        return nil
    }

    // MARK: - Formatting

    static func describe(_ site: Site) -> String {
        let va = site.virtualAddress.map { " va 0x\(hex($0))" } ?? ""
        return "foff 0x\(hex(UInt64(site.fileOffset)))\(va) [\(site.anchor.rawValue)]"
    }

    static func disassemblyText(of bytes: Data, at virtualAddress: UInt64?) -> String {
        ARM64Disassembler()
            .disassemble(bytes, at: virtualAddress ?? 0)
            .map { $0.operandString.isEmpty ? $0.mnemonic : "\($0.mnemonic) \($0.operandString)" }
            .joined(separator: "; ")
    }

    static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }

    static func alignUp(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }

    /// Zero-base a `Data` so the integer subscripts used throughout are valid.
    static func rebased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }
}
