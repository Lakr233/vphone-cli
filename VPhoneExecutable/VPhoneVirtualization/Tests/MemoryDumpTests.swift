import Foundation
import Virtualization

/// `VPhoneMemoryDump.save` names only these; the real VM needs the whole stack.
@MainActor
final class VPhoneVirtualMachine {
    let virtualMachine: VZVirtualMachine
    let memorySize: UInt64 = 0
    let cpuCount = 0

    init(virtualMachine: VZVirtualMachine) {
        self.virtualMachine = virtualMachine
    }
}

@main
enum MemoryDumpTests {
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
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Blocks: zero, data, data, zero ×3, data, then a 100-byte tail of data.
        let block = 16 * 1024
        var bytes = [UInt8](repeating: 0, count: block * 7 + 100)
        for index in [1, 2, 6] {
            for offset in stride(from: index * block, to: (index + 1) * block, by: 97) {
                bytes[offset] = UInt8(truncatingIfNeeded: offset / 97 + 1)
            }
        }
        bytes[block * 7 + 99] = 0xAB
        let url = folder.appendingPathComponent("sparse.core")
        let stored = try bytes.withUnsafeBytes { buffer in
            try VPhoneMemoryDump.writeSparse(buffer.baseAddress!, length: buffer.count, to: url)
        }
        let written = try Data(contentsOf: url)
        expect(written == Data(bytes), "the file holds every byte, zero blocks included")
        expect(stored == UInt64(block * 3 + 100), "only the data blocks are written")

        // APFS allocates a file of up to 16 MB in full, holes or not, so the
        // holes are checked on a larger one: 64 MiB with two data blocks.
        let large = folder.appendingPathComponent("large.core")
        var wide = [UInt8](repeating: 0, count: 64 << 20)
        wide[5] = 1
        wide[wide.count - 5] = 1
        let wideStored = try wide.withUnsafeBytes { buffer in
            try VPhoneMemoryDump.writeSparse(buffer.baseAddress!, length: buffer.count, to: large)
        }
        expect(wideStored == UInt64(2 * block), "two data blocks stored")
        var status = stat()
        expect(stat(large.path, &status) == 0, "stat")
        expect(Int(status.st_blocks) * 512 < 1 << 20, "the zero blocks are holes: \(status.st_blocks) blocks")
        expect(try Data(contentsOf: large) == Data(wide), "the sparse file reads back whole")

        // An existing file is never overwritten.
        do {
            _ = try bytes.withUnsafeBytes { buffer in
                try VPhoneMemoryDump.writeSparse(buffer.baseAddress!, length: buffer.count, to: url)
            }
            expect(false, "a second write to the same file is refused")
        } catch {
            expect("\(error)".contains("open"), "the refusal names open: \(error)")
        }

        // A dump of nothing but zeros is all hole.
        let empty = folder.appendingPathComponent("zero.core")
        let zeros = [UInt8](repeating: 0, count: block * 4)
        let none = try zeros.withUnsafeBytes { buffer in
            try VPhoneMemoryDump.writeSparse(buffer.baseAddress!, length: buffer.count, to: empty)
        }
        expect(none == 0, "an all-zero core stores nothing")
        expect((try? FileManager.default.attributesOfItem(atPath: empty.path)[.size] as? Int) == block * 4,
               "an all-zero core keeps its length")

        expect(VPhoneMemoryDump.fileName(forCore: "AP") == "AP.core", "AP")
        expect(VPhoneMemoryDump.fileName(forCore: "SEP-coproc") == "SEP-coproc.core", "SEP")
        expect(VPhoneMemoryDump.fileName(forCore: "../x y") == "core.._x_y.core", "no path or space survives")
        expect(VPhoneMemoryDump.fileName(forCore: "") == "core.core", "an empty name")

        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 11, 19)
        (components.hour, components.minute, components.second) = (15, 20, 11)
        let date = Calendar.current.date(from: components)!
        expect(VPhoneMemoryDump.folderName(machine: "myphone", date: date) == "myphone Memory 2026-11-19 at 15.20.11",
               "the folder is named for the machine and the local time")

        expect(VPhoneMemoryDump.spaceNeeded(memorySize: 8 << 30) > 8_579_268_608,
               "the estimate covers an 8 GiB guest's AP core")
        expect(VPhoneMemoryDump.tenths(14.300000000000001).stringValue == "14.3", "tenths")
        let json = try JSONSerialization.data(withJSONObject: ["s": VPhoneMemoryDump.tenths(8.66)])
        expect(String(decoding: json, as: UTF8.self) == "{\"s\":8.7}", "tenths stay exact in JSON")

        try? FileManager.default.removeItem(at: folder)
        print("MemoryDumpTests: \(checks) checks passed")
    }
}
