import Foundation

// MARK: - Guest Kernel

/// The guest's kernel, read from guest memory: where its kernelcache sits,
/// its page tables, and its process list.
///
/// - Two registers of the vCPUs, read through Virtualization's kernel debug
///   stub (`VPhoneGuestDebugStub.KernelRegisters`), place it: `TTBR1_EL1` is
///   the root of its translation tables, and `VBAR_EL1`, its exception
///   vectors, lies in the kernelcache, whose `MH_FILESET` header is the first
///   one below them in the kernel's address space. The header's
///   `com.apple.kernel` entry gives the kernel's UUID and segments, and
///   `kernel_pmap`'s `ttep` must be the root.
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
                "The guest's kernelcache is not below its exception vectors. Wait until the guest has booted, then try again."
            case .noPageTables:
                "The guest kernel's page tables (TTBR1_EL1) are not in its RAM."
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
    let kernelPmap: UInt64
    /// The offsets `processes()` found, once it has run.
    private(set) var layout: Layout?
    private let imageLow: UInt64
    private let imageHigh: UInt64

    static let pageSize: UInt64 = 0x4000
    /// More processes than iOS allows; a longer list is not followed.
    static let processLimit = 20000
    private static let tableMask: UInt64 = 0x0000_FFFF_FFFF_C000

    /// The kernel that `registers` describe. Every page read here is reached
    /// through the kernel's own tables at a kernel address, so nothing an app
    /// writes into its pages is looked at.
    init(
        memory: VPhoneGuestPhysicalMemory,
        registers: VPhoneGuestDebugStub.KernelRegisters,
        symbolsRoot: URL? = VPhoneKernelSymbols.recipesDirectory,
    ) throws {
        self.memory = memory
        root = registers.root
        guard memory.contains(physical: root) else { throw Failure.noPageTables }
        let tables = VPhoneGuestPageTables(memory: memory, root: root)
        guard let fileset = Self.filesetHeader(tables, below: registers.vbar) else { throw Failure.noKernelcache }
        guard let header = Self.mapped(tables, at: fileset),
              let entry = Self.filesetEntry("com.apple.kernel", header: header.pointer, available: header.available),
              let kernelHeader = Self.mapped(tables, at: entry),
              let kernel = Self.image(kernelHeader.pointer, available: kernelHeader.available)
        else { throw Failure.unexpected("the kernelcache has no readable com.apple.kernel") }
        kernelcachePhysical = tables.translate(fileset) ?? 0
        kernelUUID = kernel.uuid
        segments = kernel.segments
        imageLow = segments.map(\.address).min() ?? 0
        imageHigh = segments.map { $0.address &+ $0.size }.max() ?? 0

        // The symbol map and kernel_pmap must agree with the registers.
        symbols = try VPhoneKernelSymbols.load(kernelUUID: kernel.uuid, root: symbolsRoot)
        let (segmentName, offset) = try symbols.location(of: "_kernel_pmap")
        guard let segment = segments.first(where: { $0.name == segmentName }) else {
            throw Failure.unexpected("the kernel has no \(segmentName)")
        }
        func read64(_ address: UInt64) -> UInt64? {
            tables.translate(address).flatMap { memory.read64(physical: $0) }
        }
        guard let pointer = read64(segment.address &+ offset) else {
            throw Failure.unexpected("kernel_pmap is not mapped")
        }
        kernelPmap = Self.strip(pointer)
        guard let tte = read64(kernelPmap), let ttep = read64(kernelPmap &+ 8),
              ttep == root, tables.translate(Self.strip(tte)) == ttep
        else { throw Failure.unexpected("kernel_pmap does not hold the page tables in TTBR1_EL1") }
    }

    /// The kernel in `memory`, placed at the `dram-base` the registers agree
    /// with (`VPhoneGuestPhysicalMemory.placed(kernel:)`).
    static func locate(
        in memory: VPhoneGuestPhysicalMemory,
        registers: VPhoneGuestDebugStub.KernelRegisters,
        symbolsRoot: URL? = VPhoneKernelSymbols.recipesDirectory,
    ) throws -> VPhoneGuestKernel {
        guard let placed = memory.placed(kernel: registers) else { throw Failure.noPageTables }
        return try VPhoneGuestKernel(memory: placed, registers: registers, symbolsRoot: symbolsRoot)
    }

    /// How far below the exception vectors the kernelcache header may be:
    /// 1 GB of kernel address space. On 27.2 it is 1,861 pages below, past
    /// the kexts' and the kernel's own Mach-O headers.
    static let headerSearchLimit = 65536

    /// The kernel address of the kernelcache's `MH_FILESET` header: the first
    /// page at or below `vectors` that starts with one. Unmapped pages are
    /// passed over; each page costs one translation.
    static func filesetHeader(_ tables: VPhoneGuestPageTables, below vectors: UInt64) -> UInt64? {
        var address = vectors & ~(pageSize - 1)
        for _ in 0 ..< headerSearchLimit {
            if let physical = tables.translate(address),
               let header = tables.memory.pointer(physical: physical, count: 16),
               header.loadUnaligned(as: UInt32.self) == 0xFEED_FACF,
               header.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 0x0100_000C,
               header.loadUnaligned(fromByteOffset: 12, as: UInt32.self) == 0xC  // MH_FILESET
            {
                return address
            }
            guard address >= pageSize else { return nil }
            address -= pageSize
        }
        return nil
    }

    /// Where the kernelcache was slid: its `MH_FILESET` header where it runs,
    /// minus the link-time `vmaddr` of its first `LC_SEGMENT_64`. Needs no
    /// symbol map, so it also serves a kernel without one.
    static func filesetSlide(_ tables: VPhoneGuestPageTables, below vectors: UInt64) -> (header: UInt64, linkTime: UInt64, slide: UInt64)? {
        guard let header = filesetHeader(tables, below: vectors),
              let mapped = mapped(tables, at: header),
              let (_, pointer, _) = loadCommands(mapped.pointer, available: mapped.available).first(where: { $0.0 == 0x19 })
        else { return nil }
        let linkTime = pointer.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        return (header, linkTime, header &- linkTime)
    }

    /// The bytes at a kernel address that are mapped contiguously in guest
    /// RAM, up to 1 MB: enough for any header `loadCommands` reads. Each
    /// further page must follow on both in guest physical memory and in
    /// this process: the carve-outs end where DRAM starts, but the two are
    /// separate mappings on the host.
    static func mapped(_ tables: VPhoneGuestPageTables, at address: UInt64) -> (pointer: UnsafeRawPointer, available: UInt64)? {
        guard let physical = tables.translate(address),
              let pointer = tables.memory.pointer(physical: physical, count: 1)
        else { return nil }
        var available = pageSize - (address & (pageSize - 1))
        while available < 1 << 20,
              tables.translate(address &+ available) == physical &+ available,
              tables.memory.pointer(physical: physical &+ available, count: Int(pageSize)) == pointer + Int(available)
        {
            available += pageSize
        }
        return (pointer, available)
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
        return segment.address &+ offset
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
        while list.count < Self.processLimit, let previous = read64(virtual: current &+ 8).map(Self.strip),
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
                pid: Int32(bitPattern: read32(virtual: address &+ layout.pid) ?? 0),
                name: string(virtual: address &+ layout.name, maximum: 17) ?? "",
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
            guard read32(virtual: kernelTask &+ offset) == 0, read32(virtual: launchd &+ offset) == 1 else { continue }
            var values: Set<UInt32> = []
            for process in list {
                if let value = read32(virtual: process &+ offset), value < 100_000 { values.insert(value) }
            }
            if values.count > best?.distinct ?? 0 { best = (offset, values.count) }
        }
        guard let best, best.distinct * 10 >= list.count * 9 else { throw Failure.unexpected("no p_pid field") }
        let pid = best.offset

        let name = try stride(from: UInt64(0), to: 0x1000, by: 4).first { offset in
            string(virtual: kernelTask &+ offset, maximum: 17) == "kernel_task"
                && string(virtual: launchd &+ offset, maximum: 17) == "launchd"
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
        guard let mapPointer = read64(virtual: process &+ map).map(Self.strip), translate(mapPointer) != nil,
              let pmapPointer = read64(virtual: mapPointer &+ pmap).map(Self.strip),
              pmapPointer != kernelPmap, translate(pmapPointer) != nil,
              let tte = read64(virtual: pmapPointer), let ttep = read64(virtual: pmapPointer &+ 8),
              ttep & (Self.pageSize - 1) == 0, memory.contains(physical: ttep),
              translate(Self.strip(tte)) == ttep
        else { return nil }
        return ttep
    }

    /// The most a process may map: a process maps at most a little more than
    /// the guest has RAM (shared pages twice); twice that, or 4 GB on a small
    /// guest, is refused rather than written out.
    static func userBytesLimit(_ memory: VPhoneGuestPhysicalMemory) -> UInt64 {
        max(2 * memory.dram.size, 4 << 30)
    }

    /// The valid translations of a process's address space, in address
    /// order, up to `userBytesLimit`.
    func userMappings(root: UInt64) throws -> [Mapping] {
        var limits = VPhoneGuestPageTables.Limits()
        limits.bytes = Self.userBytesLimit(memory)
        return try VPhoneGuestPageTables(memory: memory, root: root).mappings(limits: limits)
    }

    // MARK: - Mach-O

    struct KernelImage {
        let uuid: String
        let segments: [Segment]
    }

    /// The kernel has about 15 segments; a header with more is not one.
    static let segmentLimit = 64

    /// The smallest valid length of the load commands that are read:
    /// `LC_SEGMENT_64`, `LC_UUID` and `LC_FILESET_ENTRY`. A shorter one is
    /// skipped, so no field is read past its command.
    static let minimumCommandLength: [UInt32: Int] = [0x19: 72, 0x1B: 24, 0x8000_0035: 32]

    /// The load commands of the Mach-O header at `header`, of which
    /// `available` bytes are mapped. Each lies wholly within the header's
    /// `sizeofcmds`, and that within `available`.
    static func loadCommands(_ header: UnsafeRawPointer, available: UInt64) -> [(UInt32, UnsafeRawPointer, Int)] {
        guard available >= 32 else { return [] }
        let count = Int(header.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        let size = Int(header.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
        // The real kernelcache has about 160 commands in 11 KB.
        guard count <= 4096, size <= 1 << 20, UInt64(32 + size) <= available else { return [] }
        var result: [(UInt32, UnsafeRawPointer, Int)] = []
        var cursor = 32
        for _ in 0 ..< count {
            guard cursor + 8 <= 32 + size else { break }
            let command = header.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            let length = Int(header.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
            guard length >= 8, cursor + length <= 32 + size else { break }
            if length >= minimumCommandLength[command] ?? 8 {
                result.append((command, header + cursor, length))
            }
            cursor += length
        }
        return result
    }

    /// The address of a fileset entry's Mach-O header (`LC_FILESET_ENTRY`'s
    /// `vmaddr`), slid like the rest of the in-memory header.
    static func filesetEntry(_ name: String, header: UnsafeRawPointer, available: UInt64) -> UInt64? {
        for (command, pointer, length) in loadCommands(header, available: available) where command == 0x8000_0035 {
            let nameOffset = Int(pointer.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
            guard nameOffset >= 32, nameOffset < length else { continue }
            let bytes = UnsafeRawBufferPointer(start: pointer + nameOffset, count: length - nameOffset)
            let entryName = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            if entryName == name {
                return pointer.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            }
        }
        return nil
    }

    /// The kernel's UUID and segments from its Mach-O header. A segment whose
    /// end would pass 2^64 is left out.
    static func image(_ header: UnsafeRawPointer, available: UInt64) -> KernelImage? {
        guard available >= 32, header.loadUnaligned(as: UInt32.self) == 0xFEED_FACF else { return nil }
        var segments: [Segment] = []
        var uuid: String?
        for (command, pointer, _) in loadCommands(header, available: available) {
            if command == 0x19 {  // LC_SEGMENT_64
                let bytes = UnsafeRawBufferPointer(start: pointer + 8, count: 16)
                let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                let address = pointer.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
                let size = pointer.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
                guard size > 0, !address.addingReportingOverflow(size).overflow else { continue }
                segments.append(Segment(name: name, address: address, size: size))
            } else if command == 0x1B {  // LC_UUID
                let bytes = (0 ..< 16).map { pointer.load(fromByteOffset: 8 + $0, as: UInt8.self) }
                uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                    .uuidString
            }
        }
        guard let uuid, !segments.isEmpty, segments.count <= segmentLimit else { return nil }
        return KernelImage(uuid: uuid, segments: segments)
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

    /// What a walk of one address space may produce. Guest page tables can
    /// point anywhere, themselves included; without these bounds a crafted
    /// tree yields billions of entries while the guest stays paused.
    struct Limits {
        /// Table pages read below the root, each at most once.
        var tables = 1 << 16
        /// Translations returned.
        var mappings = 1 << 21
        /// Bytes those translations cover.
        var bytes: UInt64 = 64 << 30
    }

    struct TooLarge: LocalizedError, CustomStringConvertible {
        let limits: Limits

        var errorDescription: String? {
            "The process's page tables describe more than \(limits.mappings) pages, "
                + "\(VPhoneMemoryDump.Failure.gigabytes(limits.bytes)) or \(limits.tables) tables; "
                + "nothing was saved."
        }

        var description: String { errorDescription ?? "address space too large" }
    }

    /// Every valid translation below 2^47, in address order; `entry` is the
    /// descriptor, for the permissions. A table that appears a second time in
    /// the tree is not walked again, and a tree beyond `limits` is refused.
    func mappings(limits: Limits = Limits()) throws -> [VPhoneGuestKernel.Mapping] {
        var result: [VPhoneGuestKernel.Mapping] = []
        var visited: Set<UInt64> = [root & Self.tableMask]
        var bytes: UInt64 = 0
        func add(_ mapping: VPhoneGuestKernel.Mapping) throws {
            bytes += mapping.size  // at most 2^36 each, with the count bounded
            guard result.count < limits.mappings, bytes <= limits.bytes else { throw TooLarge(limits: limits) }
            result.append(mapping)
        }
        func level(_ table: UInt64, shift: UInt64, base: UInt64) throws {
            guard let page = memory.pointer(physical: table, count: 2048 * 8) else { return }
            for index in UInt64(0) ..< 2048 {
                let entry = page.loadUnaligned(fromByteOffset: Int(index) * 8, as: UInt64.self)
                guard entry & 1 != 0 else { continue }
                let address = base | (index << shift)
                let span: UInt64 = 1 << shift
                if shift == 14 {
                    if entry & 2 != 0 {
                        try add(.init(virtual: address, physical: entry & Self.tableMask, size: span, entry: entry))
                    }
                } else if entry & 2 == 0 {
                    let physical = entry & Self.outputMask & ~(span - 1)
                    try add(.init(virtual: address, physical: physical, size: span, entry: entry))
                } else {
                    let next = entry & Self.tableMask
                    guard visited.insert(next).inserted else { continue }
                    guard visited.count <= limits.tables + 1 else { throw TooLarge(limits: limits) }
                    try level(next, shift: shift - 11, base: address)
                }
            }
        }
        try level(root & Self.tableMask, shift: 36, base: 0)
        return result
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
