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
        expect(VPhoneGuestDebugStub.little([0x78, 0x56, 0x34, 0x12]) == 0x1234_5678, "little-endian value")
        expect(VPhoneGuestDebugStub.fields("T11thread:1;threads:1,2;")["threads"] == "1,2", "reply fields")

        func read(
            names: [String] = ["x0", "cpsr", "ttbr1_el1", "vbar_el1"],
            _ values: [Int: [String: [UInt8]]],
        ) -> (Result<VPhoneGuestDebugStub.KernelRegisters, Error>, [String]) {
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return (.failure(POSIXError(.EIO)), []) }
            let stub = FakeDebugStub(descriptor: pair[1], names: names)
            stub.values = values
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
