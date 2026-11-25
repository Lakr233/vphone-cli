import Foundation
import Virtualization

/// The dump types name only these; the real VM needs the whole stack.
@MainActor
final class VPhoneVirtualMachine {
    let virtualMachine: VZVirtualMachine
    let memorySize: UInt64 = 0
    let cpuCount = 0

    init(virtualMachine: VZVirtualMachine) {
        self.virtualMachine = virtualMachine
    }
}

/// Guest memory reading without a guest: page tables, the device tree, the
/// physical and process dump writers, and the kernel symbol maps, on
/// synthetic guest RAM.
@main
enum GuestMemoryTests {
    static let page = 0x4000
    static let dramBase: UInt64 = 0x8000_0000

    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            guard condition else {
                FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
                exit(1)
            }
        }

        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let recipes = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 64 pages of guest RAM at 0x8000_0000.
        let ram = UnsafeMutableRawPointer.allocate(byteCount: 64 * page, alignment: page)
        defer { ram.deallocate() }
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: 64 * page)
        func physical(_ pageIndex: Int) -> UInt64 { dramBase + UInt64(pageIndex * page) }
        func store(_ value: UInt64, page pageIndex: Int, index: Int) {
            ram.storeBytes(of: value, toByteOffset: pageIndex * page + index * 8, as: UInt64.self)
        }
        let memory = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: dramBase, size: UInt64(64 * page), base: UnsafeRawPointer(ram)),
            carveOut: nil, mappings: [],
        )

        // Root (page 1) → level 2 (page 2) → level 3 (page 3).
        // 0x1_0000_4000: user read-write, never executable, data page 10.
        // 0x1_0000_8000: user read-only, executable, data page 11.
        // 0x1_0200_0000: a 32 MB block at 0x9000_0000, outside guest RAM.
        let address: UInt64 = 0x1_0000_4000
        store(physical(2) | 3, page: 1, index: Int((address >> 36) & 0x7FF))
        store(physical(3) | 3, page: 2, index: Int((address >> 25) & 0x7FF))
        store(physical(10) | 3 | (1 << 6) | (1 << 54), page: 3, index: Int((address >> 14) & 0x7FF))
        store(physical(11) | 3 | (3 << 6), page: 3, index: Int(((address + 0x4000) >> 14) & 0x7FF))
        store(0x9000_0000 | 1, page: 2, index: Int((0x1_0200_0000 >> 25) & 0x7FF))
        for offset in stride(from: 0, to: page, by: 8) {
            ram.storeBytes(of: UInt64(offset) | 0xA000, toByteOffset: 10 * page + offset, as: UInt64.self)
            ram.storeBytes(of: UInt64(offset) | 0xB000, toByteOffset: 11 * page + offset, as: UInt64.self)
        }

        let tables = VPhoneGuestPageTables(memory: memory, root: physical(1))
        expect(tables.translate(address + 0x123) == physical(10) + 0x123, "level-3 translation")
        expect(tables.translate(address + 0x4008) == physical(11) + 8, "next page")
        expect(tables.translate(0x1_0200_0000 + 0x1234) == 0x9000_1234, "block translation")
        expect(tables.translate(address + 0x8000) == nil, "unmapped page")
        expect(tables.translate(0x2_0000_0000) == nil, "unmapped table")

        let mappings = try tables.mappings()
        expect(mappings.map(\.virtual) == [address, address + 0x4000, 0x1_0200_0000], "mappings in order")
        expect(mappings.map(\.size) == [0x4000, 0x4000, 0x200_0000], "mapping sizes")
        expect(VPhoneProcessMemoryDump.protection(mappings[0].entry) == 3, "rw-, from AP=01 and UXN")
        expect(VPhoneProcessMemoryDump.protection(mappings[1].entry) == 5, "r-x, from AP=11")

        // The process core: one segment per protection run, the block's
        // bytes outside guest RAM counted as unreadable.
        let core = folder.appendingPathComponent("test.core")
        let (segments, bytes, unreadable) = try VPhoneProcessMemoryDump.writeCore(
            mappings: mappings, memory: memory, to: core,
        )
        expect(segments == 3 && bytes == 0x8000 + 0x200_0000 && unreadable == 0x200_0000, "core totals")
        let file = try Data(contentsOf: core)
        func u32(_ offset: Int) -> UInt32 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        func u64(_ offset: Int) -> UInt64 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) } }
        expect(u32(0) == 0xFEED_FACF && u32(12) == 4 && u32(16) == 4, "Mach-O core header: 3 segments and a note")
        let first = 32
        expect(u32(first) == 0x19 && u64(first + 24) == address && u64(first + 32) == 0x4000, "first segment")
        let data = Int(u64(first + 40))
        expect(data % page == 0 && u64(data + 0x100) == 0x100 | 0xA000, "first segment's bytes")
        let second = first + 72
        expect(u64(second + 24) == address + 0x4000 && u32(second + 56) == 5, "second segment")
        expect(u64(Int(u64(second + 40)) + 8) == 8 | 0xB000, "second segment's bytes")

        // Device tree: an 8-byte property and two carve-outs.
        func property(_ name: String, at offset: Int, value: [UInt64]) {
            let bytes = Array(name.utf8)
            for (index, byte) in bytes.enumerated() {
                ram.storeBytes(of: byte, toByteOffset: 20 * page + offset + index, as: UInt8.self)
            }
            ram.storeBytes(of: UInt32(value.count * 8), toByteOffset: 20 * page + offset + 32, as: UInt32.self)
            for (index, word) in value.enumerated() {
                ram.storeBytes(of: word, toByteOffset: 20 * page + offset + 36 + index * 8, as: UInt64.self)
            }
        }
        property("dram-base", at: 0x40, value: [0x8000_0000])
        property("region-id-12", at: 0x100, value: [0x7F00_0000, 0x4000])
        property("region-id-3", at: 0x200, value: [0x7F80_0000, 0x8000])
        property("region-id-x", at: 0x300, value: [1, 2])
        let size = UInt64(64 * page)
        expect(VPhoneGuestPhysicalMemory.deviceTreeValues("dram-base", in: ram, size: size) == [0x8000_0000], "dram-base")
        expect(VPhoneGuestPhysicalMemory.deviceTreeValues("dram-size", in: ram, size: size).isEmpty, "absent property")
        expect(VPhoneGuestPhysicalMemory.deviceTreeValues("dram-base", in: ram, size: size, runs: [0 ..< UInt64(20 * page)])
            .isEmpty, "unused pages not searched")
        let carveOuts = VPhoneGuestPhysicalMemory.deviceTreeCarveOuts(in: ram, size: size)
        expect(carveOuts.map(\.base) == [0x7F00_0000, 0x7F80_0000] && carveOuts.map(\.size) == [0x4000, 0x8000],
               "carve-outs")

        // Used pages become runs; unknown use means the whole region.
        let p = UInt64(page)
        expect(VPhoneGuestPhysicalMemory.usedRuns(nil, size: 5 * p) == [0 ..< 5 * p], "unknown use")
        expect(VPhoneGuestPhysicalMemory.usedRuns([false, true, true, false, true], size: 5 * p)
            == [p ..< 3 * p, 4 * p ..< 5 * p], "used runs")
        expect(VPhoneGuestPhysicalMemory.usedRuns([false, false], size: 2 * p).isEmpty, "nothing used")

        // The physical image: the note, then guest RAM at its own offset.
        let elf = folder.appendingPathComponent("physical.elf")
        let stored = try VPhonePhysicalMemoryDump.write(
            memory: memory, regions: [memory.dram], machineName: "test", to: elf,
        )
        let image = try Data(contentsOf: elf)
        func elf64(_ offset: Int) -> UInt64 { image.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) } }
        func elf16(_ offset: Int) -> UInt16 { image.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) } }
        expect(image.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]) && elf16(16) == 4 && elf16(56) == 2, "ELF core header")
        let load = 64 + 56
        expect(elf64(load + 16) == dramBase && elf64(load + 24) == dramBase && elf64(load + 32) == size, "PT_LOAD")
        let ramOffset = Int(elf64(load + 8))
        expect(image.count == ramOffset + Int(size), "image length")
        expect(image[ramOffset + 10 * page + 0x100] == 0x00 && image[ramOffset + 10 * page + 0x101] == 0xA1,
               "RAM bytes in place")
        expect(stored < UInt64(image.count), "zero pages left as holes")
        let notes = Data(image[Int(elf64(64 + 8)) ..< Int(elf64(64 + 8)) + Int(elf64(64 + 32))])
        expect(String(decoding: notes, as: UTF8.self).contains("\"machine\""), "VPHONE note JSON")

        // Folder names.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = VPhoneProcessMemoryDump.folderName(machine: "phone", process: "a/b:c", pid: 42, date: date)
        expect(name.hasPrefix("phone a_b_c (42) Memory "), "process folder name: \(name)")

        // Malformed guest data: none of it may trap, read past its memory,
        // or grow without bound.
        malformedInput(expect)
        try kernelFromRegisters(expect, recipes: recipes)
        try kernelRegisters(expect)
        try threadWalk(expect)
        try threadCore(expect, folder: folder, memory: memory, mappings: mappings)
        try liveRegisters(expect)

        // Symbol maps: every map with a kernelUUID has both required symbols.
        var maps = 0
        for kind in ["bases", "kernels", "donors"] {
            let directory = recipes.appendingPathComponent(kind)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let manifest = directory.appendingPathComponent(entry).appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifest),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let uuid = object["kernelUUID"] as? String
                else { continue }
                let symbols = try VPhoneKernelSymbols.load(kernelUUID: uuid, root: recipes)
                for symbol in VPhoneKernelSymbols.required {
                    let location = try symbols.location(of: symbol)
                    expect(!location.segment.isEmpty, "\(entry): \(symbol)")
                }
                for symbol in VPhoneKernelSymbols.optional {
                    expect((try? symbols.location(of: symbol)) != nil, "\(entry): \(symbol)")
                }
                maps += 1
            }
        }
        expect(maps >= 14, "symbol maps with a kernel UUID: \(maps)")
        do {
            _ = try VPhoneKernelSymbols.load(kernelUUID: "00000000-0000-0000-0000-000000000000", root: recipes)
            expect(false, "unknown kernel refused")
        } catch VPhoneKernelSymbols.Failure.unknownKernel {
            expect(true, "unknown kernel refused")
        }

        try? FileManager.default.removeItem(at: folder)
        print("GuestMemoryTests: \(checks) checks passed (\(maps) symbol maps)")
    }
}

