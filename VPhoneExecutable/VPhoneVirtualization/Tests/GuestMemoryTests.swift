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
        expect(u32(0) == 0xFEED_FACF && u32(12) == 4 && u32(16) == 3, "Mach-O core header")
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
        expect(VPhoneGuestPhysicalMemory.deviceTreeValue("dram-base", in: ram, size: size) == 0x8000_0000, "dram-base")
        expect(VPhoneGuestPhysicalMemory.deviceTreeValue("dram-size", in: ram, size: size) == nil, "absent property")
        let carveOuts = VPhoneGuestPhysicalMemory.deviceTreeCarveOuts(in: ram, size: size)
        expect(carveOuts.map(\.base) == [0x7F00_0000, 0x7F80_0000] && carveOuts.map(\.size) == [0x4000, 0x8000],
               "carve-outs")

        // Used pages become runs; unknown use means the whole region.
        let p = UInt64(page)
        expect(VPhonePhysicalMemoryDump.usedRuns(nil, size: 5 * p) == [0 ..< 5 * p], "unknown use")
        expect(VPhonePhysicalMemoryDump.usedRuns([false, true, true, false, true], size: 5 * p)
            == [p ..< 3 * p, 4 * p ..< 5 * p], "used runs")
        expect(VPhonePhysicalMemoryDump.usedRuns([false, false], size: 2 * p).isEmpty, "nothing used")

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
        try plantedHeaders(expect, recipes: recipes)

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

        // No kernel in RAM full of fake fileset headers: an error, not a trap.
        for index in 0 ..< 64 {
            header(at: ram + index * page, commands: [(0x8000_0035, 32)])
            (ram + index * page).storeBytes(of: UInt32(0x0100_000C), toByteOffset: 4, as: UInt32.self)
            (ram + index * page).storeBytes(of: UInt32(0xC), toByteOffset: 12, as: UInt32.self)
            (ram + index * page).storeBytes(of: UInt64.max, toByteOffset: 32 + 16, as: UInt64.self)
        }
        expect(VPhoneGuestKernel.findKernels(memory, symbolsRoot: nil).candidates.isEmpty, "fake fileset headers")
        do {
            _ = try VPhoneGuestKernel(memory: memory, symbolsRoot: nil)
            expect(false, "no kernel refused")
        } catch {
            expect(true, "no kernel refused")
        }

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

// MARK: - Planted Headers

extension GuestMemoryTests {
    /// A kernelcache header at `pointer`: an `MH_FILESET` whose
    /// `com.apple.kernel` entry, one page further, has `uuid` and a `__TEXT`.
    static func plantKernelcache(at pointer: UnsafeMutableRawPointer, uuid: UUID) {
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: 2 * page)
        func u32(_ value: UInt32, _ offset: Int) { pointer.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
        func u64(_ value: UInt64, _ offset: Int) { pointer.storeBytes(of: value, toByteOffset: offset, as: UInt64.self) }
        u32(0xFEED_FACF, 0); u32(0x0100_000C, 4); u32(0xC, 12); u32(1, 16); u32(56, 20)
        u32(0x8000_0035, 32); u32(56, 36); u64(UInt64(page), 48); u32(32, 56)
        for (index, byte) in Array("com.apple.kernel".utf8).enumerated() {
            pointer.storeBytes(of: byte, toByteOffset: 32 + 32 + index, as: UInt8.self)
        }
        let kernel = pointer + page
        kernel.storeBytes(of: UInt32(0xFEED_FACF), as: UInt32.self)
        kernel.storeBytes(of: UInt32(2), toByteOffset: 16, as: UInt32.self)
        kernel.storeBytes(of: UInt32(72 + 24), toByteOffset: 20, as: UInt32.self)
        kernel.storeBytes(of: UInt32(0x19), toByteOffset: 32, as: UInt32.self)
        kernel.storeBytes(of: UInt32(72), toByteOffset: 36, as: UInt32.self)
        for (index, byte) in Array("__TEXT".utf8).enumerated() {
            kernel.storeBytes(of: byte, toByteOffset: 40 + index, as: UInt8.self)
        }
        kernel.storeBytes(of: UInt64(0xFFFF_FE00_0000_0000), toByteOffset: 32 + 24, as: UInt64.self)
        kernel.storeBytes(of: UInt64(page), toByteOffset: 32 + 32, as: UInt64.self)
        kernel.storeBytes(of: UInt32(0x1B), toByteOffset: 32 + 72, as: UInt32.self)
        kernel.storeBytes(of: UInt32(24), toByteOffset: 32 + 76, as: UInt32.self)
        withUnsafeBytes(of: uuid.uuid) { bytes in
            for (index, byte) in bytes.enumerated() {
                kernel.storeBytes(of: byte, toByteOffset: 32 + 80 + index, as: UInt8.self)
            }
        }
    }

    /// Headers whose kernel has no symbol map are passed over without
    /// counting against the candidate limit, so many of them below the real
    /// kernelcache do not hide it.
    static func plantedHeaders(_ expect: (Bool, String) -> Void, recipes: URL) throws {
        let manifest = recipes.appendingPathComponent("bases/27.2_24B119/manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let known = (object?["kernelUUID"] as? String).flatMap(UUID.init(uuidString:)) else {
            expect(false, "27.2 manifest has a kernelUUID")
            return
        }
        let pages = 64
        let ram = guarded(pages * page)
        let memory = VPhoneGuestPhysicalMemory(
            dram: .init(guestAddress: dramBase, size: UInt64(pages * page), base: UnsafeRawPointer(ram)),
            carveOut: nil, mappings: [],
        )
        let planted = 20
        for index in 0 ..< planted {
            plantKernelcache(at: ram + index * 2 * page, uuid: UUID())
        }
        plantKernelcache(at: ram + planted * 2 * page, uuid: known)
        let (candidates, unknown) = VPhoneGuestKernel.findKernels(memory, symbolsRoot: recipes)
        expect(candidates.count == 1 && candidates[0].1.uuid == known.uuidString
            && candidates[0].0 == dramBase + UInt64(planted * 2 * page),
            "known kernel found after \(planted) headers with unknown UUIDs")
        expect(unknown != nil && unknown != known.uuidString, "first unknown UUID reported")
        expect(VPhoneKernelSymbols.hasMap(kernelUUID: known.uuidString.lowercased(), root: recipes),
               "UUID lookup ignores case")
    }
}
