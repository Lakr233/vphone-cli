// CustomFirmwareMobileactivationd.swift — force `-[DeviceType should_hactivate]` to YES.
//
// Swift port of `scripts/patchers/cfw_patch_mobileactivationd.py`, driven by
// `cfw.py patch-mobileactivationd <binary>` from `cfw_install{,_dev}.sh` and
// `cfw-kit/lib/base_stages.sh`'s `stage_mobileactivationd`.
//
// `mobileactivationd` asks `-[DeviceType should_hactivate]` whether the device
// may activate itself without talking to albert.apple.com. On a real iPhone the
// answer is NO and Setup.app sits on the activation screen forever, which is
// where an unpatched guest ends up. The method is a synthesised `_BOOL` ivar
// getter — two instructions, `ldrb w0, [x0, #<ivar>]` then `ret` — so forcing
// YES is `mov x0, #1 ; ret` over the same eight bytes. No cave, no shifting.
//
// Anchoring, and why it is not the Python's
// ----------------------------------------
// The Python takes two shortcuts this does not copy.
//
//   1. It resolves the IMP with a *substring* search over LC_SYMTAB
//      (`find_symbol_va(data, "should_hactivate")`) and patches the first hit.
//      On the iOS 27.0 / 24A435 iPhone17,3 binary four symbols contain that
//      substring — the method, `_objc_msgSend$should_hactivate` (a selector
//      stub in `__TEXT,__objc_stubs`), `_OBJC_IVAR_$_DeviceType._should_hactivate`
//      (a *data* offset in `__DATA`) and a duplicate N_STAB debug entry. It
//      works today only because the method happens to sort first. Patching the
//      ivar-offset word instead would corrupt every access to the ivar.
//      Here the symbol is matched by its exact ObjC name, STAB debug entries
//      are skipped, and the symbol must be N_SECT-defined.
//
//   2. Its ObjC-metadata fallback is dead code on this binary, twice over: it
//      takes the first `memmem` hit for `should_hactivate\0`, which lands at
//      the tail of the property-attribute string `TB,R,N,V_should_hactivate`
//      — the `V` field naming the backing ivar — 0x2F4D bytes before the real
//      selector; and it looks for relative method lists in `__objc_const`,
//      where iOS 16+ no longer puts them (they live in
//      `__TEXT,__objc_methlist`). Called directly on the pristine binary it
//      prints "Selref not found (chained fixups may obscure pointers)" and
//      returns -1. The fallback here finds the NUL-preceded selector,
//      unpacks chained-fixup rebase targets, and walks real relative method
//      lists — so it resolves the same IMP the symbol table does, which is how
//      the anchor is cross-checked rather than trusted.
//
// Both routes run. When both resolve they must agree, or the binary is not the
// shape we were told it was and the run stops. Nothing is a literal address.
//
// Re-attestation
// --------------
// `codeSigningMonitor == 2` on this stack, so TXM holds the original per-page
// slot hashes and any byte changed inside an executable mapping is a SIGKILL on
// first page-in. The touched page is re-hashed through `CustomFirmwareMachOCodeSignature`.
// The Python leaves that to the `ldid_sign` that follows it in the shell; doing
// it here means the binary is runnable the moment it is written, and the later
// `ldid_sign` stays a no-op-in-effect re-sign. Pass `resign: false` to get the
// Python's exact bytes.

import Capstone
import Foundation

/// Forces `-[DeviceType should_hactivate]` to return YES, so the guest
/// self-activates instead of waiting on Apple's activation service.
public enum CustomFirmwareMobileactivationd {
    // MARK: - Identity

    /// The ObjC method whose result is forced.
    public static let method = "-[DeviceType should_hactivate]"

    /// The selector, as it appears in `__TEXT,__objc_methname`.
    public static let selector = "should_hactivate"

    /// Component name, matching `records.set_group("mobileactivationd")`.
    public static let component = "mobileactivationd"

    /// Record identity, matching the Python's `records.site` label so a captured
    /// reference and this port sort together.
    public static let patchID = "mobileactivationd.should_hactivate"

    /// Where progress goes when the caller does not say. The Python prints to
    /// stdout and `cfw_install*.sh` captures that, so this does too.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Results

