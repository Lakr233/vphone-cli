import Foundation

// MARK: - Guest Kernel

/// The guest's kernel, read from guest memory alone: where its kernelcache
/// sits, its page tables, and its process list.
///
/// - The kernelcache is found by its Mach-O header in DRAM. iBoot loads it in
///   one piece, so `__TEXT` and `__DATA_CONST` sit at their file offsets;
///   SPTM moves the executable and writable segments elsewhere.
/// - The kernel's root translation table (TTBR1) is the one page in DRAM
///   that maps those two segments where they were found, and it must equal
///   the `ttep` of `kernel_pmap`.
/// - The process list starts at `kernproc` (pid 0, last in `allproc`) and
///   goes back through `p_list.le_prev`. The offsets of `p_pid`, `p_comm` and
///   `task → map → pmap` are found by what is known about the first two
///   entries (`kernel_task`, pid 0; `launchd`, pid 1) and by the pmap's own
///   check: its `tte` must translate to its `ttep`.
///
/// Only `_kernproc` and `_kernel_pmap` come from the kernel's symbol map
/// (`VPhoneKernelSymbols`); nothing here depends on an iOS version.
/// See Research/Host/process_memory_dump.md.
final class VPhoneGuestKernel: @unchecked Sendable {
    struct Segment {
        let name: String
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt64
    }

    struct Process {
        let pid: Int32
        let name: String
        let address: UInt64
        /// The physical address of the process's root translation table.
        let pageTableRoot: UInt64?
    }

    struct Layout {
        let pid: UInt64
        let name: UInt64
        let map: UInt64
        let pmap: UInt64
    }

    /// One translation of a user address range: `size` bytes at `virtual`
    /// are at `physical`; `entry` is the descriptor, for the permissions.
    struct Mapping {
        let virtual: UInt64
        let physical: UInt64
        let size: UInt64
        let entry: UInt64
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case noKernelcache
        case noPageTables
        case unexpected(String)
        case noProcess(Int32)

        var errorDescription: String? {
            switch self {
            case .noKernelcache:
                "The guest's kernel is not in its memory. Wait until the guest has booted, then try again."
            case .noPageTables:
                "The guest kernel's page tables were not found in its memory."
            case let .unexpected(what):
                "The guest kernel is laid out differently than expected: \(what)."
            case let .noProcess(pid):
                "No process with pid \(pid) runs in the guest."
            }
        }

        var description: String { errorDescription ?? "guest kernel unreadable" }
    }

    let memory: VPhoneGuestPhysicalMemory
    let kernelcachePhysical: UInt64
    let kernelUUID: String
    let segments: [Segment]
    /// The physical address of the kernel's root translation table (TTBR1).
    let root: UInt64
    let symbols: VPhoneKernelSymbols
    /// The kernel's own pmap (`kernel_pmap_store`).
    private(set) var kernelPmap: UInt64 = 0
    /// The offsets `processes()` found, once it has run.
    private(set) var layout: Layout?
    private let imageLow: UInt64
    private let imageHigh: UInt64

    static let pageSize: UInt64 = 0x4000
    private static let tableMask: UInt64 = 0x0000_FFFF_FFFF_C000

    init(memory: VPhoneGuestPhysicalMemory, symbolsRoot: URL? = VPhoneKernelSymbols.recipesDirectory) throws {
        self.memory = memory
        guard let (kernelcache, kernel) = Self.findKernel(memory) else { throw Failure.noKernelcache }
        kernelcachePhysical = kernelcache
        kernelUUID = kernel.uuid
        segments = kernel.segments
        imageLow = kernel.segments.map(\.address).min() ?? 0
        imageHigh = kernel.segments.map { $0.address + $0.size }.max() ?? 0

        // __TEXT and __DATA_CONST are where the file put them: pairs of a
        // virtual address and the physical address it must translate to.
        var known: [(UInt64, UInt64)] = []
        for name in ["__TEXT", "__DATA_CONST"] {
            guard let segment = kernel.segments.first(where: { $0.name == name }), segment.size >= Self.pageSize
            else { throw Failure.unexpected("the kernel has no \(name)") }
            for offset in [0, (segment.size / 2) & ~(Self.pageSize - 1), segment.size - Self.pageSize] {
                known.append((segment.address + offset, kernelcache + segment.fileOffset + offset))
            }
        }
        guard let root = Self.findRoot(memory, known: known) else { throw Failure.noPageTables }
        self.root = root

        symbols = try VPhoneKernelSymbols.load(kernelUUID: kernel.uuid, root: symbolsRoot)
        guard let pointer = try read64(symbol: "_kernel_pmap") else {
            throw Failure.unexpected("kernel_pmap is not mapped")
        }
        let pmap = Self.strip(pointer)
        guard let tte = read64(virtual: pmap), let ttep = read64(virtual: pmap + 8),
              ttep == root, translate(Self.strip(tte)) == ttep
        else { throw Failure.unexpected("kernel_pmap does not hold the kernel's page tables") }
        kernelPmap = pmap
    }

