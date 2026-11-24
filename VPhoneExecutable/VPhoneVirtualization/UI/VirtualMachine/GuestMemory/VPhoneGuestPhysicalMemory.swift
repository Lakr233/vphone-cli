import Darwin
import Foundation

// MARK: - Guest Physical Memory

/// A read-only view of the guest's RAM, taken from the Virtualization
/// service process that runs the application processor.
///
/// Virtualization keeps guest memory in that process as `VM_MEMORY` tag 240
/// regions: one for DRAM and a small one for the firmware carve-outs below
/// it. This maps them into `vphone-vm` read-only with `mach_vm_remap`, without
/// a copy, so a read is a plain memory access. Getting the service's task port
/// needs `com.apple.security.cs.debugger`, which `vphone-vm` carries, on a Mac
/// whose SIP debugging restrictions are off, as vphone requires anyway.
///
/// The view is live: while the guest runs, its memory changes under it.
/// Callers that need one consistent state pause the VM first.
final class VPhoneGuestPhysicalMemory: @unchecked Sendable {
    struct Region: @unchecked Sendable {
        /// The guest physical address, when it is known.
        let guestAddress: UInt64
        let size: UInt64
        /// Where the region is mapped in this process.
        let base: UnsafeRawPointer
        /// Where the region is in the service process, when it came from one.
        var serviceAddress: mach_vm_address_t?
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case serviceUnknown
        case taskPort(kern_return_t)
        case noGuestMemory
        case remap(kern_return_t)
        case protect(kern_return_t)

        var errorDescription: String? {
            switch self {
            case .serviceUnknown:
                "Virtualization did not name the process that runs this VM."
            case let .taskPort(code):
                "vphone-vm cannot read the VM's memory (task_for_pid: \(code)). This needs SIP's debugging "
                    + "restrictions off, as described in Host Setup."
            case .noGuestMemory:
                "The VM's process holds no guest memory."
            case let .remap(code):
                "Unable to map the guest's memory (mach_vm_remap: \(code))."
            case let .protect(code):
                "Unable to make the view of the guest's memory read-only (mach_vm_protect: \(code))."
            }
        }

        var description: String { errorDescription ?? "guest memory unavailable" }
    }

    /// `VM_MEMORY` tag of the hypervisor-mapped guest memory in the service.
    static let guestMemoryTag: UInt32 = 240
    static let pageSize: UInt64 = 0x4000

    let dram: Region
    /// The firmware carve-out block directly below DRAM, if one was found.
    let carveOut: Region?
    /// The DRAM bases `placed(kernel:)` tries, in order: `usualDRAMBase`,
    /// then every other `dram-base` value found in guest RAM. Apps get pages
    /// below the device tree and can write the property there, so a value
    /// found need not be the device tree's; only the kernel's registers
    /// tell.
    let dramBases: [UInt64]
    /// Every `dram-base` value found in guest RAM, in the order found and
    /// without repeats (at most `deviceTreeMatchLimit`).
    let dramCandidates: [UInt64]
    /// The host mappings and the task port, shared by every placement.
    private let owner: Owner
    /// The device tree's carve-outs and the service's other guest memory
    /// regions, to find the carve-out block below another DRAM base.
    private let carveOutSources: (carveOuts: [CarveOut], regions: [Region])

    init(
        dram: Region,
        carveOut: Region?,
        mappings: [(address: mach_vm_address_t, size: mach_vm_size_t)],
        task: mach_port_t = mach_port_t(MACH_PORT_NULL),
        dramBases: [UInt64]? = nil,
        dramCandidates: [UInt64]? = nil,
        carveOuts: [CarveOut] = [],
        otherRegions: [Region] = [],
    ) {
        self.dram = dram
        self.carveOut = carveOut
        self.dramBases = dramBases ?? [dram.guestAddress]
        self.dramCandidates = dramCandidates ?? [dram.guestAddress]
        owner = Owner(mappings: mappings, task: task)
        carveOutSources = (carveOuts, otherRegions)
    }