    /// Which anchor produced the IMP address.
    public enum AnchorSource: String, Sendable, Equatable {
        /// Both the symbol table and the ObjC metadata chain resolved, and agreed.
        case symbolTableAndObjCMetadata
        /// Only `LC_SYMTAB` carried the method — a binary whose ObjC metadata
        /// this port cannot walk (a layout change), but whose symbol is exact.
        case symbolTable
        /// Only the ObjC metadata chain resolved — a stripped binary.
        case objcMetadata
    }

    /// The located IMP.
    public struct Anchor: Sendable, Equatable {
        public let virtualAddress: UInt64
        public let fileOffset: Int
        public let source: AnchorSource
        /// `segment,section` the IMP lands in. Always an executable one.
        public let section: String
    }

    /// What a run did.
    public enum Outcome: String, Sendable, Equatable {
        /// The eight bytes already read `mov x0, #1 ; ret`. Nothing was written.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The getter was rewritten and its page re-attested.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        public let anchor: Anchor
        /// The write, in the shape the Python's reference capture records it.
        /// `nil` unless bytes actually changed.
        public let record: PatchRecord?
        /// Code-directory slots recomputed for the page the write landed in.
        /// Empty on a dry run, and on a re-run whose slots already match.
        public let slotRehashes: [CustomFirmwareSlotRehash]

        /// Sites whose bytes this run changed. The parity number: the Python
        /// writes exactly one, and so must this.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }
    }

    // MARK: - Patching

    /// Patch the `mobileactivationd` at `url` in place.
    ///
    /// Idempotent: a second run finds `mov x0, #1 ; ret` already in place,
    /// reports ``Outcome/alreadyPatched`` and leaves the file untouched, byte
    /// for byte. It does not error and it does not write the getter twice.
    ///
    /// - Parameters:
    ///   - url: The `mobileactivationd` Mach-O to patch.
    ///   - resign: Recompute the code-directory slot hash of the touched page.
    ///     `false` reproduces the Python's output exactly, for byte comparison.
    ///   - dryRun: Locate and report, write nothing.
    /// - Throws: ``PatcherError/patchSiteNotFound(_:)`` when neither anchor
    ///   resolves, ``PatcherError/invalidFormat(_:)`` when the two anchors
    ///   disagree or the site is not executable code.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        resign: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patch(&data, resign: resign, dryRun: dryRun, log: log)

        // Written only when something changed, so a no-op run does not even
        // touch the file's mtime — and so `sha256` before and after a re-run
        // is trivially the same number.
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form of ``patch(fileAt:resign:dryRun:log:)``.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        resign: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let anchor = try locateIMP(in: data)
        log?("  [.] \(method) @ 0x\(hex(anchor.virtualAddress)) "
            + "-> foff 0x\(hex(UInt64(anchor.fileOffset))) "
            + "in \(anchor.section) (via \(anchor.source.rawValue))")

        let patched = try replacementBytes()
        guard data.count >= anchor.fileOffset + patched.count else {
            throw PatcherError.invalidFormat(
                "\(method): IMP at 0x\(hex(UInt64(anchor.fileOffset))) is past the end of the file",
            )
        }
        let original = Data(data[anchor.fileOffset ..< anchor.fileOffset + patched.count])
        let body = try decodeBody(original, at: anchor.virtualAddress)

        log?("      [.] before: \(text(of: body))")