    // MARK: - Translation

    /// Translates a kernel address, or one under another root table.
    func translate(_ address: UInt64, root: UInt64? = nil) -> UInt64? {
        VPhoneGuestPageTables(memory: memory, root: root ?? self.root).translate(address)
    }

    func read64(virtual address: UInt64) -> UInt64? {
        // A read never crosses a 16 KB page: the caller's fields are aligned.
        guard let physical = translate(address) else { return nil }
        return memory.read64(physical: physical)
    }

    func read32(virtual address: UInt64) -> UInt32? {
        guard let physical = translate(address), let pointer = memory.pointer(physical: physical, count: 4) else {
            return nil
        }
        return pointer.loadUnaligned(as: UInt32.self)
    }

    func string(virtual address: UInt64, maximum: Int) -> String? {
        guard let physical = translate(address),
              let pointer = memory.pointer(physical: physical, count: maximum)
        else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: maximum)
        guard let end = bytes.firstIndex(of: 0) else { return nil }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// The runtime address of a symbol of the kernel's map.
    func address(symbol name: String) throws -> UInt64 {
        let (segmentName, offset) = try symbols.location(of: name)
        guard let segment = segments.first(where: { $0.name == segmentName }) else {
            throw Failure.unexpected("the kernel has no \(segmentName)")
        }
        return segment.address + offset
    }

    func read64(symbol name: String) throws -> UInt64? {
        try read64(virtual: address(symbol: name))
    }

    /// A kernel pointer without its pointer authentication code: the upper
    /// 17 bits of a kernel address are ones.
    static func strip(_ pointer: UInt64) -> UInt64 {
        pointer >> 47 != 0 ? pointer | 0xFFFF_8000_0000_0000 : pointer
    }

    // MARK: - Processes

    /// Every process in `allproc`, kernel_task first, then launchd and on to
    /// the newest.
    func processes() throws -> [Process] {
        guard let first = try read64(symbol: "_kernproc").map(Self.strip), translate(first) != nil else {
            throw Failure.unexpected("kernproc does not point to a process")
        }
        var list = [first]
        var seen: Set<UInt64> = [first]
        var current = first
        while list.count < 100_000, let previous = read64(virtual: current + 8).map(Self.strip),
              previous != 0, !(imageLow ..< imageHigh).contains(previous), !seen.contains(previous),
              translate(previous) != nil
        {
            list.append(previous)
            seen.insert(previous)
            current = previous
        }
        guard list.count >= 2 else { throw Failure.unexpected("the process list has only kernel_task") }
        let layout = try discoverLayout(list)
        self.layout = layout
        return list.map { address in
            Process(
                pid: Int32(bitPattern: read32(virtual: address + layout.pid) ?? 0),
                name: string(virtual: address + layout.name, maximum: 17) ?? "",
                address: address,
                pageTableRoot: pageTableRoot(process: address, map: layout.map, pmap: layout.pmap),
            )
        }
    }

    func process(pid: Int32) throws -> Process {
        guard let process = try processes().first(where: { $0.pid == pid }) else { throw Failure.noProcess(pid) }
        return process
    }