    private init(placing other: VPhoneGuestPhysicalMemory, at base: UInt64) {
        let sources = other.carveOutSources
        dram = Region(
            guestAddress: base, size: other.dram.size, base: other.dram.base, serviceAddress: other.dram.serviceAddress,
        )
        carveOut = Self.carveOut(below: base, carveOuts: sources.carveOuts, regions: sources.regions)
        dramBases = other.dramBases
        dramCandidates = other.dramCandidates
        owner = other.owner
        carveOutSources = sources
    }

    /// Owns what the view is made of; the placements of one view share it.
    private final class Owner {
        let mappings: [(address: mach_vm_address_t, size: mach_vm_size_t)]
        /// The service's task port, for asking which pages exist; owned.
        let task: mach_port_t

        init(mappings: [(address: mach_vm_address_t, size: mach_vm_size_t)], task: mach_port_t) {
            self.mappings = mappings
            self.task = task
        }

        deinit {
            for (address, size) in mappings {
                mach_vm_deallocate(mach_task_self_, address, size)
            }
            if task != MACH_PORT_NULL {
                mach_port_deallocate(mach_task_self_, task)
            }
        }
    }

    /// For each 16 KB page of `region`, whether the service has ever given it
    /// memory, resident or paged out. A page it never did reads as zeros, but
    /// reading it through the mapping would make the host allocate it. Nil
    /// when the service cannot be asked; then every page counts as used.
    func usedPages(of region: Region) -> [Bool]? {
        Self.usedPages(task: owner.task, address: region.serviceAddress, size: region.size)
    }

    static func usedPages(task: mach_port_t, address: mach_vm_address_t?, size: UInt64) -> [Bool]? {
        guard task != MACH_PORT_NULL, let address else { return nil }
        let pages = Int(size / Self.pageSize)
        var dispositions = [Int32](repeating: 0, count: pages)
        let chunk = 65536
        var done = 0
        while done < pages {
            let count = min(chunk, pages - done)
            var returned = mach_vm_size_t(count)
            let status = dispositions.withUnsafeMutableBufferPointer { buffer in
                mach_vm_page_range_query(
                    task,
                    address + mach_vm_address_t(done) * Self.pageSize,
                    mach_vm_size_t(count) * Self.pageSize,
                    mach_vm_address_t(UInt(bitPattern: buffer.baseAddress! + done)),
                    &returned,
                )
            }
            guard status == KERN_SUCCESS, returned == mach_vm_size_t(count) else { return nil }
            done += count
        }
        return dispositions.map { $0 != 0 }
    }

    /// Byte ranges of a region made of used pages; the whole region when
    /// that is unknown.
    static func usedRuns(_ used: [Bool]?, size: UInt64) -> [Range<UInt64>] {
        guard let used else { return [0 ..< size] }
        var runs: [Range<UInt64>] = []
        var start: Int?
        for (index, isUsed) in used.enumerated() {
            if isUsed, start == nil { start = index }
            if !isUsed, let first = start {
                runs.append(UInt64(first) * pageSize ..< UInt64(index) * pageSize)
                start = nil
            }
        }
        if let first = start { runs.append(UInt64(first) * pageSize ..< min(UInt64(used.count) * pageSize, size)) }
        return runs
    }

    // MARK: - Placing DRAM

    /// Where Virtualization has put DRAM on every guest so far (iOS 18.6,
    /// 26.5 and 27.2, 8 GB each), right above its 10 MB of firmware
    /// carve-outs. Tried first, so values an app plants in its pages do not
    /// decide whether the device tree's is reached; still taken only when
    /// the kernel's registers agree.
    static let usualDRAMBase: UInt64 = 0x70A0_0000

    /// The bases to try with the kernel's registers, and the one to use
    /// without them: `usualDRAMBase` when the device tree search found it,
    /// found nothing, or stopped at `deviceTreeMatchLimit` (then values were
    /// planted, and the device tree's may not have been reached), else the
    /// first value found.
    static func dramBases(found: [UInt64]) -> (tried: [UInt64], unverified: UInt64) {
        let tried = [usualDRAMBase] + found.filter { $0 != usualDRAMBase }
        let usual = found.isEmpty || found.count >= deviceTreeMatchLimit || found.contains(usualDRAMBase)
        return (tried, usual ? usualDRAMBase : found[0])
    }

