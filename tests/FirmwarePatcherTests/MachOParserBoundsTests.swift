// MachOParserBoundsTests.swift — The load-command walk must not read past EOF.
//
// `Data.loadLE` is a `precondition`, so an out-of-range read does not throw: it
// kills the process with SIGTRAP (exit 133). Before `forEachLoadCommand` bounded
// each command by its own `cmdsize` and by the file, the walk checked only that
// a command's 8-byte header fit and then read fields up to `+0x38` inside it —
// so every CFW Mach-O patcher died on `head -c 64 <any binary>` instead of
// reporting a bad file. These tests pass by *completing*: a regression here
// crashes the test runner rather than failing an expectation.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("MachOParser bounds")
struct MachOParserBoundsTests {
    // MARK: - Builders

    /// A `mach_header_64` that claims `ncmds` commands totalling `sizeofcmds`.
    static func header(ncmds: UInt32, sizeofcmds: UInt32) -> Data {
        var data = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(0xFEED_FACF) // magic: MH_MAGIC_64
        append(0x0100_000C) // cputype: CPU_TYPE_ARM64
        append(2) // cpusubtype: arm64e
        append(2) // filetype: MH_EXECUTE
        append(ncmds)
        append(sizeofcmds)
        append(0) // flags
        append(0) // reserved
        return data
    }

    /// An `LC_SEGMENT_64` whose declared `cmdsize` is free to lie about `nsects`.
    static func segment(
        name: String,
        vmAddr: UInt64,
        vmSize: UInt64,
        nsects: UInt32,
        cmdsize: UInt32
    ) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append32(0x19) // LC_SEGMENT_64
        append32(cmdsize)
        var segname = Data(name.utf8).prefix(16)
        segname.append(contentsOf: [UInt8](repeating: 0, count: 16 - segname.count))
        data.append(segname)
        append64(vmAddr)
        append64(vmSize)
        append64(0) // fileoff
        append64(vmSize) // filesize
        append32(5) // maxprot: r-x
        append32(5) // initprot: r-x
        append32(nsects)
        append32(0) // flags
        return data
    }

    // MARK: - Positive control

    // Without this, "returns nothing" would be indistinguishable from a guard
    // that rejects everything.
    @Test func aWellFormedSegmentStillParses() {
        var image = Self.header(ncmds: 1, sizeofcmds: 72)
        image.append(Self.segment(
            name: "__TEXT",
            vmAddr: 0x1_0000_0000,
            vmSize: 0x4000,
            nsects: 0,
            cmdsize: 72
        ))

        let segments = MachOParser.parseSegments(from: image)
        #expect(segments.count == 1)
        #expect(segments.first?.name == "__TEXT")
        #expect(segments.first?.vmAddr == 0x1_0000_0000)
        #expect(MachOParser.vaToFileOffset(0x1_0000_0010, segments: segments) == 0x10)
    }

    // MARK: - Truncation

    // The original repro: `head -c 64 ipsws/ref_extract/macho_pristine/seputil`.
    // Header says 23 commands in 2312 bytes; the file holds 64.
    @Test func aTruncatedLoadCommandTableYieldsNothingInsteadOfTrapping() {
        var image = Self.header(ncmds: 23, sizeofcmds: 2312)
        image.append(Data(repeating: 0, count: 32)) // half of one LC_SEGMENT_64
        #expect(image.count == 64)

        #expect(MachOParser.parseSegments(from: image).isEmpty)
        #expect(MachOParser.parseSections(from: image).isEmpty)
        #expect(MachOParser.parseSymtab(from: image) == nil)
        #expect(MachOParser.findSymbol(containing: "anything", in: image) == nil)
    }

    // A command whose body is one byte short of fitting is still a command the
    // walk must not enter — the last field read lives at the very end of it.
    @Test func aSegmentOneByteShortOfFittingIsNotParsed() {
        var image = Self.header(ncmds: 1, sizeofcmds: 72)
        image.append(Self.segment(
            name: "__TEXT",
            vmAddr: 0x1_0000_0000,
            vmSize: 0x4000,
            nsects: 0,
            cmdsize: 72
        ))
        image.removeLast()

        #expect(MachOParser.parseSegments(from: image).isEmpty)
    }

    // MARK: - Malformed sizes

    // `cmdsize == 0` used to advance the cursor by zero, re-reading the same
    // command `ncmds` times. Bounded, but it is not a table worth trusting.
    @Test func aZeroSizedCommandStopsTheWalk() {
        var image = Self.header(ncmds: 4, sizeofcmds: 32)
        var zero = Data()
        withUnsafeBytes(of: UInt32(0x19).littleEndian) { zero.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { zero.append(contentsOf: $0) }
        image.append(zero)
        image.append(Data(repeating: 0, count: 24))

        #expect(MachOParser.parseSegments(from: image).isEmpty)
    }

    // `nsects` is inside the command but the section table it describes is not:
    // the command declares one section and then stops at the fixed 72 bytes.
    @Test func aSectionTableOutsideItsCommandIsNotRead() {
        var image = Self.header(ncmds: 1, sizeofcmds: 72)
        image.append(Self.segment(
            name: "__TEXT",
            vmAddr: 0x1_0000_0000,
            vmSize: 0x4000,
            nsects: 1, // claims a section_64 that cmdsize leaves no room for
            cmdsize: 72
        ))
        image.append(Data(repeating: 0xFF, count: 80)) // trailing bytes, not ours to read

        // The segment itself is well formed, so it still parses…
        #expect(MachOParser.parseSegments(from: image).count == 1)
        // …but the section it lies about does not.
        #expect(MachOParser.parseSections(from: image).isEmpty)
    }

    // MARK: - Not a Mach-O at all

    @Test func nonMachOInputIsRejectedWithoutReading() {
        let text = Data("this is not a mach-o, not even a little bit of one".utf8)
        #expect(MachOParser.parseSegments(from: text).isEmpty)
        #expect(MachOParser.parseSections(from: text).isEmpty)
        #expect(MachOParser.parseSymtab(from: text) == nil)

        #expect(MachOParser.parseSegments(from: Data()).isEmpty)
        #expect(MachOParser.parseSymtab(from: Data()) == nil)
    }
}