    /// Where `p_pid`, `p_comm` and the map and pmap pointers are.
    func discoverLayout(_ list: [UInt64]) throws -> Layout {
        let kernelTask = list[0], launchd = list[1]

        // Of the offsets where kernel_task reads 0 and launchd 1, the one with
        // the most distinct values over the whole list: other fields start
        // the same way (the responsible pid, for one) but repeat across
        // processes. Counting, rather than requiring every value distinct,
        // tolerates an entry being created or torn down while the guest was
        // paused.
        var best: (offset: UInt64, distinct: Int)?
        for offset in stride(from: UInt64(0), to: 0x400, by: 4) {
            guard read32(virtual: kernelTask + offset) == 0, read32(virtual: launchd + offset) == 1 else { continue }
            var values: Set<UInt32> = []
            for process in list {
                if let value = read32(virtual: process + offset), value < 100_000 { values.insert(value) }
            }
            if values.count > best?.distinct ?? 0 { best = (offset, values.count) }
        }
        guard let best, best.distinct * 10 >= list.count * 9 else { throw Failure.unexpected("no p_pid field") }
        let pid = best.offset

        let name = try stride(from: UInt64(0), to: 0x1000, by: 4).first { offset in
            string(virtual: kernelTask + offset, maximum: 17) == "kernel_task"
                && string(virtual: launchd + offset, maximum: 17) == "launchd"
        }.unwrap(or: Failure.unexpected("no p_comm field"))

        // The task follows the proc in one allocation; its map points to a
        // pmap whose tte translates to its ttep. The first offsets that hold
        // for every sampled process are the ones; later hits are neighbours.
        let pmapSample = Array(list.dropFirst().prefix(8))
        for map in stride(from: UInt64(0), to: 0x1000, by: 8) {
            for pmap in stride(from: UInt64(0), to: 0x200, by: 8)
                where pmapSample.allSatisfy({ pageTableRoot(process: $0, map: map, pmap: pmap) != nil })
            {
                return Layout(pid: pid, name: name, map: map, pmap: pmap)
            }
        }
        throw Failure.unexpected("no task map with a pmap")
    }

    func pageTableRoot(process: UInt64, map: UInt64, pmap: UInt64) -> UInt64? {
        guard let mapPointer = read64(virtual: process + map).map(Self.strip), translate(mapPointer) != nil,
              let pmapPointer = read64(virtual: mapPointer + pmap).map(Self.strip),
              pmapPointer != kernelPmap, translate(pmapPointer) != nil,
              let tte = read64(virtual: pmapPointer), let ttep = read64(virtual: pmapPointer + 8),
              ttep & (Self.pageSize - 1) == 0, memory.contains(physical: ttep),
              translate(Self.strip(tte)) == ttep
        else { return nil }
        return ttep
    }

    /// The valid translations of a process's address space, in address order.
    func userMappings(root: UInt64) -> [Mapping] {
        VPhoneGuestPageTables(memory: memory, root: root).mappings()
    }

    // MARK: - Locating

    private struct KernelImage {
        let uuid: String
        let segments: [Segment]
    }

    /// The kernelcache's Mach-O header in DRAM, and the kernel inside it.
    private static func findKernel(_ memory: VPhoneGuestPhysicalMemory) -> (UInt64, KernelImage)? {
        let dram = memory.dram
        var offset: UInt64 = 0
        while offset + pageSize <= dram.size {
            let header = dram.base + Int(offset)
            if header.loadUnaligned(as: UInt32.self) == 0xFEED_FACF,
               header.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 0x0100_000C,
               header.loadUnaligned(fromByteOffset: 12, as: UInt32.self) == 0xC,  // MH_FILESET
               let entry = filesetEntry("com.apple.kernel", header: header, available: dram.size - offset),
               entry < dram.size - offset,
               let kernel = image(header + Int(entry), available: dram.size - offset - entry)
            {
                return (dram.guestAddress + offset, kernel)
            }
            offset += pageSize
        }
        return nil
    }

