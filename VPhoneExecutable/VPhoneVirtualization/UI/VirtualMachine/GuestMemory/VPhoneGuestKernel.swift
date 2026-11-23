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
    let kernelPmap: UInt64
    /// The offsets `processes()` found, once it has run.
    private(set) var layout: Layout?
    private let imageLow: UInt64
    private let imageHigh: UInt64

    static let pageSize: UInt64 = 0x4000
    /// More processes than iOS allows; a longer list is not followed.
    static let processLimit = 20000
    private static let tableMask: UInt64 = 0x0000_FFFF_FFFF_C000

    init(memory: VPhoneGuestPhysicalMemory, symbolsRoot: URL? = VPhoneKernelSymbols.recipesDirectory) throws {
        self.memory = memory
        let (candidates, unknownUUID) = Self.findKernels(memory, symbolsRoot: symbolsRoot)
        guard !candidates.isEmpty else {
            if symbolsRoot == nil { throw VPhoneKernelSymbols.Failure.noRecipes }
            if let unknownUUID { throw VPhoneKernelSymbols.Failure.unknownKernel(unknownUUID) }
            throw Failure.noKernelcache
        }

        // Every candidate is checked against one list of possible root tables,
        // taken in a single pass over DRAM, so a copied header costs a few
        // thousand table lookups rather than a pass of its own.
        var firstError: Error?
        let checks = candidates.compactMap { kernelcache, kernel -> Candidate? in
            do {
                return try Candidate(kernelcache: kernelcache, kernel: kernel)
            } catch {
                firstError = firstError ?? error
                return nil
            }
        }
        let roots = Self.possibleRoots(memory, indexes: Set(checks.map(\.rootIndex)))
        var found: Resolved?
        search: for candidate in checks {
            var rootFound = false
            for root in roots[candidate.rootIndex] ?? [] where candidate.translates(through: root, memory) {
                rootFound = true
                do {
                    found = try Self.resolve(memory, candidate, root: root, symbolsRoot: symbolsRoot)
                    break search
                } catch {
                    firstError = firstError ?? error
                }
            }
            if !rootFound { firstError = firstError ?? Failure.noPageTables }
        }
        guard let found else { throw firstError ?? Failure.noKernelcache }
        kernelcachePhysical = found.kernelcache
        kernelUUID = found.kernel.uuid
        segments = found.kernel.segments
        root = found.root
        symbols = found.symbols
        kernelPmap = found.pmap
        imageLow = segments.map(\.address).min() ?? 0
        imageHigh = segments.map { $0.address &+ $0.size }.max() ?? 0
    }

    private struct Resolved {
        let kernelcache: UInt64
        let kernel: KernelImage
        let root: UInt64
        let symbols: VPhoneKernelSymbols
        let pmap: UInt64
    }

    /// A kernelcache header and the translations its kernel implies:
    /// `__TEXT` and `__DATA_CONST` are where the file put them, so three
    /// virtual addresses of each must translate to the header's physical
    /// address plus their file offsets.
    private struct Candidate {
        let kernelcache: UInt64
        let kernel: KernelImage
        let known: [(virtual: UInt64, physical: UInt64)]

        init(kernelcache: UInt64, kernel: KernelImage) throws {
            var known: [(UInt64, UInt64)] = []
            for name in ["__TEXT", "__DATA_CONST"] {
                guard let segment = kernel.segments.first(where: { $0.name == name }),
                      segment.size >= VPhoneGuestKernel.pageSize
                else { throw Failure.unexpected("the kernel has no \(name)") }
                let page = VPhoneGuestKernel.pageSize
                for offset in [0, (segment.size / 2) & ~(page - 1), segment.size - page] {
                    known.append((segment.address &+ offset, kernelcache &+ segment.fileOffset &+ offset))
                }
            }
            self.kernelcache = kernelcache
            self.kernel = kernel
            self.known = known
        }

        /// The root-table entry the first address uses.
        var rootIndex: Int { Int((known[0].virtual >> 36) & 0x7FF) }

        func translates(through root: UInt64, _ memory: VPhoneGuestPhysicalMemory) -> Bool {
            let tables = VPhoneGuestPageTables(memory: memory, root: root)
            return known.allSatisfy { tables.translate($0.virtual) == $0.physical }
        }
    }

    /// Checks the rest of a candidate whose segments translate through
    /// `root`: its symbol map and `kernel_pmap` must agree with that root.
    private static func resolve(
        _ memory: VPhoneGuestPhysicalMemory,
        _ candidate: Candidate,
        root: UInt64,
        symbolsRoot: URL?,
    ) throws -> Resolved {
        let tables = VPhoneGuestPageTables(memory: memory, root: root)
        func read64(_ address: UInt64) -> UInt64? {
            tables.translate(address).flatMap { memory.read64(physical: $0) }
        }
        let kernel = candidate.kernel
        let symbols = try VPhoneKernelSymbols.load(kernelUUID: kernel.uuid, root: symbolsRoot)
        let (segmentName, offset) = try symbols.location(of: "_kernel_pmap")
        guard let segment = kernel.segments.first(where: { $0.name == segmentName }) else {
            throw Failure.unexpected("the kernel has no \(segmentName)")
        }
        guard let pointer = read64(segment.address &+ offset) else {
            throw Failure.unexpected("kernel_pmap is not mapped")
        }
        let pmap = strip(pointer)
        guard let tte = read64(pmap), let ttep = read64(pmap &+ 8),
              ttep == root, tables.translate(strip(tte)) == ttep
        else { throw Failure.unexpected("kernel_pmap does not hold the kernel's page tables") }
        return Resolved(
            kernelcache: candidate.kernelcache, kernel: kernel, root: root, symbols: symbols, pmap: pmap,
        )
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

    /// The valid translations of a process's address space, in address order.
    /// A process maps at most a little more than the guest has RAM (shared
    /// pages twice); twice that is refused rather than written out.
    func userMappings(root: UInt64) throws -> [Mapping] {
        var limits = VPhoneGuestPageTables.Limits()
        limits.bytes = max(2 * memory.dram.size, 4 << 30)
        return try VPhoneGuestPageTables(memory: memory, root: root).mappings(limits: limits)
    }

    // MARK: - Locating

    struct KernelImage {
        let uuid: String
        let segments: [Segment]
    }

    /// Kernelcache headers in DRAM whose kernel has a symbol map, lowest
    /// first, each with the kernel inside it, and the UUID of the first header
    /// without a map. Any process can write such a header into its own pages,
    /// and the kernel hands out memory below the kernelcache too (see
    /// Research/Host/process_memory_dump.md), so copies may come first. One
    /// with an unknown UUID costs nothing here; the caller checks the others
    /// cheaply against one list of possible root tables and takes the first
    /// whose page tables and `kernel_pmap` agree.
    /// More headers than fit below the kernelcache on these guests (about
    /// 58 MB into DRAM, 3,700 pages), so copies there cannot use up the
    /// limit before the real one is reached.
    static let kernelCandidateLimit = 16384
    /// The kernel has about 15 segments; a header with more is not one.
    static let segmentLimit = 64

    static func findKernels(
        _ memory: VPhoneGuestPhysicalMemory,
        symbolsRoot: URL?,
    ) -> (candidates: [(UInt64, KernelImage)], unknownUUID: String?) {
        let dram = memory.dram
        var result: [(UInt64, KernelImage)] = []
        var unknownUUID: String?
        var offset: UInt64 = 0
        while offset + pageSize <= dram.size, result.count < kernelCandidateLimit {
            let header = dram.base + Int(offset)
            if header.loadUnaligned(as: UInt32.self) == 0xFEED_FACF,
               header.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 0x0100_000C,
               header.loadUnaligned(fromByteOffset: 12, as: UInt32.self) == 0xC,  // MH_FILESET
               let entry = filesetEntry("com.apple.kernel", header: header, available: dram.size - offset),
               entry < dram.size - offset,
               let kernel = image(header + Int(entry), available: dram.size - offset - entry)
            {
                if VPhoneKernelSymbols.hasMap(kernelUUID: kernel.uuid, root: symbolsRoot) {
                    result.append((dram.guestAddress + offset, kernel))
                } else {
                    unknownUUID = unknownUUID ?? kernel.uuid
                }
            }
            offset += pageSize
        }
        return (result, unknownUUID)
    }

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

    /// The file offset of a fileset entry (`LC_FILESET_ENTRY`).
    static func filesetEntry(_ name: String, header: UnsafeRawPointer, available: UInt64) -> UInt64? {
        for (command, pointer, length) in loadCommands(header, available: available) where command == 0x8000_0035 {
            let nameOffset = Int(pointer.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
            guard nameOffset >= 32, nameOffset < length else { continue }
            let bytes = UnsafeRawBufferPointer(start: pointer + nameOffset, count: length - nameOffset)
            let entryName = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            if entryName == name {
                return pointer.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
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
                let fileOffset = pointer.loadUnaligned(fromByteOffset: 40, as: UInt64.self)
                guard size > 0, !address.addingReportingOverflow(size).overflow,
                      !fileOffset.addingReportingOverflow(size).overflow
                else { continue }
                segments.append(Segment(name: name, address: address, size: size, fileOffset: fileOffset))
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

    /// For each root-table index in `indexes`, the DRAM pages, lowest first,
    /// whose entry at that index is a table descriptor into DRAM: the pages
    /// that could be the kernel's root table. One pass over DRAM; on a booted
    /// 27.2 guest about 2,800 of its 524,288 pages for the kernel's index.
    static func possibleRoots(_ memory: VPhoneGuestPhysicalMemory, indexes: Set<Int>) -> [Int: [UInt64]] {
        let sorted = indexes.sorted()
        var result: [Int: [UInt64]] = [:]
        let dram = memory.dram
        var offset: UInt64 = 0
        while offset + pageSize <= dram.size {
            let page = dram.base + Int(offset)
            for index in sorted {
                let entry = page.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)
                if entry & 3 == 3, memory.contains(physical: entry & tableMask) {
                    result[index, default: []].append(dram.guestAddress + offset)
                }
            }
            offset += pageSize
        }
        return result
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