// MARK: - Malformed Input

extension GuestMemoryTests {
    /// `count` bytes followed by an inaccessible page: a read past them
    /// crashes the test instead of passing unseen.
    static func guarded(_ count: Int) -> UnsafeMutableRawPointer {
        let pages = (count + page - 1) / page
        let total = (pages + 1) * page
        let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)!
        mprotect(base + pages * page, page, PROT_NONE)
        return base + (pages * page - count)
    }

    static func malformedInput(_ expect: (Bool, String) -> Void) {
        // Addresses near 2^64 are refused, not added up.
        let ram = guarded(64 * page)
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: 64 * page)
        let memory = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: dramBase, size: UInt64(64 * page), base: UnsafeRawPointer(ram)),
            carveOut: nil, mappings: [],
        )
        expect(memory.read64(physical: .max) == nil && memory.read64(physical: .max - 4) == nil, "address near 2^64")
        expect(memory.pointer(physical: dramBase + UInt64(64 * page) - 4, count: 8) == nil, "read across the end")
        expect(memory.pointer(physical: dramBase, count: .max) == nil, "huge count")

        // Device tree: a carve-out whose end passes 2^64 is dropped, a
        // repeated one is kept once, and a property at the very end of the
        // searched range is not read past it.
        func property(_ name: String, at offset: Int, value: [UInt64]) {
            for (index, byte) in Array(name.utf8).enumerated() {
                ram.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self)
            }
            ram.storeBytes(of: UInt32(value.count * 8), toByteOffset: offset + 32, as: UInt32.self)
            for (index, word) in value.enumerated() {
                ram.storeBytes(of: word, toByteOffset: offset + 36 + index * 8, as: UInt64.self)
            }
        }
        property("region-id-1", at: 0x100, value: [0x7000_0000, .max])
        property("region-id-2", at: 0x200, value: [0x7F00_0000, 0x4000])
        property("region-id-3", at: 0x300, value: [0x7F00_0000, 0x4000])
        let tail = 64 * page - 40
        for (index, byte) in Array("region-id-9".utf8).enumerated() {
            ram.storeBytes(of: byte, toByteOffset: tail + index, as: UInt8.self)
        }
        let carveOuts = VPhoneGuestPhysicalMemory.deviceTreeCarveOuts(in: ram, size: UInt64(64 * page))
        expect(carveOuts == [.init(base: 0x7F00_0000, size: 0x4000)], "carve-outs: overflow dropped, duplicate once")

        // Thousands of planted names: the search stops at its limit.
        let sprayed = guarded(16 << 20)
        sprayed.initializeMemory(as: UInt8.self, repeating: 0, count: 16 << 20)
        let entry = Array("region-id-7".utf8) + [0]
        var planted = 0
        for offset in stride(from: 0, to: (16 << 20) - 64, by: 64) {
            for (index, byte) in entry.enumerated() {
                sprayed.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self)
            }
            sprayed.storeBytes(of: UInt32(16), toByteOffset: offset + 32, as: UInt32.self)
            sprayed.storeBytes(of: UInt64(planted) << 14, toByteOffset: offset + 36, as: UInt64.self)
            sprayed.storeBytes(of: UInt64(0x4000), toByteOffset: offset + 44, as: UInt64.self)
            planted += 1
        }
        let started = Date()
        let found = VPhoneGuestPhysicalMemory.deviceTreeCarveOuts(in: sprayed, size: 16 << 20)
        expect(found.count == VPhoneGuestPhysicalMemory.deviceTreeMatchLimit && planted > found.count,
               "sprayed carve-outs capped: \(found.count) of \(planted)")
        expect(Date().timeIntervalSince(started) < 1, "sprayed carve-outs fast")

        // dram-base: stray matches (wrong length, misaligned value) in front
        // of the device tree do not count, however many there are.
        let strays = guarded(16 << 20)
        strays.initializeMemory(as: UInt8.self, repeating: 0, count: 16 << 20)
        let dramName = Array("dram-base".utf8) + [0]
        func plantDRAMBase(in memory: UnsafeMutableRawPointer, at offset: Int, length: UInt32, value: UInt64) {
            for (index, byte) in dramName.enumerated() {
                memory.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self)
            }
            memory.storeBytes(of: length, toByteOffset: offset + 32, as: UInt32.self)
            memory.storeBytes(of: value, toByteOffset: offset + 36, as: UInt64.self)
        }
        let strayEnd = (16 << 20) - 4096
        var strayCount = 0
        for offset in stride(from: 0, to: strayEnd, by: 64) {
            plantDRAMBase(in: strays, at: offset, length: strayCount % 2 == 0 ? 4 : 8, value: UInt64(strayCount) << 14 | 0x123)
            strayCount += 1
        }
        plantDRAMBase(in: strays, at: strayEnd, length: 8, value: VPhoneGuestPhysicalMemory.usualDRAMBase)
        let strayStarted = Date()
        let pastStrays = VPhoneGuestPhysicalMemory.deviceTreeValues("dram-base", in: strays, size: 16 << 20) {
            $0 & 0x3FFF == 0
        }
        expect(strayCount > 4 * VPhoneGuestPhysicalMemory.deviceTreeMatchLimit
            && pastStrays == [VPhoneGuestPhysicalMemory.usualDRAMBase],
            "dram-base found past \(strayCount) stray matches")
        expect(Date().timeIntervalSince(strayStarted) < 1, "stray matches fast")

        // Well-formed planted values can still fill the limit; the usual base
        // is tried first regardless, and the unverified one is never a planted
        // value when the usual base was found.
        for offset in stride(from: 0, to: strayEnd, by: 64) {
            plantDRAMBase(in: strays, at: offset, length: 8, value: UInt64(offset + 1) << 14)
        }
        let filled = VPhoneGuestPhysicalMemory.deviceTreeValues("dram-base", in: strays, size: 16 << 20)
        expect(filled.count == VPhoneGuestPhysicalMemory.deviceTreeMatchLimit
            && !filled.contains(VPhoneGuestPhysicalMemory.usualDRAMBase), "planted values fill the limit")
        let usual = VPhoneGuestPhysicalMemory.usualDRAMBase
        let fromFilled = VPhoneGuestPhysicalMemory.dramBases(found: filled)
        expect(fromFilled.tried.first == usual && fromFilled.tried.count == filled.count + 1
            && fromFilled.unverified == usual, "usual base tried first, and unverified when the search was capped")
        let fromFew = VPhoneGuestPhysicalMemory.dramBases(found: [0x4000, 0x8000])
        expect(fromFew.tried == [usual, 0x4000, 0x8000] && fromFew.unverified == 0x4000,
               "another base: unverified is the first found")
        let withUsual = VPhoneGuestPhysicalMemory.dramBases(found: [0x4000, usual, 0x8000])
        expect(withUsual.tried == [usual, 0x4000, 0x8000] && withUsual.unverified == usual, "usual base found: used")
        expect(VPhoneGuestPhysicalMemory.dramBases(found: []) == ([usual], usual), "nothing found: usual base")

        // Mach-O: commands too short for their fields, or a header with
        // fewer than 32 bytes left, are skipped without reading past them.
        func header(at pointer: UnsafeMutableRawPointer, commands: [(UInt32, UInt32)], sizeofcmds: UInt32? = nil) {
            pointer.storeBytes(of: UInt32(0xFEED_FACF), as: UInt32.self)
            pointer.storeBytes(of: UInt32(commands.count), toByteOffset: 16, as: UInt32.self)
            let total = commands.reduce(0) { $0 + $1.1 }
            pointer.storeBytes(of: sizeofcmds ?? total, toByteOffset: 20, as: UInt32.self)
            var cursor = 32
            for (command, length) in commands {
                pointer.storeBytes(of: command, toByteOffset: cursor, as: UInt32.self)
                pointer.storeBytes(of: length, toByteOffset: cursor + 4, as: UInt32.self)
                cursor += Int(length)
            }
        }
        for (command, name) in [(UInt32(0x19), "LC_SEGMENT_64"), (0x1B, "LC_UUID"), (0x8000_0035, "LC_FILESET_ENTRY")] {
            let size = 32 + 8
            let buffer = guarded(size)
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            header(at: buffer, commands: [(command, 8)])
            expect(VPhoneGuestKernel.loadCommands(buffer, available: UInt64(size)).isEmpty, "short \(name) skipped")
            expect(VPhoneGuestKernel.image(buffer, available: UInt64(size)) == nil, "short \(name): no image")
            expect(VPhoneGuestKernel.filesetEntry("com.apple.kernel", header: buffer, available: UInt64(size)) == nil,
                   "short \(name): no fileset entry")
        }
        let short = guarded(16)
        short.storeBytes(of: UInt32(0xFEED_FACF), as: UInt32.self)
        expect(VPhoneGuestKernel.image(short, available: 16) == nil, "header shorter than 32 bytes")
        let lying = guarded(64)
        lying.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        header(at: lying, commands: [(0x19, 72)], sizeofcmds: 0xFFFF_FFF0)
        expect(VPhoneGuestKernel.loadCommands(lying, available: 64).isEmpty, "sizeofcmds beyond the memory")

        // A segment whose end passes 2^64 is left out.
        let segmentHeader = guarded(32 + 72 + 24)
        segmentHeader.initializeMemory(as: UInt8.self, repeating: 0, count: 32 + 72 + 24)
        header(at: segmentHeader, commands: [(0x19, 72), (0x1B, 24)])
        segmentHeader.storeBytes(of: UInt64.max - 0x1000, toByteOffset: 32 + 24, as: UInt64.self)
        segmentHeader.storeBytes(of: UInt64(0x4000), toByteOffset: 32 + 32, as: UInt64.self)
        expect(VPhoneGuestKernel.image(segmentHeader, available: UInt64(32 + 72 + 24)) == nil,
               "overflowing segment left out")

        // Page tables pointing at themselves: each table is walked once.
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: 64 * page)
        func physical(_ pageIndex: Int) -> UInt64 { dramBase + UInt64(pageIndex * page) }
        for index in 0 ..< 2048 {
            ram.storeBytes(of: physical(1) | 3, toByteOffset: 1 * page + index * 8, as: UInt64.self)
        }
        let cyclic = VPhoneGuestPageTables(memory: memory, root: physical(1))
        expect((try? cyclic.mappings())?.isEmpty == true, "self-referencing root")

        // Every level-1 entry to one level-2 table, every level-2 entry to
        // one level-3 table of 2048 pages: 2048^3 entries without the
        // visited set, 2048 with it.
        for index in 0 ..< 2048 {
            ram.storeBytes(of: physical(2) | 3, toByteOffset: 1 * page + index * 8, as: UInt64.self)
            ram.storeBytes(of: physical(3) | 3, toByteOffset: 2 * page + index * 8, as: UInt64.self)
            ram.storeBytes(of: physical(10) | 3, toByteOffset: 3 * page + index * 8, as: UInt64.self)
        }
        let fanned = VPhoneGuestPageTables(memory: memory, root: physical(1))
        let walkStarted = Date()
        let walked = try? fanned.mappings()
        expect(walked?.count == 2048 && Date().timeIntervalSince(walkStarted) < 1, "shared tables walked once")

        var few = VPhoneGuestPageTables.Limits()
        few.mappings = 100
        expect(throwsTooLarge { try fanned.mappings(limits: few) }, "mapping limit")
        var small = VPhoneGuestPageTables.Limits()
        small.bytes = 0x10_0000
        expect(throwsTooLarge { try fanned.mappings(limits: small) }, "byte limit")

        // 32 MB blocks in every level-2 entry: refused by size.
        for index in 0 ..< 2048 {
            ram.storeBytes(of: physical(4) | 3, toByteOffset: 1 * page + index * 8, as: UInt64.self)
            ram.storeBytes(of: UInt64(index) << 25 | 1, toByteOffset: 4 * page + index * 8, as: UInt64.self)
        }
        var oneGigabyte = VPhoneGuestPageTables.Limits()
        oneGigabyte.bytes = 1 << 30
        expect(throwsTooLarge { try VPhoneGuestPageTables(memory: memory, root: physical(1)).mappings(limits: oneGigabyte) },
               "blocks beyond the byte limit")

        // A table outside guest RAM is skipped.
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: 64 * page)
        ram.storeBytes(of: 0xFFFF_FFFF_C000 | 3, toByteOffset: 1 * page, as: UInt64.self)
        expect((try? VPhoneGuestPageTables(memory: memory, root: physical(1)).mappings())?.isEmpty == true,
               "table outside guest RAM")
        expect(VPhoneGuestPageTables(memory: memory, root: .max).translate(.max) == nil, "root near 2^64")
    }

    static func throwsTooLarge(_ body: () throws -> [VPhoneGuestKernel.Mapping]) -> Bool {
        do {
            _ = try body()
            return false
        } catch is VPhoneGuestPageTables.TooLarge {
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Kernel From Registers

extension GuestMemoryTests {
    /// A Mach-O header at `pointer`: `filetype`, then `commands`, each a
    /// command number and its bytes after the 8-byte command header.
    static func machO(at pointer: UnsafeMutableRawPointer, filetype: UInt32, commands: [(UInt32, [UInt8])]) {
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: page)
        var cursor = 32
        for (command, body) in commands {
            let length = (8 + body.count + 7) & ~7
            pointer.storeBytes(of: command, toByteOffset: cursor, as: UInt32.self)
            pointer.storeBytes(of: UInt32(length), toByteOffset: cursor + 4, as: UInt32.self)
            for (index, byte) in body.enumerated() {
                pointer.storeBytes(of: byte, toByteOffset: cursor + 8 + index, as: UInt8.self)
            }
            cursor += length
        }
        pointer.storeBytes(of: UInt32(0xFEED_FACF), as: UInt32.self)
        pointer.storeBytes(of: UInt32(0x0100_000C), toByteOffset: 4, as: UInt32.self)
        pointer.storeBytes(of: filetype, toByteOffset: 12, as: UInt32.self)
        pointer.storeBytes(of: UInt32(commands.count), toByteOffset: 16, as: UInt32.self)
        pointer.storeBytes(of: UInt32(cursor - 32), toByteOffset: 20, as: UInt32.self)
    }

    static func bytes(_ value: UInt64) -> [UInt8] { littleBytes(value) }

    static func name16(_ name: String) -> [UInt8] {
        Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
    }

    /// A kernel reached only through its registers: a root table, the
    /// kernelcache header below the vectors, the kernel's header with a
    /// known UUID, and `kernel_pmap` holding the root. Copies of the headers
    /// elsewhere in RAM, lower ones included, are never read.
    static func kernelFromRegisters(_ expect: (Bool, String) -> Void, recipes: URL) throws {
        let manifest = recipes.appendingPathComponent("bases/27.2_24B119/manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let known = (object?["kernelUUID"] as? String).flatMap(UUID.init(uuidString:)) else {
            expect(false, "27.2 manifest has a kernelUUID")
            return
        }
        let symbols = try VPhoneKernelSymbols.load(kernelUUID: known.uuidString, root: recipes)
        let (pmapSegment, pmapOffset) = try symbols.location(of: "_kernel_pmap")

        let pages = 64
        let ram = guarded(pages * page)
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: pages * page)
        func physical(_ index: Int) -> UInt64 { dramBase + UInt64(index * page) }
        let memory = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: dramBase, size: UInt64(pages * page), base: UnsafeRawPointer(ram)),
            carveOut: nil, mappings: [],
        )

        // Root (page 1) → level 2 (page 2) → level 3 (page 3), one 32 MB
        // window of kernel addresses from K.
        let kernelBase: UInt64 = 0xFFFF_FE00_0700_0000
        ram.storeBytes(of: physical(2) | 3, toByteOffset: 1 * page + Int((kernelBase >> 36) & 0x7FF) * 8, as: UInt64.self)
        ram.storeBytes(of: physical(3) | 3, toByteOffset: 2 * page + Int((kernelBase >> 25) & 0x7FF) * 8, as: UInt64.self)
        func map(_ address: UInt64, to index: Int) {
            expect(address >= kernelBase && address - kernelBase < 1 << 25, "test address in the window")
            ram.storeBytes(of: physical(index) | 3, toByteOffset: 3 * page + Int((address >> 14) & 0x7FF) * 8, as: UInt64.self)
        }

        // The kernelcache at K (page 10), the kernel's header one page up
        // (page 11), the segment holding _kernel_pmap 4 MB up, the pointer's
        // page (12), the pmap (13), the vectors 1 MB up (14).
        let kernelHeader = kernelBase + 0x4000
        let dataSegment = kernelBase + 0x40_0000
        let pmap = kernelBase + 0x8000
        let tte = kernelBase + 0xC000
        let vectors = kernelBase + 0x10_0000
        map(kernelBase, to: 10)
        map(kernelHeader, to: 11)
        map((dataSegment + pmapOffset) & ~0x3FFF, to: 12)
        map(pmap, to: 13)
        map(tte, to: 1)
        map(vectors, to: 14)
        func plantFileset(at index: Int, entry: UInt64) {
            machO(at: ram + index * page, filetype: 0xC, commands: [
                (0x8000_0035, bytes(entry) + bytes(0x4000) + [32, 0, 0, 0, 0, 0, 0, 0] + Array("com.apple.kernel".utf8) + [0]),
            ])
        }
        func plantKernel(at index: Int, uuid: UUID) {
            let uuidBytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            machO(at: ram + index * page, filetype: 2, commands: [
                (0x19, name16("__TEXT") + bytes(kernelHeader) + bytes(0x4000) + [UInt8](repeating: 0, count: 40)),
                (0x19, name16(pmapSegment) + bytes(dataSegment) + bytes((pmapOffset + 0x4000) & ~0x3FFF)
                    + [UInt8](repeating: 0, count: 40)),
                (0x1B, uuidBytes),
            ])
        }
        plantFileset(at: 10, entry: kernelHeader)
        plantKernel(at: 11, uuid: known)
        // PAC bits on the pointer, as the kernel stores it.
        let signed = (pmap & 0x0000_7FFF_FFFF_FFFF) | 0x2A5C << 48
        ram.storeBytes(of: signed, toByteOffset: 12 * page + Int((dataSegment + pmapOffset) & 0x3FFF), as: UInt64.self)
        ram.storeBytes(of: tte, toByteOffset: 13 * page, as: UInt64.self)
        ram.storeBytes(of: physical(1), toByteOffset: 13 * page + 8, as: UInt64.self)

        // Copies below: the real headers, and ones with other UUIDs.
        for index in [4, 6, 8] {
            plantFileset(at: index, entry: kernelHeader)
            plantKernel(at: index + 1, uuid: index == 4 ? known : UUID())
        }

        let registers = VPhoneGuestDebugStub.KernelRegisters(ttbr1: 0x0001 << 48 | physical(1) | 1, vbar: vectors + 0x800)
        expect(registers.root == physical(1), "root without the ASID and CnP")
        let kernel = try VPhoneGuestKernel.locate(in: memory, registers: registers, symbolsRoot: recipes)
        expect(kernel.kernelUUID == known.uuidString && kernel.kernelcachePhysical == physical(10),
               "kernel from its registers, not the lower copies")
        expect(kernel.root == physical(1) && kernel.kernelPmap == pmap && kernel.segments.count == 2,
               "root, kernel_pmap without PAC, segments")
        expect(kernel.memory === memory, "first dram-base kept")

        // Decoy dram-base values first: one puts the root outside DRAM, one
        // a page off, where the vectors do not translate.
        let decoyed = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: 0x1_0000_0000, size: UInt64(pages * page), base: UnsafeRawPointer(ram)),
            carveOut: nil, mappings: [], dramBases: [0x1_0000_0000, dramBase + 0x4000, dramBase],
        )
        let placed = try VPhoneGuestKernel.locate(in: decoyed, registers: registers, symbolsRoot: recipes)
        expect(placed.memory.dram.guestAddress == dramBase && placed.kernelcachePhysical == physical(10),
               "decoy dram-base values passed over")
        let onlyDecoys = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: 0x1_0000_0000, size: UInt64(pages * page), base: UnsafeRawPointer(ram)),
            carveOut: nil, mappings: [], dramBases: [0x1_0000_0000, dramBase + 0x4000],
        )
        expect(onlyDecoys.placed(kernel: registers) == nil, "no dram-base agrees")

        // Contiguous in guest physical memory but not on the host: the last
        // carve-out page, then DRAM's first page, are separate mappings.
        let carvePage = guarded(page)
        carvePage.initializeMemory(as: UInt8.self, repeating: 0, count: page)
        let split = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: dramBase, size: UInt64(pages * page), base: UnsafeRawPointer(ram)),
            carveOut: .init(guestAddress: dramBase - UInt64(page), size: UInt64(page), base: UnsafeRawPointer(carvePage)),
            mappings: [],
        )
        let straddle = kernelBase + 0x20_0000
        ram.storeBytes(of: (dramBase - UInt64(page)) | 3, toByteOffset: 3 * page + Int((straddle >> 14) & 0x7FF) * 8,
                       as: UInt64.self)
        map(straddle + UInt64(page), to: 0)
        let straddled = VPhoneGuestKernel.mapped(VPhoneGuestPageTables(memory: split, root: physical(1)), at: straddle)
        expect(straddled?.pointer == UnsafeRawPointer(carvePage) && straddled?.available == UInt64(page),
               "mapped bytes stop at the carve-out's end")
        let within = VPhoneGuestKernel.mapped(VPhoneGuestPageTables(memory: split, root: physical(1)), at: kernelBase)
        expect(within?.available ?? 0 > UInt64(page), "mapped bytes go on within DRAM")

        // The physical image's note without the kernel: the base is unverified,
        // with every candidate.
        let unverifiedNote = VPhonePhysicalMemoryDump.kernelDescription(
            memory: VPhoneGuestPhysicalMemory(
                dram: .init(guestAddress: 0x1_0000_0000, size: UInt64(pages * page), base: UnsafeRawPointer(ram)),
                carveOut: nil, mappings: [], dramBases: [VPhoneGuestPhysicalMemory.usualDRAMBase, 0x1_0000_0000], dramCandidates: [0x1_0000_0000, dramBase],
            ),
            kernel: .failure(VPhoneGuestDebugStub.Failure.unavailable("test")), machineName: "test",
        )
        let noteBase = unverifiedNote["dram_base"] as? [String: Any]
        let noteVerified = noteBase?["verified"] as? Bool
        let noteCandidates = noteBase?["candidates"] as? [String]
        expect(noteVerified == false && noteCandidates == ["0x100000000", "0x80000000"]
            && unverifiedNote["kernel_error"] != nil, "note: base unverified, candidates listed")
        let verifiedNote = VPhonePhysicalMemoryDump.kernelDescription(memory: placed.memory, kernel: .success(placed),
                                                                      machineName: "test")
        expect((verifiedNote["dram_base"] as? [String: Any])?["verified"] as? Bool == true, "note: base verified")

        // Room for a process core: its pages and commands, not twice guest RAM.
        let someMappings = (0 ..< 3).map {
            VPhoneGuestKernel.Mapping(virtual: UInt64($0) << 20, physical: dramBase, size: 1 << 20, entry: 3)
        }
        expect(VPhoneProcessMemoryDump.spaceNeeded(someMappings)
            == 3 << 20 + 3 * 72 + VPhoneProcessMemoryDump.spaceNeededBeforePause, "space for a process core")
        func fails(_ registers: VPhoneGuestDebugStub.KernelRegisters, _ check: (Error) -> Bool) -> Bool {
            do {
                _ = try VPhoneGuestKernel.locate(in: memory, registers: registers, symbolsRoot: recipes)
                return false
            } catch {
                return check(error)
            }
        }
        expect(fails(.init(ttbr1: 0x1_0000_0000, vbar: vectors)) {
            if case VPhoneGuestKernel.Failure.noPageTables = $0 { return true } else { return false }
        }, "root outside guest RAM")

        // Unknown kernel: named by its own UUID, not by a lower copy's.
        let other = UUID()
        plantKernel(at: 11, uuid: other)
        expect(fails(registers) {
            if case let VPhoneKernelSymbols.Failure.unknownKernel(uuid) = $0 { return uuid == other.uuidString }
            return false
        }, "unknown kernel named by its own UUID")
        plantKernel(at: 11, uuid: known)

        // kernel_pmap holding other tables.
        ram.storeBytes(of: physical(2), toByteOffset: 13 * page + 8, as: UInt64.self)
        expect(fails(registers) {
            if case VPhoneGuestKernel.Failure.unexpected = $0 { return true } else { return false }
        }, "kernel_pmap must hold TTBR1_EL1's tables")
        ram.storeBytes(of: physical(1), toByteOffset: 13 * page + 8, as: UInt64.self)

        // A fileset entry pointing nowhere.
        plantFileset(at: 10, entry: .max)
        expect(fails(registers) {
            if case VPhoneGuestKernel.Failure.unexpected = $0 { return true } else { return false }
        }, "kernel entry not mapped")

        // No header below the vectors: the walk ends at its limit, or at
        // address 0, quickly.
        (ram + 10 * page).initializeMemory(as: UInt8.self, repeating: 0, count: page)
        let started = Date()
        expect(fails(registers) {
            if case VPhoneGuestKernel.Failure.noKernelcache = $0 { return true } else { return false }
        }, "no kernelcache below the vectors")
        let tables = VPhoneGuestPageTables(memory: memory, root: physical(1))
        expect(VPhoneGuestKernel.filesetHeader(tables, below: 0x8000) == nil, "walk stops at address 0")
        expect(Date().timeIntervalSince(started) < 1, "walk bounded: \(Date().timeIntervalSince(started)) s")
    }

    /// TTBR1_EL1 and VBAR_EL1 through a fake stub: the same on every vCPU,
    /// or refused.
    static func kernelRegisters(_ expect: (Bool, String) -> Void) throws {
        expect(VPhoneGuestDebugStub.frame("OK") == Array("$OK#9a".utf8), "packet checksum")
        expect(VPhoneGuestDebugStub.decode(Array("0* 1".utf8)) == Array("00001".utf8), "run length")
        expect(VPhoneGuestDebugStub.decode(Array("a}\u{03}b".utf8)) == Array("a#b".utf8), "escaped byte")
        let bomb = [UInt8]([UInt8(ascii: "0")]) + [UInt8](repeating: 0, count: 40000).enumerated().map {
            $0.offset % 2 == 0 ? UInt8(ascii: "*") : 126
        }
        expect(VPhoneGuestDebugStub.decode(bomb) == nil, "run lengths past 1 MB refused")
        expect(VPhoneGuestDebugStub.hex("1f") == 31 && VPhoneGuestDebugStub.hex("A") == 10, "hex numbers")
        expect(VPhoneGuestDebugStub.hex("-1") == nil && VPhoneGuestDebugStub.hex("+1") == nil
            && VPhoneGuestDebugStub.hex("") == nil && VPhoneGuestDebugStub.hex("0x1") == nil, "signs and prefixes refused")
        expect(VPhoneGuestDebugStub.little([0x78, 0x56, 0x34, 0x12]) == 0x1234_5678, "little-endian value")
        expect(VPhoneGuestDebugStub.fields("T11thread:1;threads:1,2;")["threads"] == "1,2", "reply fields")

        func read(
            names: [String] = ["x0", "cpsr", "ttbr1_el1", "vbar_el1"],
            listsThreadsInStop: Bool = true, raw: [String: String] = [:],
            _ values: [Int: [String: [UInt8]]],
        ) -> (Result<VPhoneGuestDebugStub.KernelRegisters, Error>, [String]) {
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return (.failure(POSIXError(.EIO)), []) }
            let stub = FakeDebugStub(descriptor: pair[1], names: names)
            stub.values = values
            stub.listsThreadsInStop = listsThreadsInStop
            stub.raw = raw
            stub.start()
            let session = VPhoneGuestDebugStub.Session(descriptor: pair[0])
            let result = Result { try VPhoneGuestDebugStub.kernelRegisters(session) }
            session.detach()
            stub.done.wait()
            return (result, stub.packets)
        }
        let ttbr1: UInt64 = 0x0001 << 48 | 0x7616_0000 | 1
        let vbar: UInt64 = 0xFFFF_FE00_3FE1_C000
        let same = ["ttbr1_el1": littleBytes(ttbr1), "vbar_el1": littleBytes(vbar)]
        let (agreed, packets) = read([1: same, 2: same])
        expect((try? agreed.get()) == .init(ttbr1: ttbr1, vbar: vbar), "registers of agreeing vCPUs")
        expect((try? agreed.get())?.root == 0x7616_0000, "root from TTBR1_EL1")
        expect(packets.filter { $0.hasPrefix("p") }.count == 4, "two reads per vCPU")
        expect(packets.first == "QStartNoAckMode" && packets.last == "D", "no-ack first, detach last")

        var other = same
        other["ttbr1_el1"] = littleBytes(0x7700_0000)
        expect((try? read([1: same, 2: other]).0.get()) == nil, "disagreeing vCPUs refused")
        let early = ["ttbr1_el1": littleBytes(0), "vbar_el1": littleBytes(0x1_0000_0800)]
        expect((try? read([1: early]).0.get()) == nil, "a kernel without page tables yet refused")
        expect((try? read(names: ["x0", "cpsr", "ttbr1_el1"], [1: same]).0.get()) == nil, "no vbar_el1: refused")

        // The vCPUs from qfThreadInfo/qsThreadInfo when the stop reply has none.
        let (listed, listPackets) = read(listsThreadsInStop: false, [1: same, 2: same])
        expect((try? listed.get()) != nil && listPackets.contains("qsThreadInfo"), "vCPUs from the thread list")
        let (bare, barePackets) = read(listsThreadsInStop: false, raw: ["qfThreadInfo": "m"], [1: same])
        expect((try? bare.get()) == nil && !barePackets.contains("qsThreadInfo"), "a bare m refused")
        let (endless, endlessPackets) = read(listsThreadsInStop: false, raw: ["qsThreadInfo": "m1"], [1: same])
        expect((try? endless.get()) == nil
            && endlessPackets.filter { $0 == "qsThreadInfo" }.count == VPhoneGuestDebugStub.threadListReplyLimit,
            "a thread list that never ends refused")
        let (signed, _) = read(raw: ["?": "T11thread:1;threads:-1;", "qfThreadInfo": "m-1", "qsThreadInfo": "l"], [1: same])
        expect((try? signed.get()) == nil, "thread -1 (all threads) never read")
        let (unparsedStop, unparsedStopPackets) = read(raw: ["?": "T11thread:1;threads:1,zz;"], [1: same])
        expect((try? unparsedStop.get()) == nil && !unparsedStopPackets.contains { $0.hasPrefix("p") },
               "an unreadable vCPU in the stop reply refused")
        let (unparsedList, _) = read(listsThreadsInStop: false, raw: ["qfThreadInfo": "m1,zz"], [1: same])
        expect((try? unparsedList.get()) == nil, "an unreadable vCPU in the thread list refused")

        var pair: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        let silent = VPhoneGuestDebugStub.Session(descriptor: pair[0])
        let started = Date()
        expect((try? silent.request("?")) == nil && Date().timeIntervalSince(started) < 3, "a silent stub times out")
    }

    static func littleBytes(_ value: UInt64, count: Int = 8) -> [UInt8] {
        (0 ..< count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0 % 8))) }
    }
}

