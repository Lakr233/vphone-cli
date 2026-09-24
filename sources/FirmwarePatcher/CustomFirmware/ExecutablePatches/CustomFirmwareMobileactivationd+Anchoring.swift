import Foundation

extension CustomFirmwareMobileactivationd {
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

}
