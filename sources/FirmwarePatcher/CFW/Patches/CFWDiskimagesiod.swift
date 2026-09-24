// CFWDiskimagesiod.swift — force diskimagesiod's DDI mount-completion gate open.
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
// and `ARM64.ret` is the keystone-derived constant; `CFWDiskimagesiodTests`
// asserts the two agree with `ARM64.movX0_1`.
//
// Re-signing
// ──────────
// Off by default, matching the Python and the call site: `cfw_install.sh`
// re-signs the patched binary with `ldid` under the extracted
// `com.apple.diskimagesiod` entitlements, so a slot re-attest here would be
// overwritten moments later. `reattest: true` recomputes the CodeDirectory slot
// hashes through `CFWMachOCodeSignature` instead, which is what a caller that
// drops the `ldid` step needs — and what makes `codesign -v` pass on the patched
// file on its own.

import Capstone
import Foundation

/// Forces `-[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:]` to
/// return YES so MobileStorageMounter stops waiting on a mount that will never
/// be reported.
public enum CFWDiskimagesiod {
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
    /// no trap in it. `CFWDiskimagesiodTests` asserts the two spellings are the
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
            original == CFWDiskimagesiod.replacement
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
        public let rehashes: [CFWSlotRehash]

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

        var rehashes: [CFWSlotRehash] = []
        if reattest {
            // First and last byte of the write: an 8-byte span sits inside one
            // 4 KiB page here, but a page boundary between them would otherwise
            // leave the second page's slot stale.
            rehashes = try CFWMachOCodeSignature.reattest(
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

    // MARK: - ObjC metadata

    /// selector cstring → selref → method-list entry → IMP.
    static func resolveIMPViaObjCMetadata(
        in data: Data,
        sections: [String: MachOSectionInfo],
    ) throws -> (impVA: UInt64, anchor: Anchor) {
        guard let selectorVA = selectorStringVA(in: data, sections: sections) else {
            throw PatcherError.patchSiteNotFound(
                "\(component): selector '\(selector)' not present in the image",
            )
        }

        // A method-list `name` field points at the uniqued `SEL *` (the selref)
        // on every toolchain that emits `__objc_selrefs`, and straight at the
        // cstring in a "direct selector" list. Both are accepted, exactly as
        // the Python does, so a missing selref is not fatal on its own.
        var targets: Set<UInt64> = [selectorVA]
        if let selrefsSection = section(sections, "__DATA_CONST,__objc_selrefs", "__DATA,__objc_selrefs", "__AUTH_CONST,__objc_selrefs"),
           let selrefVA = selectorReferenceVA(
               in: data,
               selrefs: selrefsSection,
               selectorVA: selectorVA,
               imageBase: imageBase(sections),
           )
        {
            targets.insert(selrefVA)
        }

        // Preferred: a structural walk of the packed relative method lists.
        if let methlist = sections[methodListSectionKey] {
            let imps = relativeMethodListIMPs(in: data, section: methlist, naming: targets)
            if let impVA = try single(imps, strategy: methodListSectionKey) {
                return (impVA, .relativeMethodList)
            }
        }

        // Fallback: the Python's own strategy, a 4-byte-strided scan, over the
        // same sections it tries. It covers two cases the structural walk does
        // not — a `__TEXT,__objc_methlist` whose list chain this parser cannot
        // follow to the end, and the older layout where method lists are
        // embedded in `class_ro_t` records inside an `__objc_const` section and
        // so are not packed back to back. Running it over the method-list
        // section too is what keeps this port from ever being *less* capable
        // than the Python it replaces. Every candidate still has to resolve to
        // a single agreed-upon IMP, and that IMP still has to pass ``makeSite``.
        for key in scannedSectionKeys {
            guard let scanned = sections[key] else { continue }
            let imps = scanRelativeMethodEntryIMPs(in: data, section: scanned, naming: targets)
            if let impVA = try single(imps, strategy: key) {
                return (impVA, .methodListScan)
            }
        }

        throw PatcherError.patchSiteNotFound(
            "\(method): no ObjC method-list entry names '\(selector)'",
        )
    }

    /// The single distinct IMP in `candidates`, `nil` when there are none.
    ///
    /// More than one distinct IMP means the image names this selector from
    /// several implementations and the patch has no unambiguous target — which
    /// stops the install rather than picking one.
    static func single(_ candidates: [UInt64], strategy: String) throws -> UInt64? {
        let distinct = Set(candidates)
        guard let first = distinct.first else { return nil }
        guard distinct.count == 1 else {
            let list = distinct.sorted().map { "0x\(hex($0))" }.joined(separator: ", ")
            throw PatcherError.invalidFormat(
                "\(method): \(strategy) names '\(selector)' from \(distinct.count) "
                    + "implementations (\(list)) — no unambiguous target",
            )
        }
        return first
    }

    /// Virtual address of the selector cstring.
    ///
    /// Looked for in `__TEXT,__objc_methname` first — the section that exists
    /// for exactly this — then `__TEXT,__cstring`, then anywhere in the file,
    /// which is the Python's only search. A hit has to start a string (the
    /// preceding byte is NUL, or it is the first byte of its section) so a
    /// selector that is the tail of a longer one cannot match.
    static func selectorStringVA(in data: Data, sections: [String: MachOSectionInfo]) -> UInt64? {
        let needle = Data(selector.utf8) + [0]

        for key in stringSectionKeys {
            guard let section = sections[key] else { continue }
            let start = Int(section.fileOffset)
            let end = start + Int(section.size)
            guard start >= 0, end <= data.count, start < end else { continue }
            guard let found = firstStringStart(of: needle, in: data, range: start ..< end) else { continue }
            return section.address + UInt64(found - start)
        }

        guard let found = firstStringStart(of: needle, in: data, range: 0 ..< data.count) else { return nil }
        return virtualAddress(ofFileOffset: found, sections: sections)
    }

    /// First occurrence of `needle` in `range` that begins a C string.
    static func firstStringStart(of needle: Data, in data: Data, range: Range<Int>) -> Int? {
        var searchFrom = range.lowerBound
        while searchFrom < range.upperBound,
              let found = data.range(of: needle, in: searchFrom ..< range.upperBound)
        {
            if found.lowerBound == range.lowerBound || data[found.lowerBound - 1] == 0 {
                return found.lowerBound
            }
            searchFrom = found.lowerBound + 1
        }
        return nil
    }

    /// The `__objc_selrefs` slot pointing at `selectorVA`.
    ///
    /// The slot holds a *chained fixup*, not a linked address, so the raw
    /// quadword rarely equals the target. Four interpretations are tried in
    /// decreasing strictness, and the first that matches anywhere in the
    /// section wins:
    ///
    ///   1. the value itself — an already-linked or non-chained image;
    ///   2. `DYLD_CHAINED_PTR_64` rebase: the low 36 bits are an offset from the
    ///      image's preferred base, the rest are `high8` / `next` / `bind`;
    ///   3. the low 48 bits, for the older 8-byte fixup spellings;
    ///   4. the low 32 bits, which is the Python's catch-all.
    static func selectorReferenceVA(
        in data: Data,
        selrefs: MachOSectionInfo,
        selectorVA: UInt64,
        imageBase: UInt64,
    ) -> UInt64? {
        let start = Int(selrefs.fileOffset)
        let count = Int(selrefs.size)
        guard start >= 0, start + count <= data.count else { return nil }

        let matchers: [(UInt64) -> Bool] = [
            { $0 == selectorVA },
            { imageBase &+ ($0 & chainedRebaseTargetMask) == selectorVA },
            { ($0 & 0x0000_FFFF_FFFF_FFFF) == selectorVA },
            { ($0 & 0xFFFF_FFFF) == (selectorVA & 0xFFFF_FFFF) },
        ]
        for matches in matchers {
            var offset = 0
            while offset + 8 <= count {
                if matches(data.loadLE(UInt64.self, at: start + offset)) {
                    return selrefs.address + UInt64(offset)
                }
                offset += 8
            }
        }
        return nil
    }

    // MARK: - Method lists

    /// Walk `__TEXT,__objc_methlist` as what it is: relative method lists laid
    /// end to end, each one 8-byte aligned.
    ///
    /// A list is `{uint32 entsizeAndFlags, uint32 count}` followed by `count`
    /// entries of `entsizeAndFlags & 0xFFFC` bytes. Bit 31 marks the relative
    /// form, whose entry is three `int32` fields — `name`, `types`, `imp` —
    /// each relative to *its own* address.
    ///
    /// Returns the IMP virtual address of every entry whose `name` field
    /// resolves into `targets`.
    static func relativeMethodListIMPs(
        in data: Data,
        section: MachOSectionInfo,
        naming targets: Set<UInt64>,
    ) -> [UInt64] {
        let base = Int(section.fileOffset)
        let size = Int(section.size)
        guard base >= 0, size > 0, base + size <= data.count else { return [] }

        var found: [UInt64] = []
        var offset = 0
        while offset + methodListHeaderSize <= size {
            let header = data.loadLE(UInt32.self, at: base + offset)
            let count = Int(data.loadLE(UInt32.self, at: base + offset + 4))
            let entrySize = Int(header & methodListEntrySizeMask)
            guard header & relativeMethodListFlag != 0,
                  entrySize == relativeMethodEntrySize,
                  count > 0,
                  methodListHeaderSize + entrySize * count <= size - offset
            else { break }

            let entriesStart = offset + methodListHeaderSize
            for index in 0 ..< count {
                let entryOffset = entriesStart + index * entrySize
                if let impVA = relativeMethodEntryIMP(
                    in: data,
                    fileOffset: base + entryOffset,
                    virtualAddress: section.address + UInt64(entryOffset),
                    naming: targets,
                ) {
                    found.append(impVA)
                }
            }

            offset = alignUp(entriesStart + entrySize * count, to: methodListAlignment)
        }
        return found
    }

    /// The Python's strategy, kept for the layouts the structural walk cannot
    /// parse: treat every 4-byte-aligned word in `section` as the `name` field
    /// of a relative method entry and keep the ones that resolve into `targets`.
    static func scanRelativeMethodEntryIMPs(
        in data: Data,
        section: MachOSectionInfo,
        naming targets: Set<UInt64>,
    ) -> [UInt64] {
        let base = Int(section.fileOffset)
        let size = Int(section.size)
        guard base >= 0, size >= relativeMethodEntrySize, base + size <= data.count else { return [] }

        var found: [UInt64] = []
        var offset = 0
        while offset + relativeMethodEntrySize <= size {
            if let impVA = relativeMethodEntryIMP(
                in: data,
                fileOffset: base + offset,
                virtualAddress: section.address + UInt64(offset),
                naming: targets,
            ) {
                found.append(impVA)
            }
            offset += 4
        }
        return found
    }

    /// `imp` of the relative method entry at `fileOffset`, when its `name`
    /// field resolves into `targets`.
    static func relativeMethodEntryIMP(
        in data: Data,
        fileOffset: Int,
        virtualAddress: UInt64,
        naming targets: Set<UInt64>,
    ) -> UInt64? {
        guard fileOffset >= 0, fileOffset + relativeMethodEntrySize <= data.count else { return nil }
        let nameRelative = Int32(bitPattern: data.loadLE(UInt32.self, at: fileOffset))
        let nameVA = UInt64(bitPattern: Int64(bitPattern: virtualAddress) &+ Int64(nameRelative))
        guard targets.contains(nameVA) else { return nil }

        let impFieldOffset = fileOffset + 8
        let impFieldVA = virtualAddress &+ 8
        let impRelative = Int32(bitPattern: data.loadLE(UInt32.self, at: impFieldOffset))
        return UInt64(bitPattern: Int64(bitPattern: impFieldVA) &+ Int64(impRelative))
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