// MARK: - Fake Debug Stub

/// A kernel debug stub as Virtualization's answers: vCPUs as threads,
/// `qRegisterInfo`, per-thread `p` reads, `D`. Runs on its own thread over
/// one end of a socket pair.
final class FakeDebugStub: @unchecked Sendable {
    let descriptor: Int32
    /// The register names in number order.
    let names: [String]
    /// Register bytes by vCPU and name; what is missing reads as an error.
    var values: [Int: [String: [UInt8]]] = [:]
    /// Replies sent as they are, by packet.
    var raw: [String: String] = [:]
    var listsThreadsInStop = true
    private(set) var packets: [String] = []
    let done = DispatchSemaphore(value: 0)
    private var acknowledging = true

    init(descriptor: Int32, names: [String]) {
        self.descriptor = descriptor
        self.names = names
    }

    func start() {
        Thread { [self] in run() }.start()
    }

    private func run() {
        defer { close(descriptor); done.signal() }
        var buffer: [UInt8] = []
        while true {
            if let start = buffer.firstIndex(of: UInt8(ascii: "$")),
               let end = buffer[start...].firstIndex(of: UInt8(ascii: "#")), buffer.count >= end + 3
            {
                let packet = String(decoding: buffer[(start + 1) ..< end], as: UTF8.self)
                buffer.removeFirst(end + 3)
                packets.append(packet)
                if acknowledging { send(Array("+".utf8)) }
                let reply = answer(packet)
                send(VPhoneGuestDebugStub.frame(reply))
                if packet == "QStartNoAckMode" { acknowledging = false }
                if packet == "D" { return }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            buffer += chunk[0 ..< count]
        }
    }

    private func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    private func answer(_ packet: String) -> String {
        if let reply = raw[packet] { return reply }
        let cpus = values.keys.sorted().map { String($0, radix: 16) }.joined(separator: ",")
        switch packet {
        case "QStartNoAckMode", "QThreadSuffixSupported", "D": return "OK"
        case "?": return "T11thread:1;name:CPU0;" + (listsThreadsInStop ? "threads:\(cpus);" : "")
        case "qfThreadInfo": return "m" + cpus
        case "qsThreadInfo": return "l"
        default: break
        }
        if packet.hasPrefix("qRegisterInfo"), let number = Int(packet.dropFirst(13), radix: 16) {
            guard number < names.count else { return "E45" }
            let alias = names[number] == "fp" ? "alt-name:x29;" : ""
            return "name:\(names[number]);\(alias)bitsize:64;offset:0;encoding:uint;format:hex;"
        }
        if packet.hasPrefix("p") {
            let fields = VPhoneGuestDebugStub.fields(String(packet.dropFirst()))
            let parts = packet.dropFirst().split(separator: ";")
            guard let number = parts.first.flatMap({ Int($0, radix: 16) }), number < names.count,
                  let cpu = fields["thread"].flatMap({ Int($0, radix: 16) }),
                  let bytes = values[cpu]?[names[number]]
            else { return "E01" }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return ""
    }
}

// MARK: - Threads

/// Kernel memory as 8-byte words by kernel virtual address; every kernel
/// address reads, as zero unless written, and nothing else does.
final class FakeKernelMemory: VPhoneKernelMemory {
    var words: [UInt64: UInt64] = [:]

    func read64(virtual address: UInt64) -> UInt64? {
        address & 7 == 0 && VPhoneGuestThreads.isKernelPointer(address) ? words[address] ?? 0 : nil
    }

    func read32(virtual address: UInt64) -> UInt32? {
        guard address & 3 == 0, let word = read64(virtual: address & ~7) else { return nil }
        return UInt32(truncatingIfNeeded: address & 4 == 0 ? word : word >> 32)
    }

    subscript(address: UInt64) -> UInt64 {
        get { words[address] ?? 0 }
        set { words[address] = newValue }
    }
}

/// Counts reads. Alone, every aligned word of a kernel page points to the
/// next page, so any walk finds a new kernel pointer at every step; around
/// other memory, it reads that.
final class CountingKernelMemory: VPhoneKernelMemory {
    let wrapped: FakeKernelMemory?
    private(set) var reads = 0

    init(wrapping wrapped: FakeKernelMemory? = nil) { self.wrapped = wrapped }

    func read64(virtual address: UInt64) -> UInt64? {
        reads += 1
        if let wrapped { return wrapped.read64(virtual: address) }
        return VPhoneGuestThreads.isKernelPointer(address) ? (address & ~0x3FFF) &+ 0x4000 : nil
    }

    func read32(virtual address: UInt64) -> UInt32? {
        reads += 1
        if let wrapped { return wrapped.read32(virtual: address) }
        return VPhoneGuestThreads.isKernelPointer(address) ? 0 : nil
    }
}

extension GuestMemoryTests {
    // The 27.2 layout: the queue head 0x28 past the map pointer.
    static let procMap: UInt64 = 0x790
    static let list: UInt64 = 0x7B8
    static let link: UInt64 = 0x3F0
    static let userState: UInt64 = 0xF8
    static let neonState: UInt64 = 0x108
    static let idOffset: UInt64 = 0x4C8
    static let tsdOffset: UInt64 = 0x130
    static let nameOffset: UInt64 = 0x758

    /// A thread at `thread` with saved registers whose x0 is `seed` and xN
    /// `seed + N`, pc `seed << 4`, and NEON words `seed << 32 | seed`.
    static func plantThread(_ memory: FakeKernelMemory, thread: UInt64, seed: UInt64, id: UInt64) {
        let state = thread + 0x10000  // 16-byte aligned
        memory[thread + userState] = state
        memory[state] = UInt64(74) << 32 | 21
        for index in 0 ..< 29 { memory[state + 8 + UInt64(index * 8)] = seed + UInt64(index) }
        memory[state + 0xF0] = 0x16F0_0000 + seed  // fp
        memory[state + 0xF8] = 0x0012_3400_1A0D_62C0 | seed  // lr, signed
        memory[state + 0x100] = 0x16F0_0000 + seed - 0x10  // sp
        memory[state + 0x108] = seed << 4  // pc
        memory[state + 0x110] = 0x6000_0000  // cpsr: EL0t, Z and C
        memory[state + 0x118] = 0xDEAD_0000 + seed  // far
        memory[state + 0x120] = 0x5600_0080  // esr: svc #0x80
        let neon = thread + 0x20000
        memory[thread + neonState] = neon
        memory[neon] = UInt64(132) << 32 | 23
        for index in 0 ..< 64 { memory[neon + 16 + UInt64(index * 8)] = seed << 32 | seed }
        memory[neon + 0x210] = UInt64(0x0300_0000) << 32 | 0x10  // fpcr, fpsr
        memory[thread + idOffset] = id
        memory[thread + tsdOffset] = 0x1_0000_70E0 + seed * 0x10_0000
    }

    /// Procs with their threads queued; returns the procs.
    static func plantProcesses(_ memory: FakeKernelMemory, threadCounts: [Int]) -> [UInt64] {
        var procs: [UInt64] = []
        var nextThread: UInt64 = 0xFFFF_FE10_0000_0000
        var seed: UInt64 = 0x100
        for (index, count) in threadCounts.enumerated() {
            let proc = 0xFFFF_FE20_0000_0000 + UInt64(index) * 0x10_0000
            procs.append(proc)
            memory[proc + procMap] = 0xFFFF_FE30_0000_0000  // the map, a kernel pointer
            let head = proc + list
            var previous = head
            for _ in 0 ..< count {
                let thread = nextThread
                nextThread += 0x10_0000
                plantThread(memory, thread: thread, seed: seed, id: seed)
                seed += 1
                // The head's and each link's next pointer is the thread itself.
                memory[previous == head ? head : previous + link] = thread
                previous = thread
            }
            memory[previous == head ? head : previous + link] = head
        }
        return procs
    }

    static func threadWalk(_ expect: (Bool, String) -> Void) throws {
        let memory = FakeKernelMemory()
        let procs = plantProcesses(memory, threadCounts: [3, 1, 0, 2])
        var layout = try VPhoneGuestThreads.discover(memory, sample: procs, map: procMap)
        expect(layout.list == list && layout.link == link, "thread queue: head and link")
        expect(layout.userState == userState && layout.neonState == neonState, "saved register pointers")

        let (threads, skipped) = try VPhoneGuestThreads.threads(memory, process: procs[0], layout: layout)
        expect(threads.count == 3 && skipped == 0, "three threads")
        let first = threads[0].registers
        expect(first.x[0] == 0x100 && first.x[28] == 0x100 + 28 && first.pc == 0x1000, "x0–x28 and pc")
        expect(first.lr == 0x0012_3400_1A0D_63C0 && first.sp == 0x16F0_00F0, "lr kept signed, sp")
        expect(first.cpsr == 0x6000_0000 && first.esr == 0x5600_0080 && first.far == 0xDEAD_0100, "cpsr, esr, far")
        expect(threads[0].neon?.count == 66 && threads[0].neon?[0] == 0x100_0000_0100, "NEON v0")
        expect(threads[0].neon?[64] == UInt64(0x0300_0000) << 32 | 0x10 && threads[0].neon?[65] == 0, "fpsr, fpcr, pad")
        expect(threads[0].id == nil, "no ID offset without the accessor")
        expect(try VPhoneGuestThreads.threads(memory, process: procs[2], layout: layout).threads.isEmpty, "no threads")

        // The accessors: the first `ldr xN, [x0, #imm]` before a branch.
        let tid: [UInt32] = [0xB400_0040, 0xF942_6400, 0xD65F_03C0]  // cbz x0; ldr x0, [x0, #0x4c8]; ret
        expect(VPhoneGuestThreads.accessorOffset(tid) == 0x4C8, "thread_tid's ldr")
        expect(VPhoneGuestThreads.accessorOffset([0xD65F_03C0, 0xF942_6400]) == nil, "nothing after ret")
        expect(VPhoneGuestThreads.accessorOffset([0x9400_0010, 0xF942_6400]) == nil, "nothing after bl")
        expect(VPhoneGuestThreads.accessorOffset([0xF942_6420]) == nil, "base other than x0")
        layout.id = idOffset
        layout.tsd = tsdOffset
        layout.name = nameOffset
        let all = procs.flatMap { VPhoneGuestThreads.queue(memory, head: $0 + list, link: link) ?? [] }
        let checked = VPhoneGuestThreads.checkAccessors(memory, layout, threads: all)
        expect(checked.id == idOffset && checked.tsd == tsdOffset && checked.name == nameOffset, "accessors kept")
        let named = try VPhoneGuestThreads.threads(memory, process: procs[0], layout: checked).threads
        expect(named[1].id == 0x101 && named[1].tsd == 0x1_0000_70E0 + 0x101 * 0x10_0000 && named[1].name == nil,
               "ID and TSD read, no name")

        // A name buffer, and one that is not a name.
        let nameBuffer: UInt64 = 0xFFFF_FE40_0000_0000
        memory[all[0] + nameOffset] = nameBuffer
        memory[nameBuffer] = UInt64(littleEndian: 0x0064_7261_6F62_7473)  // "stboard"
        expect(try VPhoneGuestThreads.threads(memory, process: procs[0], layout: checked).threads[0].name == "stboard",
               "thread name")
        memory[nameBuffer] = 0x0101_0101_0101_0101
        expect(VPhoneGuestThreads.checkAccessors(memory, layout, threads: all).name == nil, "unterminated name refused")
        memory[nameBuffer] = 0x000A_0D41  // "A\r\n"
        expect(VPhoneGuestThreads.checkAccessors(memory, layout, threads: all).name == nil, "control characters refused")
        memory[all[0] + nameOffset] = 0
        memory[all[1] + idOffset] = memory[all[0] + idOffset]
        expect(VPhoneGuestThreads.checkAccessors(memory, layout, threads: all).id == nil, "repeated thread IDs refused")
        memory[all[1] + idOffset] = 0x101
        memory[all[2] + tsdOffset] = 0xFFFF_FE00_0000_0000
        expect(VPhoneGuestThreads.checkAccessors(memory, layout, threads: all).tsd == nil, "kernel TSD refused")

        try threadMalformed(expect)
    }

    static func threadMalformed(_ expect: (Bool, String) -> Void) throws {
        // A queue that loops without coming back to its head, or points back
        // to a thread it already passed, ends without hanging.
        let memory = FakeKernelMemory()
        let procs = plantProcesses(memory, threadCounts: [3, 2])
        let threads = VPhoneGuestThreads.queue(memory, head: procs[0] + list, link: link)!
        memory[threads[2] + link] = threads[0]
        expect(VPhoneGuestThreads.queue(memory, head: procs[0] + list, link: link) == nil, "looping queue refused")
        memory[threads[2] + link] = threads[2]
        expect(VPhoneGuestThreads.queue(memory, head: procs[0] + list, link: link) == nil, "self-linked thread refused")
        memory[threads[2] + link] = 0x1234
        expect(VPhoneGuestThreads.queue(memory, head: procs[0] + list, link: link) == nil, "user pointer refused")
        expect((try? VPhoneGuestThreads.threads(memory, process: procs[0], layout: .init(
            list: list, link: link, userState: userState, neonState: nil,
        ))) == nil, "broken queue throws")

        // A queue longer than the limit is refused.
        let long = FakeKernelMemory()
        let head: UInt64 = 0xFFFF_FE50_0000_0000
        var previous = head
        for index in 0 ... VPhoneGuestThreads.threadLimit {
            let thread = 0xFFFF_FE60_0000_0000 + UInt64(index) * 0x1000
            long[previous == head ? head : previous + 8] = thread
            previous = thread
        }
        long[previous + 8] = head
        expect(VPhoneGuestThreads.queue(long, head: head, link: 8) == nil, "queue beyond the thread limit refused")

        // A thread whose record is not a user state is skipped, and
        // discovery tolerates one in ten such threads.
        let bad = FakeKernelMemory()
        let sample = plantProcesses(bad, threadCounts: [6, 5])
        let victim = VPhoneGuestThreads.queue(bad, head: sample[0] + list, link: link)![1]
        let state = bad[victim + userState]
        bad[state + 0x110] = 0x3C5  // cpsr: EL1h
        let layout = try VPhoneGuestThreads.discover(bad, sample: sample, map: procMap)
        expect(layout.userState == userState, "one odd thread in eleven tolerated")
        let (kept, skipped) = try VPhoneGuestThreads.threads(bad, process: sample[0], layout: layout)
        expect(kept.count == 5 && skipped == 1, "kernel-mode state skipped")
        bad[state] = UInt64(74) << 32 | 22
        bad[state + 4] = 0
        expect(VPhoneGuestThreads.record(bad, thread: victim, at: userState, flavor: 21, words: 72 ... 256) == nil,
               "wrong flavor refused")
        bad[state] = UInt64(8) << 32 | 21
        expect(VPhoneGuestThreads.record(bad, thread: victim, at: userState, flavor: 21, words: 72 ... 256) == nil,
               "short record refused")
        bad[victim + userState] = state + 8
        expect(VPhoneGuestThreads.record(bad, thread: victim, at: userState, flavor: 21, words: 72 ... 256) == nil,
               "unaligned record refused")

        // No saved registers anywhere: no layout.
        let empty = FakeKernelMemory()
        let bare = plantProcesses(empty, threadCounts: [2])
        for thread in VPhoneGuestThreads.queue(empty, head: bare[0] + list, link: link)! {
            empty[thread + userState] = 0
            empty[thread + neonState] = 0
        }
        expect((try? VPhoneGuestThreads.discover(empty, sample: bare, map: procMap)) == nil, "no saved state, no layout")
        expect((try? VPhoneGuestThreads.discover(empty, sample: [], map: procMap)) == nil, "empty sample refused")

        // Memory whose every page points to the next makes every walk run to
        // the thread limit; discovery gives up at its read budget.
        let chain = CountingKernelMemory()
        let started = Date()
        expect((try? VPhoneGuestThreads.discover(chain, sample: [0xFFFF_FE20_0000_0000], map: procMap)) == nil,
               "chained pages: no layout")
        expect(chain.reads <= VPhoneGuestThreads.discoveryReadLimit,
               "chained pages: \(chain.reads) reads, within the budget")
        expect(Date().timeIntervalSince(started) < 10, "chained pages: \(Date().timeIntervalSince(started)) s")

        // Rings that close but carry no saved state: each offset stops at
        // the second failing thread of the sampled ones.
        var tested = 0
        expect(!VPhoneGuestThreads.mostly(Array(0 ..< 100)) { _ in tested += 1; return false } && tested == 11,
               "mostly stops once it cannot pass (\(tested) tests)")
        expect(VPhoneGuestThreads.mostly(Array(0 ..< 10)) { $0 != 3 }, "one in ten may fail")
        expect(!VPhoneGuestThreads.mostly([]) { _ in true }, "nothing to test does not pass")
        let wide = FakeKernelMemory()
        let crowded = plantProcesses(wide, threadCounts: [40, 40])
        for thread in crowded.flatMap({ VPhoneGuestThreads.queue(wide, head: $0 + list, link: link)! }) {
            wide[thread + userState] = 0
        }
        let counted = CountingKernelMemory(wrapping: wide)
        expect((try? VPhoneGuestThreads.discover(counted, sample: crowded, map: procMap)) == nil, "no saved state, no layout")
        expect(counted.reads < 2_000_000, "threads without saved state: \(counted.reads) reads")
    }

    /// LC_THREADs and LC_NOTEs as LLDB reads them.
    static func threadCore(
        _ expect: (Bool, String) -> Void, folder: URL, memory: VPhoneGuestPhysicalMemory,
        mappings: [VPhoneGuestKernel.Mapping],
    ) throws {
        let kernel = FakeKernelMemory()
        let procs = plantProcesses(kernel, threadCounts: [2])
        var layout = try VPhoneGuestThreads.discover(kernel, sample: procs, map: procMap)
        layout.id = idOffset
        let threads = try VPhoneGuestThreads.threads(kernel, process: procs[0], layout: layout).threads
        let core = folder.appendingPathComponent("threads.core")
        _ = try VPhoneProcessMemoryDump.writeCore(mappings: mappings, threads: threads, memory: memory, to: core)
        let file = try Data(contentsOf: core)
        func u32(_ offset: Int) -> UInt32 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        func u64(_ offset: Int) -> UInt64 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) } }
        expect(u32(16) == 3 + 2 + 2, "3 segments, 2 threads, 2 notes")
        expect(Int(u32(20)) == 3 * 72 + 2 * 848 + 2 * 40, "sizeofcmds")
        var offset = 32 + 3 * 72
        expect(u32(offset) == 4 && u32(offset + 4) == 848, "LC_THREAD")
        expect(u32(offset + 8) == 6 && u32(offset + 12) == 68, "ARM_THREAD_STATE64")
        expect(u64(offset + 16) == 0x100 && u64(offset + 16 + 32 * 8) == 0x1000, "x0 and pc")
        expect(u32(offset + 16 + 33 * 8) == 0x6000_0000, "cpsr")
        let exception = offset + 16 + 272
        expect(u32(exception) == 7 && u32(exception + 4) == 4 && u64(exception + 8) == 0xDEAD_0100
            && u32(exception + 16) == 0x5600_0080, "ARM_EXCEPTION_STATE64")
        let neon = exception + 24
        expect(u32(neon) == 17 && u32(neon + 4) == 132 && u64(neon + 8) == 0x100_0000_0100,
               "ARM_NEON_STATE64")
        expect(u32(neon + 8 + 512) == 0x10 && u32(neon + 8 + 516) == 0x0300_0000, "fpsr and fpcr")
        offset += 2 * 848
        expect(u32(offset) == 0x31 && u32(offset + 4) == 40, "LC_NOTE")
        let name = String(decoding: file[offset + 8 ..< offset + 24].prefix { $0 != 0 }, as: UTF8.self)
        expect(name == "addrable bits", "addrable bits note")
        let bits = Int(u64(offset + 24))
        expect(u32(bits) == 4 && u32(bits + 4) == 39 && u32(bits + 8) == 39, "39 address bits, version 4")
        let metadataNote = offset + 40
        let metadataName = String(decoding: file[metadataNote + 8 ..< metadataNote + 24].prefix { $0 != 0 }, as: UTF8.self)
        let payload = file[Int(u64(metadataNote + 24)) ..< Int(u64(metadataNote + 24) + u64(metadataNote + 32))]
        let json = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
        let ids = (json?["threads"] as? [[String: Any]])?.compactMap { ($0["thread_id"] as? NSNumber)?.uint64Value }
        expect(metadataName == "process metadata" && ids == [0x100, 0x101], "thread IDs in order")
        let segment = Int(u64(32 + 40))
        expect(segment % page == 0 && segment >= Int(u64(metadataNote + 24) + u64(metadataNote + 32)),
               "memory after the notes")

