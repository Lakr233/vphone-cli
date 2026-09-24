import Foundation

extension CustomFirmwareDiskimagesiod {
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

}