    /// This view with DRAM at the first of `dramBases` that the kernel's
    /// registers agree with: the root table (`TTBR1_EL1`) lies in DRAM and
    /// the exception vectors (`VBAR_EL1`) translate through it into DRAM. An
    /// app can write a `dram-base` property but does not know where the
    /// kernel's tables are, so a wrong base fails this. Nil when none agrees.
    func placed(kernel registers: VPhoneGuestDebugStub.KernelRegisters) -> VPhoneGuestPhysicalMemory? {
        for base in dramBases {
            let memory = base == dram.guestAddress ? self : VPhoneGuestPhysicalMemory(placing: self, at: base)
            guard memory.contains(physical: registers.root),
                  let vectors = VPhoneGuestPageTables(memory: memory, root: registers.root).translate(registers.vbar),
                  memory.contains(physical: vectors)
            else { continue }
            return memory
        }
        return nil
    }

    /// The service region directly below `base` that holds every carve-out
    /// the device tree places below it.
    static func carveOut(below base: UInt64, carveOuts: [CarveOut], regions: [Region]) -> Region? {
        let below = carveOuts.filter { $0.base < base }
        guard !below.isEmpty else { return nil }
        for region in regions where region.size < base {
            let low = base - region.size
            // Written without a sum of guest values.
            if below.allSatisfy({ low <= $0.base && $0.size <= base - $0.base }) {
                return Region(guestAddress: low, size: region.size, base: region.base, serviceAddress: region.serviceAddress)
            }
        }
        return nil
    }

    // MARK: - Reading

    /// A pointer to `count` bytes at a guest physical address, or nil when
    /// they are not all in one mapped region.
    func pointer(physical address: UInt64, count: Int = 8) -> UnsafeRawPointer? {
        guard count >= 0 else { return nil }
        return Self.pointer(address, count: UInt64(count), in: dram)
            ?? carveOut.flatMap { Self.pointer(address, count: UInt64(count), in: $0) }
    }

    /// No sum of guest values: an address near 2^64 must not trap.
    private static func pointer(_ address: UInt64, count: UInt64, in region: Region) -> UnsafeRawPointer? {
        guard address >= region.guestAddress else { return nil }
        let offset = address - region.guestAddress
        guard offset <= region.size, count <= region.size - offset else { return nil }
        return region.base + Int(offset)
    }

    func read64(physical address: UInt64) -> UInt64? {
        pointer(physical: address, count: 8)?.loadUnaligned(as: UInt64.self)
    }

    func contains(physical address: UInt64) -> Bool {
        address >= dram.guestAddress && address - dram.guestAddress < dram.size
    }

    // MARK: - Regions

    struct HostRegion {
        let address: mach_vm_address_t
        let size: mach_vm_size_t
    }

    /// The service's guest memory, with adjacent regions of one mapping joined:
    /// DRAM is one hypervisor mapping split into many VM entries.
    static func guestRegions(task: mach_port_t) -> [HostRegion] {
        var regions: [(address: mach_vm_address_t, size: mach_vm_size_t, protection: vm_prot_t)] = []
        var address: mach_vm_address_t = 0
        while true {
            var size: mach_vm_size_t = 0
            var depth: natural_t = 64
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size,
            )
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(task, &address, &size, &depth, $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { break }
            if info.user_tag == guestMemoryTag {
                if let last = regions.last, last.address + last.size == address, last.protection == info.protection {
                    regions[regions.count - 1].size += size
                } else {
                    regions.append((address, size, info.protection))
                }
            }
            address += size
        }
        return regions.map { HostRegion(address: $0.address, size: $0.size) }
    }

    // MARK: - Device Tree

    /// Where the device tree sits, among the first pages of DRAM.
    private static let deviceTreeSearchLimit: UInt64 = 512 << 20
    /// How many distinct values of a property are kept. Any app can write
    /// these patterns into its own pages; the real device tree has one
    /// `dram-base` and a few dozen carve-outs. Only well-formed properties
    /// with a new value count, so stray matches cannot use the limit up;
    /// planted well-formed ones still can, which is why `usualDRAMBase` is
    /// tried first and every base is checked against the kernel's registers.
    static let deviceTreeMatchLimit = 4096