        // Without every thread's ID there is no metadata note.
        let unnamed = threads.map { VPhoneGuestThreads.Thread(
            address: $0.address, registers: $0.registers, neon: nil, id: nil, tsd: nil, name: nil,
        ) }
        let notes = VPhoneProcessMemoryDump.notes(threads: unnamed, addressBits: 39).map(\.0)
        expect(notes == ["addrable bits"], "no metadata without IDs")
        expect(VPhoneProcessMemoryDump.threadCommand(unnamed[0]).count == 8 + 280 + 24, "thread without NEON")

        // Address bits cover the highest mapping.
        func mapping(_ end: UInt64) -> VPhoneGuestKernel.Mapping {
            .init(virtual: end - 0x4000, physical: 0, size: 0x4000, entry: 0)
        }
        expect(VPhoneProcessMemoryDump.addressBits([mapping(1 << 39)]) == 39, "39 bits")
        expect(VPhoneProcessMemoryDump.addressBits([mapping(1 << 39 + 0x4000)]) == 40, "40 bits")
        expect(VPhoneProcessMemoryDump.addressBits([mapping(1 << 47)]) == 47, "47 bits")
        expect(VPhoneProcessMemoryDump.addressBits([]) == 39, "no mappings")
    }
}

// MARK: - Live Registers