        if original == patched {
            // The already-patched shape, recognised rather than re-applied.
            // `8eb6c8b` fixed this exact class of bug for the DSC gates.
            log?("      [=] already `mov x0, #1 ; ret` at 0x\(hex(anchor.virtualAddress)); "
                + "nothing to write")
            let rehashes = dryRun || !resign
                ? []
                : try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: touchedOffsets(anchor, patched))
            if !rehashes.isEmpty {
                log?("      [+] re-attested \(rehashes.count) stale slot(s): "
                    + rehashes.map(\.description).joined(separator: ", "))
            }
            return Report(
                outcome: .alreadyPatched,
                anchor: anchor,
                record: nil,
                slotRehashes: rehashes,
            )
        }

        guard isPlausibleGetterBody(body) else {
            throw PatcherError.invalidFormat(
                "\(method): body at 0x\(hex(anchor.virtualAddress)) reads `\(text(of: body))`, "
                    + "which is not a two-instruction body this patch can replace",
            )
        }

        guard !dryRun else {
            log?("      [.] dry-run: would write \(original.hex) -> \(patched.hex) "
                + "at foff 0x\(hex(UInt64(anchor.fileOffset)))")
            return Report(outcome: .wouldPatch, anchor: anchor, record: nil, slotRehashes: [])
        }

        data.replaceSubrange(anchor.fileOffset ..< anchor.fileOffset + patched.count, with: patched)
        try log?("      [+] after:  \(text(of: decodeBody(patched, at: anchor.virtualAddress)))")

        let written = Data(data[anchor.fileOffset ..< anchor.fileOffset + patched.count])
        guard written == patched else {
            throw PatcherError.patchVerificationFailed(
                "\(method): site at 0x\(hex(UInt64(anchor.fileOffset))) reads \(written.hex) after write",
            )
        }

        var rehashes: [CustomFirmwareSlotRehash] = []
        if resign {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(
                &data,
                modifiedOffsets: touchedOffsets(anchor, patched),
            )
            log?("  [.] re-attested \(rehashes.count) slot(s): "
                + rehashes.map(\.description).joined(separator: ", "))
            let unsupported = CustomFirmwareMachOCodeSignature.unsupportedCodeDirectories(in: data)
            if !unsupported.isEmpty {
                log?("      [-] \(unsupported.count) non-SHA256 CodeDirectory(ies) left alone")
            }
        }

        log?("  [+] Patched at 0x\(hex(UInt64(anchor.fileOffset))): mov x0, #1; ret")
        return try Report(
            outcome: .patched,
            anchor: anchor,
            record: PatchRecord(
                patchID: patchID,
                component: component,
                fileOffset: anchor.fileOffset,
                virtualAddress: anchor.virtualAddress,
                originalBytes: original,
                patchedBytes: patched,
                beforeDisasm: text(of: body),
                afterDisasm: text(of: decodeBody(patched, at: anchor.virtualAddress)),
                description: "\(method) -> mov x0, #1; ret",
            ),
            slotRehashes: rehashes,
        )
    }

    // MARK: - Replacement

    /// `mov x0, #1 ; ret`, assembled rather than written down.
    ///
    /// The MOVZ comes out of ``ARM64Encoder``, whose every encoder is asserted
    /// against keystone; `ret` has no operands to encode, so it is the shared
    /// keystone-generated constant — the same split the Python makes between
    /// `asm("mov x0, #1")` and its `RET`.
    static func replacementBytes() throws -> Data {
        guard let mov = ARM64Encoder.encodeMovzX(rd: 0, imm16: 1) else {
            throw PatcherError.invalidFormat("could not encode `mov x0, #1`")
        }
        return mov + ARM64.ret
    }

    /// The file offsets whose pages need re-hashing. Both words are listed, not
    /// just the first: a getter whose second instruction begins a new 4 KiB page
    /// dirties two slots, and hashing only the first would leave the tail slot
    /// stale — a SIGKILL the first time that page is demand-paged in.
    static func touchedOffsets(_ anchor: Anchor, _ patched: Data) -> [Int] {
        stride(from: anchor.fileOffset, to: anchor.fileOffset + patched.count, by: 4).map(\.self)
    }

    // MARK: - Anchoring

    /// Resolve the IMP of ``method``, by symbol and by ObjC metadata.
    ///
    /// Both routes are independent: one reads `LC_SYMTAB`, the other walks
    /// `__objc_methname` -> `__objc_selrefs` -> relative method list. When both
    /// answer they must give the same address.
    public static func locateIMP(in data: Data) throws -> Anchor {
        let data = data.startIndex == 0 ? data : Data(data)
        let segments = MachOParser.parseSegments(from: data)
        guard !segments.isEmpty else {
            throw PatcherError.invalidFormat("not a 64-bit Mach-O, or it carries no LC_SEGMENT_64")
        }

        let bySymbol = symbolVirtualAddress(in: data)
        let byMetadata = objcMetadataVirtualAddress(in: data, segments: segments)

        let source: AnchorSource
        let virtualAddress: UInt64
        switch (bySymbol, byMetadata) {
        case let (symbol?, metadata?):
            guard symbol == metadata else {
                throw PatcherError.invalidFormat(
                    "\(method): symbol table says 0x\(hex(symbol)) but the ObjC method list "
                        + "says 0x\(hex(metadata)) — refusing to guess which is the IMP",
                )
            }
            source = .symbolTableAndObjCMetadata
            virtualAddress = symbol
        case let (symbol?, nil):
            source = .symbolTable
            virtualAddress = symbol
        case let (nil, metadata?):
            source = .objcMetadata
            virtualAddress = metadata
        case (nil, nil):
            throw PatcherError.patchSiteNotFound(
                "\(method): neither LC_SYMTAB nor the ObjC method lists carry it",
            )
        }

        guard let fileOffset = MachOParser.vaToFileOffset(virtualAddress, segments: segments) else {
            throw PatcherError.invalidFormat(
                "\(method): VA 0x\(hex(virtualAddress)) maps to no segment",
            )
        }
        guard let section = executableSection(containing: virtualAddress, in: data) else {
            throw PatcherError.invalidFormat(
                "\(method): VA 0x\(hex(virtualAddress)) is not inside an executable section — "
                    + "the anchor resolved to data, not code",
            )
        }

        return Anchor(
            virtualAddress: virtualAddress,
            fileOffset: fileOffset,
            source: source,
            section: section,
        )
    }

    /// The VA of the `LC_SYMTAB` entry whose name is exactly ``method``.
    ///
    /// Exact, not a substring: `_objc_msgSend$should_hactivate` and
    /// `_OBJC_IVAR_$_DeviceType._should_hactivate` both contain the selector and
    /// neither is the IMP. N_STAB debug entries are skipped — the same address
    /// arrives twice on this binary, once as N_SECT and once as N_FUN — and the
    /// symbol must be section-defined with a non-zero value.
    static func symbolVirtualAddress(in data: Data) -> UInt64? {
        guard let symtab = MachOParser.parseSymtab(from: data) else { return nil }
        // <mach-o/nlist.h>: N_STAB masks off the debug entries, N_TYPE selects
        // the kind, and N_SECT is the one kind that means "defined in a section".
        let nStab: UInt8 = 0xE0
        let nTypeMask: UInt8 = 0x0E
        let nSect: UInt8 = 0x0E

        for index in 0 ..< symtab.nsyms {
            let entry = symtab.symoff + index * 16 // sizeof(nlist_64)
            guard entry + 16 <= data.count else { break }

            let typeByte = data[entry + 4]
            guard typeByte & nStab == 0, typeByte & nTypeMask == nSect else { continue }

            let strx = Int(data.loadLE(UInt32.self, at: entry))
            let value = data.loadLE(UInt64.self, at: entry + 8)
            guard value != 0, strx < symtab.strsize else { continue }

            guard let name = cString(in: data, at: symtab.stroff + strx,
                                     limit: symtab.stroff + symtab.strsize) else { continue }
            if name == method {
                return value
            }
        }
        return nil
    }

    /// The VA of the IMP, walked out of the ObjC metadata:
    /// `__objc_methname` selector -> `__objc_selrefs` entry -> the relative
    /// method-list entry whose `name` field points at that selref -> its `imp`.
    static func objcMetadataVirtualAddress(
        in data: Data,
        segments: [MachOSegmentInfo],
    ) -> UInt64? {
        let sections = MachOParser.parseSections(from: data)
        guard let imageBase = segments.first(where: { $0.name == "__TEXT" })?.vmAddr else {
            return nil
        }
        guard let selectorVA = selectorVirtualAddress(in: data, sections: sections) else {
            return nil
        }
        guard let selrefVA = selectorReferenceVirtualAddress(
            to: selectorVA, in: data, sections: sections, imageBase: imageBase,
        ) else { return nil }

        return methodImplementation(
            forSelectorReference: selrefVA, in: data, sections: sections,
        )
    }

    /// The selector string's VA — the whole string ``selector``, not a suffix of
    /// a longer one.
    ///
    /// `DeviceType`'s property-attribute string `TB,R,N,V_should_hactivate`
    /// names the backing ivar and sits earlier in the very same section, so a
    /// plain `memmem` for `should_hactivate\0` — what the Python does — hits its
    /// tail first. Requiring the preceding byte to be the previous string's NUL
    /// is what separates a whole selector from a suffix of something longer.
    static func selectorVirtualAddress(
        in data: Data,
        sections: [String: MachOSectionInfo],
    ) -> UInt64? {
        let candidates = ["__TEXT,__objc_methname", "__DATA,__objc_methname"]
        guard let section = candidates.compactMap({ sections[$0] }).first else { return nil }

        let start = Int(section.fileOffset)
        let end = start + Int(section.size)
        guard start >= 0, end <= data.count, start < end else { return nil }

        let needle = Data(selector.utf8) + Data([0])
        var cursor = start
        while cursor + needle.count <= end {
            guard let found = data[cursor ..< end].range(of: needle) else { return nil }
            let offset = found.lowerBound
            // The first string in the section needs no separator before it.
            if offset == start || data[offset - 1] == 0 {
                return section.address + UInt64(offset - start)
            }
            cursor = offset + 1
        }
        return nil
    }

    /// The `__objc_selrefs` slot that points at `selectorVA`.
    ///
    /// The slots are chained-fixup rebases on this stack, not plain pointers, so
    /// the raw word is matched three ways: as-is (an already-bound pointer), as a
    /// 36-bit rebase target relative to the image base, and as an absolute 36-bit
    /// target. Whichever form the binary uses, the resolved address has to be the
    /// selector's.
    static func selectorReferenceVirtualAddress(
        to selectorVA: UInt64,
        in data: Data,
        sections: [String: MachOSectionInfo],
        imageBase: UInt64,
    ) -> UInt64? {
        let candidates = [
            "__DATA,__objc_selrefs",
            "__DATA_CONST,__objc_selrefs",
            "__AUTH_CONST,__objc_selrefs",
        ]
        guard let section = candidates.compactMap({ sections[$0] }).first else { return nil }

        let start = Int(section.fileOffset)
        let count = Int(section.size)
        guard start >= 0, start + count <= data.count else { return nil }

        // dyld_chained_ptr_64_rebase.target is 36 bits wide.
        let targetMask: UInt64 = (1 << 36) - 1

        for slot in stride(from: 0, to: count - 7, by: 8) {
            let raw = data.loadLE(UInt64.self, at: start + slot)
            let target = raw & targetMask
            if raw == selectorVA || target == selectorVA || imageBase &+ target == selectorVA {
                return section.address + UInt64(slot)
            }
        }
        return nil
    }

    /// The IMP of the relative-method-list entry whose `name` field resolves to
    /// `selrefVA`.
    ///
    /// iOS 16+ stores "small" method lists — three `int32`s per entry, each
    /// relative to its own field's address — in `__TEXT,__objc_methlist`. The
    /// Python looks in `__objc_const`, which is why its fallback never fires.
    /// Both are searched here, so an older layout still resolves.
    static func methodImplementation(
        forSelectorReference selrefVA: UInt64,
        in data: Data,
        sections: [String: MachOSectionInfo],
    ) -> UInt64? {
        let candidates = [
            "__TEXT,__objc_methlist",
            "__DATA,__objc_const",
            "__DATA_CONST,__objc_const",
            "__AUTH_CONST,__objc_const",
        ]
        for name in candidates {
            guard let section = sections[name] else { continue }
            if let imp = methodImplementation(
                forSelectorReference: selrefVA, in: data, section: section,
            ) {
                return imp
            }
        }
        return nil
    }

    /// Walk one section as a run of relative method lists.
    ///
    /// Each list is `{ uint32 entsizeAndFlags; uint32 count; }` followed by
    /// `count` 12-byte entries, and the next list starts at the following 8-byte
    /// boundary. A header that is not a 12-byte-entry small list ends the walk:
    /// past it the bytes are no longer method lists, and matching an "entry" in
    /// them would be matching noise.
    static func methodImplementation(
        forSelectorReference selrefVA: UInt64,
        in data: Data,
        section: MachOSectionInfo,
    ) -> UInt64? {
        let smallMethodListFlag: UInt32 = 0x8000_0000
        let entrySizeMask: UInt32 = 0x0000_FFFC
        let entrySize = 12

        let base = Int(section.fileOffset)
        let size = Int(section.size)
        guard base >= 0, base + size <= data.count else { return nil }

        var cursor = 0
        while cursor + 8 <= size {
            let header = data.loadLE(UInt32.self, at: base + cursor)
            let count = Int(data.loadLE(UInt32.self, at: base + cursor + 4))
            guard header & smallMethodListFlag != 0,
                  Int(header & entrySizeMask) == entrySize,
                  count > 0,
                  cursor + 8 + count * entrySize <= size
            else { return nil }

            for index in 0 ..< count {
                let entry = cursor + 8 + index * entrySize
                let entryVA = section.address + UInt64(entry)
                let nameDelta = Int(data.loadLE(Int32.self, at: base + entry))
                guard UInt64(bitPattern: Int64(entryVA) + Int64(nameDelta)) == selrefVA else {
                    continue
                }
                // { name, types, imp } — the imp field is 8 bytes in, and its
                // delta is relative to the imp field's own address.
                let impField = entryVA + 8
                let impDelta = Int(data.loadLE(Int32.self, at: base + entry + 8))
                return UInt64(bitPattern: Int64(impField) + Int64(impDelta))
            }
            cursor += 8 + count * entrySize
            cursor = (cursor + 7) & ~7
        }
        return nil
    }

    /// `segment,section` of the executable section containing `va`, or nil when
    /// the address is not in one.
    ///
    /// Executability is read off the segment's `initprot`, not off the segment's
    /// name, so this keeps working if the IMP ever lives somewhere other than
    /// `__TEXT,__text`.
    static func executableSection(containing va: UInt64, in data: Data) -> String? {
        let vmProtExecute: UInt32 = 0x4
        var executableSegments: Set<String> = []

        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32 // sizeof(mach_header_64)
        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard cmdsize > 0 else { break }
            if cmd == 0x19, offset + 64 <= data.count { // LC_SEGMENT_64
                let initprot = data.loadLE(UInt32.self, at: offset + 60)
                if initprot & vmProtExecute != 0 {
                    let raw = data[offset + 8 ..< offset + 24]
                    executableSegments.insert(
                        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self),
                    )
                }
            }
            offset += cmdsize
        }

        for (key, section) in MachOParser.parseSections(from: data)
            where executableSegments.contains(section.segmentName)
            && va >= section.address && va < section.address + section.size
        {
            return key
        }
        return nil
    }

    // MARK: - Body Shape

    /// Decode the eight bytes the patch replaces.
    static func decodeBody(_ bytes: Data, at va: UInt64) throws -> [Instruction] {
        let decoded = ARM64Disassembler().disassemble(bytes, at: va, count: 2)
        guard decoded.count == 2, decoded.allSatisfy({ $0.id != 0 }) else {
            throw PatcherError.invalidFormat(
                "\(method): the eight bytes at 0x\(hex(va)) (\(bytes.hex)) are not two "
                    + "decodable instructions",
            )
        }
        return decoded
    }

    /// Whether the decoded body is something this patch may overwrite.
    ///
    /// The method is a synthesised BOOL getter, so the shape to expect is a
    /// single-register load followed by `ret`. The check is deliberately on the
    /// *return* — a two-word body ending in `ret`, or a first instruction that
    /// is a plain function entry — rather than on `ldrb` specifically: a future
    /// build may spell the getter differently, but overwriting eight bytes that
    /// are *not* a function's first two words would land mid-function.
    static func isPlausibleGetterBody(_ body: [Instruction]) -> Bool {
        guard body.count == 2 else { return false }
        // A getter: `ldr…/mov… ; ret`.
        if body[1].mnemonic == "ret" || body[1].mnemonic.hasPrefix("reta") {
            return true
        }
        // A real function: a recognisable prologue in the first word, so the
        // eight bytes are the head of a function and an early return is safe.
        let prologue: Set = ["pacibsp", "paciasp", "stp", "sub"]
        return prologue.contains(body[0].mnemonic)
    }

    // MARK: - Helpers

    static func text(of instructions: [Instruction]) -> String {
        instructions
            .map { $0.operandString.isEmpty ? $0.mnemonic : "\($0.mnemonic) \($0.operandString)" }
            .joined(separator: "; ")
    }

    /// Read a NUL-terminated ASCII string, refusing to run past `limit`.
    static func cString(in data: Data, at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < min(limit, data.count) else { return nil }
        var end = offset
        let stop = min(limit, data.count)
        while end < stop, data[end] != 0 {
            end += 1
        }
        return String(data: data[offset ..< end], encoding: .ascii)
    }

    static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