    /// The values of a property of the flattened Apple device tree in guest
    /// memory, in the order found and without repeats: a 32-byte name, a
    /// 32-bit length, then the value. Only 8-byte values that `accept`
    /// takes, at most `deviceTreeMatchLimit`. Only the byte ranges in
    /// `runs` are searched.
    static func deviceTreeValues(
        _ name: String,
        in base: UnsafeRawPointer,
        size: UInt64,
        runs: [Range<UInt64>]? = nil,
        accept: (UInt64) -> Bool = { _ in true },
    ) -> [UInt64] {
        let limit = Int(min(size, deviceTreeSearchLimit))
        var values: [UInt64] = []
        var seen: Set<UInt64> = []
        forEachOccurrence(of: Array(name.utf8) + [0], in: base, count: limit, runs: runs) { offset in
            guard offset % 4 == 0, offset + 44 <= limit else { return true }
            let length = (base + offset + 32).loadUnaligned(as: UInt32.self) & 0x7FFF_FFFF
            guard length == 8 else { return true }
            let value = (base + offset + 36).loadUnaligned(as: UInt64.self)
            if accept(value), seen.insert(value).inserted { values.append(value) }
            return values.count < deviceTreeMatchLimit
        }
        return values
    }

    struct CarveOut: Hashable {
        let base: UInt64
        let size: UInt64
    }

    /// The device tree's `region-id-N` properties: (base, size) of each
    /// firmware carve-out, without duplicates and without any whose end
    /// would pass 2^64. Only the byte ranges in `runs` are searched.
    static func deviceTreeCarveOuts(in base: UnsafeRawPointer, size: UInt64, runs: [Range<UInt64>]? = nil) -> [CarveOut] {
        let limit = Int(min(size, deviceTreeSearchLimit))
        var result: [CarveOut] = []
        var seen: Set<CarveOut> = []
        forEachOccurrence(of: Array("region-id-".utf8), in: base, count: limit, runs: runs) { offset in
            guard offset % 4 == 0, offset + 52 <= limit else { return true }
            let name = UnsafeRawBufferPointer(start: base + offset, count: 32)
            guard let end = name.firstIndex(of: 0), end > 10,
                  name[10 ..< end].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
            else { return true }
            let length = (base + offset + 32).loadUnaligned(as: UInt32.self) & 0x7FFF_FFFF
            guard length == 16 else { return true }
            let carveOut = CarveOut(
                base: (base + offset + 36).loadUnaligned(as: UInt64.self),
                size: (base + offset + 44).loadUnaligned(as: UInt64.self),
            )
            if !carveOut.base.addingReportingOverflow(carveOut.size).overflow, seen.insert(carveOut).inserted {
                result.append(carveOut)
            }
            return result.count < deviceTreeMatchLimit
        }
        return result
    }

    /// Calls `body` with the offset of each match of `needle` in the first
    /// `count` bytes, within `runs` (all of them when nil), until it returns
    /// false. Pages outside `runs` are never read, so the host does not
    /// allocate them. The search is bounded by `count`, not by the number of
    /// matches: a match costs a few comparisons, and the device tree must
    /// not be hidden behind any number of stray ones.
    private static func forEachOccurrence(
        of needle: [UInt8],
        in base: UnsafeRawPointer,
        count: Int,
        runs: [Range<UInt64>]?,
        _ body: (Int) -> Bool,
    ) {
        needle.withUnsafeBytes { pattern in
            for run in runs ?? [0 ..< UInt64(count)] {
                // A run may end inside a match; the device tree is in used
                // pages, so it is whole within one run.
                var offset = Int(min(run.lowerBound, UInt64(count)))
                let end = Int(min(run.upperBound, UInt64(count)))
                while offset < end,
                      let hit = memmem(base + offset, end - offset, pattern.baseAddress, pattern.count)
                {
                    let found = base.distance(to: UnsafeRawPointer(hit))
                    guard body(found) else { return }
                    offset = found + 1
                }
            }
        }
    }
}