extension GuestMemoryTests {
    static func liveRegisters(_ expect: (Bool, String) -> Void) throws {
        // Which vCPU runs which thread.
        let root: UInt64 = 0x1_3302_0000
        let ours: Set<UInt64> = [0xFFFF_FE25_248E_3CC8]
        let ttbr0 = 0x07D6 << 48 | root
        func running(_ cpsr: UInt32, _ ttbr0: UInt64, _ thread: UInt64) -> Bool {
            VPhoneGuestThreads.isRunning(cpsr: cpsr, ttbr0: ttbr0, thread: thread, root: root, threads: ours)
        }
        expect(running(0x8000_0000, ttbr0, 0xFFFF_FE25_248E_3CC8), "EL0 on the process's tables, its thread")
        expect(running(0x8000_0000, ttbr0 | 1, 0xFFFF_FE25_248E_3CC8), "CnP bit ignored")
        expect(!running(0x6240_03C4, ttbr0, 0xFFFF_FE25_248E_3CC8), "EL1 is not user code")
        expect(!running(0x8000_0010, ttbr0, 0xFFFF_FE25_248E_3CC8), "AArch32 is not ours")
        expect(!running(0x8000_0000, 0x07D6 << 48 | 0x9F04_8000, 0xFFFF_FE25_248E_3CC8), "other page tables")
        expect(!running(0x8000_0000, ttbr0, 0xFFFF_FE25_2211_9770), "another thread")

        // The session, against a fake stub.
        let kernel = FakeKernelMemory()
        let procs = plantProcesses(kernel, threadCounts: [3])
        let layout = try VPhoneGuestThreads.discover(kernel, sample: procs, map: procMap)
        let threads = try VPhoneGuestThreads.threads(kernel, process: procs[0], layout: layout).threads
        var names = VPhoneGuestDebugStub.generalNames + ["cpsr"] + VPhoneGuestDebugStub.neonNames
        names += ["amx.x0", "esr_el1", "ttbr0_el1", "tpidr_el1", "vbar_el1", "ttbr1_el1"]
        let kernelRegisters: [String: [UInt8]] = [
            "ttbr1_el1": littleBytes(0x7616_0000 | 1), "vbar_el1": littleBytes(0xFFFF_FE00_3FE1_C000),
        ]
        var pair: [Int32] = [0, 0]
        expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "socket pair")
        let stub = FakeDebugStub(descriptor: pair[1], names: names)
        // vCPU 1 idles in the kernel; vCPU 2 runs the second thread at EL0.
        stub.values[1] = [
            "cpsr": littleBytes(0x6240_03C4, count: 4), "ttbr0_el1": littleBytes(0x7616_C000),
            "tpidr_el1": littleBytes(0xFFFF_FE25_2211_9770),
        ].merging(kernelRegisters) { $1 }
        var busy: [String: [UInt8]] = [
            "cpsr": littleBytes(0x8000_0000, count: 4), "ttbr0_el1": littleBytes(ttbr0 | 1),
            "tpidr_el1": littleBytes(threads[1].address), "fpsr": littleBytes(0x10), "fpcr": littleBytes(0x0300_0000),
        ]
        for (index, name) in VPhoneGuestDebugStub.generalNames.enumerated() {
            busy[name] = littleBytes(0x2_0000_A000 + UInt64(index))
        }
        for index in 0 ..< 32 {
            busy["v\(index)"] = littleBytes(UInt64(index)) + littleBytes(UInt64(index) << 8)
        }
        busy.merge(kernelRegisters) { $1 }
        stub.values[2] = busy
        stub.listsThreadsInStop = false
        stub.start()
        let session = VPhoneGuestDebugStub.Session(descriptor: pair[0])
        let reading = try VPhoneGuestDebugStub.registers(session) {
            VPhoneGuestThreads.isRunning(
                cpsr: $0.cpsr, ttbr0: $0.ttbr0, thread: $0.thread, root: root, threads: Set(threads.map(\.address)),
            )
        }
        session.detach()
        stub.done.wait()
        let vcpus = try reading.vcpus.get()
        expect(reading.kernel == .init(ttbr1: 0x7616_0000 | 1, vbar: 0xFFFF_FE00_3FE1_C000), "kernel registers, same session")
        expect(stub.packets.filter { $0 == "QStartNoAckMode" || $0 == "D" }.count == 2, "one session for both")
        expect(stub.packets.filter { $0 == "qRegisterInfo0" }.count == 1, "one register enumeration for both")
        expect(vcpus.map(\.cpu) == [1, 2], "vCPUs from the thread list")
        expect(vcpus[0].cpsr == 0x6240_03C4 && vcpus[0].registers == nil && vcpus[0].neon == nil, "idle vCPU: identity only")
        expect(vcpus[1].thread == threads[1].address && vcpus[1].ttbr0 == ttbr0 | 1, "busy vCPU: thread and tables")
        expect(vcpus[1].registers?.count == 33 && vcpus[1].registers?[32] == 0x2_0000_A020, "busy vCPU: x0–pc")
        expect(vcpus[1].neon?.count == 66 && vcpus[1].neon?[2] == 1 && vcpus[1].neon?[3] == 0x100, "busy vCPU: v1")
        expect(vcpus[1].neon?[64] == UInt64(0x0300_0000) << 32 | 0x10 && vcpus[1].neon?[65] == 0, "busy vCPU: fpsr, fpcr")
        let reads = stub.packets.filter { $0.hasPrefix("p") }
        expect(reads.filter { $0.hasSuffix("thread:1;") }.count == 5, "five reads for an idle vCPU")
        expect(!stub.packets.contains("qRegisterInfo" + String(names.count, radix: 16)), "enumeration stops when all are named")
        expect(stub.packets.first == "QStartNoAckMode" && stub.packets.last == "D", "no-ack first, detach last")

