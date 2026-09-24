// MachOParser.swift — Mach-O parsing utilities for firmware patching.

import Foundation

// MARK: - Segment/Section Info

/// Minimal segment info extracted from a Mach-O binary.
public struct MachOSegmentInfo: Sendable {
    public let name: String
    public let vmAddr: UInt64
    public let vmSize: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
}

/// Minimal section info extracted from a Mach-O binary.
public struct MachOSectionInfo: Sendable {
    public let segmentName: String
    public let sectionName: String
    public let address: UInt64
    public let size: UInt64
    public let fileOffset: UInt32
}

// MARK: - MachO Parser

/// Mach-O parsing utilities for kernel/firmware binary analysis.
public enum MachOParser {
    /// `sizeof(segment_command_64)` — the fixed part, before the section table.
    static let segmentCommand64Size = 72
    /// `sizeof(section_64)`.
    static let section64Size = 80
    /// `sizeof(symtab_command)`.
    static let symtabCommandSize = 24

    /// Walk the load-command table, handing `body` only those commands whose
    /// whole body lies inside the buffer.
    ///
    /// The bound matters: `Data.loadLE` is a `precondition`, so a read past the
    /// end kills the process with SIGTRAP rather than raising anything a caller
    /// could catch. A header claiming more (or larger) commands than the file
    /// holds — a truncated download, a half-written patch — used to walk right
    /// off the end. Now the walk stops at the first command that does not fit,
    /// and the caller sees an empty/partial result it can reject normally.
    static func forEachLoadCommand(
        in data: Data,
        _ body: (_ cmd: UInt32, _ offset: Int, _ cmdsize: Int) -> Void,
    ) {
        guard data.count > 32 else { return }
        let ncmds = data.loadLE(UInt32.self, at: 16)
        var offset = 32 // sizeof(mach_header_64)

        for _ in 0 ..< ncmds {
            guard offset + 8 <= data.count else { return }
            let cmd = data.loadLE(UInt32.self, at: offset)
            let cmdsize = Int(data.loadLE(UInt32.self, at: offset + 4))
            // A command smaller than its own header, or one running past EOF,
            // means the table cannot be trusted — stop rather than guess.
            guard cmdsize >= 8, offset + cmdsize <= data.count else { return }
            body(cmd, offset, cmdsize)
            offset += cmdsize
        }
    }

    /// Parse all segments from a Mach-O binary in a Data buffer.
    public static func parseSegments(from data: Data) -> [MachOSegmentInfo] {
        var segments: [MachOSegmentInfo] = []
        guard data.count > 32 else { return segments }

        let magic = data.loadLE(UInt32.self, at: 0)
        guard magic == 0xFEED_FACF else { return segments } // MH_MAGIC_64

        forEachLoadCommand(in: data) { cmd, offset, cmdsize in
            guard cmd == 0x19, cmdsize >= segmentCommand64Size else { return } // LC_SEGMENT_64
            let nameData = data[offset + 8 ..< offset + 24]
            let name = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let vmAddr = data.loadLE(UInt64.self, at: offset + 24)
            let vmSize = data.loadLE(UInt64.self, at: offset + 32)
            let fileOff = data.loadLE(UInt64.self, at: offset + 40)
            let fileSize = data.loadLE(UInt64.self, at: offset + 48)

            segments.append(MachOSegmentInfo(
                name: name,
                vmAddr: vmAddr,
                vmSize: vmSize,
                fileOffset: fileOff,
                fileSize: fileSize,
            ))
        }
        return segments
    }

    /// Parse all sections from a Mach-O binary.
    /// Returns a dictionary keyed by "segment,section".
    public static func parseSections(from data: Data) -> [String: MachOSectionInfo] {
        var sections: [String: MachOSectionInfo] = [:]
        guard data.count > 32 else { return sections }

        let magic = data.loadLE(UInt32.self, at: 0)
        guard magic == 0xFEED_FACF else { return sections }

        forEachLoadCommand(in: data) { cmd, offset, cmdsize in
            guard cmd == 0x19, cmdsize >= segmentCommand64Size else { return } // LC_SEGMENT_64
            let segNameData = data[offset + 8 ..< offset + 24]
            let segName = String(data: segNameData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let nsects = data.loadLE(UInt32.self, at: offset + 64)

            var sectOff = offset + segmentCommand64Size
            for _ in 0 ..< nsects {
                // The section table lives inside this command, so bound it by
                // the command as well as by the file.
                guard sectOff + section64Size <= offset + cmdsize else { break }
                let sectNameData = data[sectOff ..< sectOff + 16]
                let sectName = String(data: sectNameData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let addr = data.loadLE(UInt64.self, at: sectOff + 32)
                let size = data.loadLE(UInt64.self, at: sectOff + 40)
                let fileOff = data.loadLE(UInt32.self, at: sectOff + 48)

                let key = "\(segName),\(sectName)"
                sections[key] = MachOSectionInfo(
                    segmentName: segName,
                    sectionName: sectName,
                    address: addr,
                    size: size,
                    fileOffset: fileOff,
                )
                sectOff += section64Size
            }
        }
        return sections
    }

    /// Convert a virtual address to a file offset using segment mappings.
    public static func vaToFileOffset(_ va: UInt64, segments: [MachOSegmentInfo]) -> Int? {
        for seg in segments {
            if va >= seg.vmAddr, va < seg.vmAddr + seg.vmSize {
                return Int(seg.fileOffset + (va - seg.vmAddr))
            }
        }
        return nil
    }

    /// Parse LC_SYMTAB information.
    /// Returns (symoff, nsyms, stroff, strsize) or nil.
    public static func parseSymtab(from data: Data) -> (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)? {
        guard data.count > 32 else { return nil }

        var result: (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)?
        forEachLoadCommand(in: data) { cmd, offset, cmdsize in
            guard result == nil else { return } // first LC_SYMTAB wins, as before
            guard cmd == 0x02, cmdsize >= symtabCommandSize else { return } // LC_SYMTAB
            let symoff = data.loadLE(UInt32.self, at: offset + 8)
            let nsyms = data.loadLE(UInt32.self, at: offset + 12)
            let stroff = data.loadLE(UInt32.self, at: offset + 16)
            let strsize = data.loadLE(UInt32.self, at: offset + 20)
            result = (Int(symoff), Int(nsyms), Int(stroff), Int(strsize))
        }
        return result
    }

    /// Find a symbol containing the given name fragment. Returns its virtual address.
    public static func findSymbol(containing fragment: String, in data: Data) -> UInt64? {
        guard let symtab = parseSymtab(from: data) else { return nil }

        for i in 0 ..< symtab.nsyms {
            let entryOff = symtab.symoff + i * 16 // sizeof(nlist_64)
            guard entryOff + 16 <= data.count else { break }

            let nStrx = data.loadLE(UInt32.self, at: entryOff)
            let nValue = data.loadLE(UInt64.self, at: entryOff + 8)

            guard nStrx < symtab.strsize, nValue != 0 else { continue }

            let strStart = symtab.stroff + Int(nStrx)
            guard strStart < data.count else { continue }

            // Read null-terminated string
            var strEnd = strStart
            while strEnd < data.count, strEnd < symtab.stroff + symtab.strsize {
                if data[strEnd] == 0 {
                    break
                }
                strEnd += 1
            }

            if let name = String(data: data[strStart ..< strEnd], encoding: .ascii),
               name.contains(fragment)
            {
                return nValue
            }
        }
        return nil
    }
}
