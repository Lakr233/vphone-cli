// CustomFirmwareWatchDogSymbolTargets.swift — Resolve watchdogd branch targets.

import Foundation

// MARK: - Symbol targets

/// Resolves a branch target to the name of the function it calls.
///
/// Two paths, because a call can reach a function either way:
///
///   * through a stub section (`S_SYMBOL_STUBS`, which is what `__auth_stubs`
///     is), whose entries map one-to-one onto a window of the indirect symbol
///     table — the classic Mach-O import lookup, and the one watchdogd's
///     `bl _sysctlbyname` takes;
///   * directly to a defined symbol, for a statically linked build.
///
/// This is deliberately not in `MachOParser`: it needs each section's `flags`,
/// `reserved1` and `reserved2` and the `LC_DYSYMTAB` indirect table, none of
/// which that shared parser exposes. It carries this patcher's name because
/// this patcher is its only caller — the first time a second one needs the same
/// lookup, move it to `Binary/` under a neutral name rather than growing a copy.
struct CustomFirmwareWatchDogSymbolTargets {
    /// A section of branch-island stubs, one per imported symbol.
    struct StubSection {
        let address: UInt64
        let size: UInt64
        /// `reserved2` — bytes per stub.
        let entrySize: UInt64
        /// `reserved1` — index of this section's first indirect symbol.
        let firstIndirectIndex: Int
    }

    let data: Data
    let symbolOffset: Int
    let symbolCount: Int
    let stringOffset: Int
    let stringSize: Int
    let indirectOffset: Int
    let indirectCount: Int
    let stubSections: [StubSection]

    static let machMagic64: UInt32 = 0xFEED_FACF
    static let lcSegment64: UInt32 = 0x19
    static let lcDysymtab: UInt32 = 0x0B
    /// `SECTION_TYPE` of a stub section.
    static let sectionTypeSymbolStubs: UInt32 = 0x08
    /// Indirect entries that name no import.
    static let indirectSymbolLocal: UInt32 = 0x8000_0000
    static let indirectSymbolAbs: UInt32 = 0x4000_0000
    /// `N_STAB` — a debug entry, never a call target name.
    static let symbolIsDebug: UInt8 = 0xE0

    init?(data: Data) {
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count > 32, data.loadLE(UInt32.self, at: 0) == Self.machMagic64 else { return nil }
        guard let symtab = MachOParser.parseSymtab(from: data) else { return nil }

        var indirectOffset = 0
        var indirectCount = 0
        var stubs: [StubSection] = []

        let commandCount = data.loadLE(UInt32.self, at: 16)
        var offset = 32
        for _ in 0 ..< commandCount {
            guard offset + 8 <= data.count else { return nil }
            let command = data.loadLE(UInt32.self, at: offset)
            let commandSize = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard commandSize > 0 else { return nil }

            if command == Self.lcDysymtab, offset + 64 <= data.count {
                indirectOffset = Int(data.loadLE(UInt32.self, at: offset + 56))
                indirectCount = Int(data.loadLE(UInt32.self, at: offset + 60))
            } else if command == Self.lcSegment64, offset + 72 <= data.count {
                let sectionCount = data.loadLE(UInt32.self, at: offset + 64)
                var section = offset + 72
                for _ in 0 ..< sectionCount {
                    guard section + 80 <= data.count else { break }
                    let flags = data.loadLE(UInt32.self, at: section + 64)
                    let entrySize = UInt64(data.loadLE(UInt32.self, at: section + 72)) // reserved2
                    if flags & 0xFF == Self.sectionTypeSymbolStubs, entrySize > 0 {
                        stubs.append(StubSection(
                            address: data.loadLE(UInt64.self, at: section + 32),
                            size: data.loadLE(UInt64.self, at: section + 40),
                            entrySize: entrySize,
                            firstIndirectIndex: Int(data.loadLE(UInt32.self, at: section + 68)), // reserved1
                        ))
                    }
                    section += 80
                }
            }
            offset += commandSize
        }

        self.data = data
        symbolOffset = symtab.symoff
        symbolCount = symtab.nsyms
        stringOffset = symtab.stroff
        stringSize = symtab.strsize
        self.indirectOffset = indirectOffset
        self.indirectCount = indirectCount
        stubSections = stubs
    }

    /// Name of the function a `bl`/`b` to `address` ends up in, or `nil`.
    func name(forBranchTarget address: UInt64) -> String? {
        importName(atStub: address) ?? definedName(at: address)
    }

    /// The imported symbol a stub at `address` stands for.
    func importName(atStub address: UInt64) -> String? {
        guard indirectCount > 0 else { return nil }
        for section in stubSections {
            guard address >= section.address, address < section.address &+ section.size else { continue }
            let index = section.firstIndirectIndex + Int((address - section.address) / section.entrySize)
            guard index >= 0, index < indirectCount else { return nil }
            let entryOffset = indirectOffset + index * 4
            guard entryOffset + 4 <= data.count else { return nil }
            let entry = data.loadLE(UInt32.self, at: entryOffset)
            guard entry & (Self.indirectSymbolLocal | Self.indirectSymbolAbs) == 0 else { return nil }
            return symbolName(at: Int(entry))
        }
        return nil
    }

    /// A defined symbol whose value is exactly `address`.
    func definedName(at address: UInt64) -> String? {
        guard address != 0 else { return nil }
        for index in 0 ..< symbolCount {
            let entry = symbolOffset + index * 16
            guard entry + 16 <= data.count else { return nil }
            guard data[entry + 4] & Self.symbolIsDebug == 0 else { continue }
            guard data.loadLE(UInt64.self, at: entry + 8) == address else { continue }
            return symbolName(at: index)
        }
        return nil
    }

    func symbolName(at index: Int) -> String? {
        guard index >= 0, index < symbolCount else { return nil }
        let entry = symbolOffset + index * 16
        guard entry + 4 <= data.count else { return nil }
        let stringIndex = Int(data.loadLE(UInt32.self, at: entry))
        guard stringIndex < stringSize else { return nil }
        let start = stringOffset + stringIndex
        guard start < data.count else { return nil }
        var end = start
        let limit = min(data.count, stringOffset + stringSize)
        while end < limit, data[end] != 0 {
            end += 1
        }
        return String(data: data.subdata(in: start ..< end), encoding: .utf8)
    }
}