    private static func loadCommands(_ header: UnsafeRawPointer, available: UInt64) -> [(UInt32, UnsafeRawPointer, Int)] {
        let count = Int(header.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        let size = Int(header.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
        guard count < 100_000, UInt64(32 + size) <= available else { return [] }
        var result: [(UInt32, UnsafeRawPointer, Int)] = []
        var cursor = 32
        for _ in 0 ..< count {
            guard cursor + 8 <= 32 + size else { break }
            let command = header.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            let length = Int(header.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
            guard length >= 8, cursor + length <= 32 + size else { break }
            result.append((command, header + cursor, length))
            cursor += length
        }
        return result
    }

    /// The file offset of a fileset entry (`LC_FILESET_ENTRY`).
    private static func filesetEntry(_ name: String, header: UnsafeRawPointer, available: UInt64) -> UInt64? {
        for (command, pointer, length) in loadCommands(header, available: available) where command == 0x8000_0035 {
            let nameOffset = Int(pointer.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
            guard nameOffset < length else { continue }
            let bytes = UnsafeRawBufferPointer(start: pointer + nameOffset, count: length - nameOffset)
            let entryName = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            if entryName == name {
                return pointer.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            }
        }
        return nil
    }

    private static func image(_ header: UnsafeRawPointer, available: UInt64) -> KernelImage? {
        guard header.loadUnaligned(as: UInt32.self) == 0xFEED_FACF else { return nil }
        var segments: [Segment] = []
        var uuid: String?
        for (command, pointer, _) in loadCommands(header, available: available) {
            if command == 0x19 {  // LC_SEGMENT_64
                let bytes = UnsafeRawBufferPointer(start: pointer + 8, count: 16)
                let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                let size = pointer.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
                guard size > 0 else { continue }
                segments.append(Segment(
                    name: name,
                    address: pointer.loadUnaligned(fromByteOffset: 24, as: UInt64.self),
                    size: size,
                    fileOffset: pointer.loadUnaligned(fromByteOffset: 40, as: UInt64.self),
                ))
            } else if command == 0x1B {  // LC_UUID
                let bytes = (0 ..< 16).map { pointer.load(fromByteOffset: 8 + $0, as: UInt8.self) }
                uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                    .uuidString
            }
        }
        guard let uuid, !segments.isEmpty else { return nil }
        return KernelImage(uuid: uuid, segments: segments)
    }

    /// The page in DRAM that, as a root table, maps every known pair.
    private static func findRoot(_ memory: VPhoneGuestPhysicalMemory, known: [(UInt64, UInt64)]) -> UInt64? {
        guard let (firstAddress, _) = known.first else { return nil }
        let index = Int((firstAddress >> 36) & 0x7FF)
        let dram = memory.dram
        var offset: UInt64 = 0
        while offset + pageSize <= dram.size {
            let entry = (dram.base + Int(offset) + index * 8).loadUnaligned(as: UInt64.self)
            if entry & 3 == 3, memory.contains(physical: entry & tableMask) {
                let candidate = dram.guestAddress + offset
                let probe = VPhoneGuestPageTables(memory: memory, root: candidate)
                if known.allSatisfy({ probe.translate($0.0) == $0.1 }) {
                    return candidate
                }
            }
            offset += pageSize
        }
        return nil
    }
}

// MARK: - Page Tables

/// The guest's ARMv8 translation tables with a 16 KB granule: three levels
/// of 2048 entries, indexed by address bits 46–36, 35–25 and 24–14. A level-1
/// or level-2 entry may be a block (64 GB, 32 MB) instead of a table.
struct VPhoneGuestPageTables {
    let memory: VPhoneGuestPhysicalMemory
    let root: UInt64

    private static let shifts: [UInt64] = [36, 25, 14]
    private static let tableMask: UInt64 = 0x0000_FFFF_FFFF_C000
    private static let outputMask: UInt64 = 0x0000_FFFF_FFFF_FFFF

    func translate(_ address: UInt64) -> UInt64? {
        var table = root & Self.tableMask
        for shift in Self.shifts {
            guard let entry = memory.read64(physical: table + ((address >> shift) & 0x7FF) * 8), entry & 1 != 0 else {
                return nil
            }
            let span: UInt64 = 1 << shift
            if shift == 14 {
                return entry & 2 == 0 ? nil : (entry & Self.tableMask) | (address & (span - 1))
            }
            if entry & 2 == 0 {  // block
                return (entry & Self.outputMask & ~(span - 1)) | (address & (span - 1))
            }
            table = entry & Self.tableMask
        }
        return nil
    }

    /// Every valid translation below 2^47, in address order; `entry` is the
    /// descriptor, for the permissions.
    func mappings() -> [VPhoneGuestKernel.Mapping] {
        var result: [VPhoneGuestKernel.Mapping] = []
        func level(_ table: UInt64, shift: UInt64, base: UInt64) {
            for index in UInt64(0) ..< 2048 {
                guard let entry = memory.read64(physical: table + index * 8), entry & 1 != 0 else { continue }
                let address = base | (index << shift)
                let span: UInt64 = 1 << shift
                if shift == 14 {
                    if entry & 2 != 0 {
                        result.append(.init(virtual: address, physical: entry & Self.tableMask, size: span, entry: entry))
                    }
                } else if entry & 2 == 0 {
                    let physical = entry & Self.outputMask & ~(span - 1)
                    result.append(.init(virtual: address, physical: physical, size: span, entry: entry))
                } else {
                    level(entry & Self.tableMask, shift: shift - 11, base: address)
                }
            }
        }
        level(root & Self.tableMask, shift: 36, base: 0)
        return result
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
