import Foundation

extension DyldSharedCacheHypervisorVirtualMachinePatcher {
    /// One occurrence of the pristine cstring in a standalone Mach-O.
    public struct MachOStringSite: Sendable, Equatable {
        /// Address the literal is mapped at.
        public let stringVMA: UInt64
        /// Offset of the literal in the file.
        public let fileOffset: Int
        /// `"segment,section"` it was found in.
        public let section: String
    }

    /// Every pristine `"kern.hv_vmm_present\0"` in `data`'s string sections.
    ///
    /// Hits are anchored at a cstring boundary — the start of the section, or
    /// just after a NUL — so the tail of some longer literal that happens to end
    /// in these bytes is not returned.
    ///
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when `data` is not a 64-bit
    ///   little-endian Mach-O. A fat binary has to be sliced first.
    public static func findStringSites(inMachO data: Data) throws -> [MachOStringSite] {
        let image = data.startIndex == 0 ? data : Data(data)
        var sites: [MachOStringSite] = []
        for (name, section) in try machOSections(of: image)
            where cstringSectionNames.contains(section.sectionName)
        {
            let start = Int(section.fileOffset)
            let end = start + Int(section.size)
            guard start >= 0, end <= image.count, start <= end else { continue }
            let buffer = image[start ..< end]

            var searchFrom = buffer.startIndex
            while searchFrom < buffer.endIndex,
                  let found = buffer.range(of: needle, in: searchFrom ..< buffer.endIndex)
            {
                let position = found.lowerBound - buffer.startIndex
                if position == 0 || buffer[buffer.startIndex + position - 1] == 0 {
                    sites.append(
                        MachOStringSite(
                            stringVMA: section.address &+ UInt64(position),
                            fileOffset: start + position,
                            section: name,
                        ),
                    )
                }
                searchFrom = found.lowerBound + 1
            }
        }
        return sites
    }

    /// True when `data` holds the mangled form anywhere.
    ///
    /// Only for saying something useful in the log: ``findStringSites(inMachO:)``
    /// already returns nothing for an already-patched binary, so the patch flow
    /// is idempotent with or without this.
    public static func isAlreadyMangled(_ data: Data) -> Bool {
        data.range(of: mangledNeedle) != nil
    }

    // MARK: - Minimal Mach-O section table

    /// One `section_64`, reduced to what the string scan needs.
    struct MachOSection {
        let segmentName: String
        let sectionName: String
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt32
    }

    /// `LC_SEGMENT_64` sections of a thin 64-bit Mach-O, as
    /// `("segment,section", section)` pairs.
    ///
    /// Later sections with the same `"segment,section"` name replace earlier
    /// ones while keeping the earlier one's position, which is what the
    /// reference's dict does and is the only reason the two agree on the order
    /// sites come back in.
    static func machOSections(of data: Data) throws -> [(String, MachOSection)] {
        guard data.count >= 32 else {
            throw PatcherError.invalidFormat("truncated Mach-O header (\(data.count) bytes)")
        }
        let magic = data.loadLE(UInt32.self, at: 0)
        guard magic == 0xFEED_FACF else {
            throw PatcherError.invalidFormat(
                "not a 64-bit Mach-O (magic=0x\(String(magic, radix: 16, uppercase: true)))",
            )
        }

        let commandCount = Int(data.loadLE(UInt32.self, at: 16))
        var ordered: [String] = []
        var byName: [String: MachOSection] = [:]
        var offset = 32
        for _ in 0 ..< commandCount {
            guard offset + 8 <= data.count else { break }
            let command = data.loadLE(UInt32.self, at: offset)
            let commandSize = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard commandSize >= 8, offset + commandSize <= data.count else { break }

            if command == 0x19 { // LC_SEGMENT_64
                let segmentName = fixedWidthName(data, at: offset + 8)
                let sectionCount = Int(data.loadLE(UInt32.self, at: offset + 64))
                var sectionOffset = offset + 72
                for _ in 0 ..< sectionCount {
                    guard sectionOffset + 80 <= data.count else { break }
                    let sectionName = fixedWidthName(data, at: sectionOffset)
                    let key = "\(segmentName),\(sectionName)"
                    if byName[key] == nil {
                        ordered.append(key)
                    }
                    byName[key] = MachOSection(
                        segmentName: segmentName,
                        sectionName: sectionName,
                        address: data.loadLE(UInt64.self, at: sectionOffset + 32),
                        size: data.loadLE(UInt64.self, at: sectionOffset + 40),
                        fileOffset: data.loadLE(UInt32.self, at: sectionOffset + 48),
                    )
                    sectionOffset += 80
                }
            }
            offset += commandSize
        }
        return ordered.compactMap { key in byName[key].map { (key, $0) } }
    }

    /// A 16-byte NUL-padded Mach-O name field.
    private static func fixedWidthName(_ data: Data, at offset: Int) -> String {
        let start = data.startIndex + offset
        let end = min(start + 16, data.endIndex)
        guard start < end else { return "" }
        let field = data[start ..< end]
        let terminated = field.prefix { $0 != 0 }
        return String(decoding: terminated, as: UTF8.self)
    }

}
