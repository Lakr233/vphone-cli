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

        let mappings = tables.mappings()
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