        // The core gets the live registers; info.json keeps the saved ones.
        let merged = VPhoneGuestThreads.withLiveRegisters(threads, vcpus: vcpus)
        expect(merged[1].registers.pc == 0x2_0000_A020 && merged[1].registers.cpsr == 0x8000_0000, "live pc and cpsr")
        expect(merged[1].registers.far == 0 && merged[1].registers.esr == 0, "no pending exception on a live thread")
        expect(merged[1].saved == threads[1].registers && merged[1].neon == vcpus[1].neon, "saved kept, NEON live")
        expect(merged[0].saved == nil && merged[0].registers == threads[0].registers, "other threads unchanged")
        let info = VPhoneProcessMemoryDump.threadDescription(merged[1]).json
        let saved = info["saved"] as? [String: String]
        expect(info["live"] as? Bool == true && saved?["pc"] == hex(threads[1].registers.pc), "info.json: live, with the saved pc")
        expect(saved?["esr"] == hex(UInt64(0x5600_0080)) && info["esr"] as? String == hex(0), "info.json: the saved esr")
        expect(VPhoneProcessMemoryDump.threadDescription(merged[0]).json["live"] == nil, "info.json: saved thread")
        let command = VPhoneProcessMemoryDump.threadCommand(merged[1])
        expect(command.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16 + 32 * 8, as: UInt64.self) } == 0x2_0000_A020,
               "LC_THREAD has the live pc")

        // No double claims, no partial registers, no saved NEON with live registers.
        var twice = vcpus[1]
        twice.registers = Array(repeating: 7, count: 33)
        let doubled = VPhoneGuestThreads.withLiveRegisters(threads, vcpus: [vcpus[1], twice])
        expect(doubled[1].registers.pc == 0x2_0000_A020, "a second vCPU on the same thread ignored")
        var partial = vcpus[1]
        partial.registers = Array(repeating: 7, count: 12)
        expect(VPhoneGuestThreads.withLiveRegisters(threads, vcpus: [partial])[1].saved == nil, "partial registers ignored")
        var noNeon = vcpus[1]
        noNeon.neon = nil
        expect(VPhoneGuestThreads.withLiveRegisters(threads, vcpus: [noNeon])[1].neon == nil, "saved NEON dropped")

        // A vector register the stub will not read leaves NEON out, not the
        // general registers.
        var pair3: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair3)
        let patchy = FakeDebugStub(descriptor: pair3[1], names: names)
        var unreadable = busy
        unreadable["v7"] = nil
        patchy.values[2] = unreadable
        patchy.start()
        let patchySession = VPhoneGuestDebugStub.Session(descriptor: pair3[0])
        let partly = try? VPhoneGuestDebugStub.registers(patchySession) { _ in true }.vcpus.get()
        patchySession.detach()
        patchy.done.wait()
        expect(partly?.first?.registers?.count == 33 && partly?.first?.neon == nil, "unreadable v7: general registers kept")

        // A stub without the registers that identify a thread still places
        // the kernel; one without the kernel's registers places nothing;
        // and none at all.
        var pair2: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair2)
        let bare = FakeDebugStub(descriptor: pair2[1], names: VPhoneGuestDebugStub.generalNames + ["cpsr", "ttbr1_el1", "vbar_el1"])
        bare.values[1] = kernelRegisters
        bare.start()
        let bareSession = VPhoneGuestDebugStub.Session(descriptor: pair2[0])
        let bareReading = try? VPhoneGuestDebugStub.registers(bareSession) { _ in true }
        expect(bareReading != nil && (try? bareReading?.vcpus.get()) == nil, "no tpidr_el1: kernel placed, vCPUs refused")
        bareSession.detach()
        bare.done.wait()
        var pair4: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair4)
        let kernelless = FakeDebugStub(descriptor: pair4[1], names: names.filter { $0 != "vbar_el1" })
        kernelless.values[2] = busy
        kernelless.start()
        let kernellessSession = VPhoneGuestDebugStub.Session(descriptor: pair4[0])
        expect((try? VPhoneGuestDebugStub.registers(kernellessSession) { _ in true }) == nil, "no vbar_el1: refused")
        kernellessSession.detach()
        kernelless.done.wait()
        expect((try? VPhoneGuestDebugStub.registers(port: 1) { _ in true }) == nil, "no stub listening")
    }
}
