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
        case dramBaseUnknown

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
            case .dramBaseUnknown:
                "The guest's device tree does not give the physical address of its RAM."
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
    private let mappings: [(address: mach_vm_address_t, size: mach_vm_size_t)]
    /// The service's task port, for asking which pages exist; owned.
    private let task: mach_port_t

    init(
        dram: Region,
        carveOut: Region?,
        mappings: [(address: mach_vm_address_t, size: mach_vm_size_t)],
        task: mach_port_t = mach_port_t(MACH_PORT_NULL),
    ) {
        self.dram = dram
        self.carveOut = carveOut
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

    /// For each 16 KB page of `region`, whether the service has ever given it
    /// memory, resident or paged out. A page it never did reads as zeros, but
    /// reading it through the mapping would make the host allocate it. Nil
    /// when the service cannot be asked; then every page counts as used.
    func usedPages(of region: Region) -> [Bool]? {
        guard task != MACH_PORT_NULL, let address = region.serviceAddress else { return nil }
        let pages = Int(region.size / Self.pageSize)
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
    /// How many matches of a property name are looked at. Any app can write
    /// these patterns into its own pages; the real device tree has a few
    /// dozen carve-outs.
    static let deviceTreeMatchLimit = 4096

    /// A property of the flattened Apple device tree in guest memory: a
    /// 32-byte name, a 32-bit length, then the value. Only 8-byte values.
    static func deviceTreeValue(_ name: String, in base: UnsafeRawPointer, size: UInt64) -> UInt64? {
        let limit = Int(min(size, deviceTreeSearchLimit))
        var value: UInt64?
        forEachOccurrence(of: Array(name.utf8) + [0], in: base, count: limit) { offset in
            guard offset % 4 == 0, offset + 44 <= limit else { return true }
            let length = (base + offset + 32).loadUnaligned(as: UInt32.self) & 0x7FFF_FFFF
            guard length == 8 else { return true }
            value = (base + offset + 36).loadUnaligned(as: UInt64.self)
            return false
        }
        return value
    }

    struct CarveOut: Hashable {
        let base: UInt64
        let size: UInt64
    }

    /// The device tree's `region-id-N` properties: (base, size) of each
    /// firmware carve-out, without duplicates and without any whose end
    /// would pass 2^64.
    static func deviceTreeCarveOuts(in base: UnsafeRawPointer, size: UInt64) -> [CarveOut] {
        let limit = Int(min(size, deviceTreeSearchLimit))
        var result: [CarveOut] = []
        var seen: Set<CarveOut> = []
        forEachOccurrence(of: Array("region-id-".utf8), in: base, count: limit) { offset in
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
            return true
        }
        return result
    }

    /// Calls `body` with the offset of each match of `needle` in the first
    /// `count` bytes, at most `deviceTreeMatchLimit` times, until it returns
    /// false.
    private static func forEachOccurrence(
        of needle: [UInt8],
        in base: UnsafeRawPointer,
        count: Int,
        _ body: (Int) -> Bool,
    ) {
        var offset = 0
        var matches = 0
        needle.withUnsafeBytes { pattern in
            while offset < count, matches < deviceTreeMatchLimit,
                  let hit = memmem(base + offset, count - offset, pattern.baseAddress, pattern.count)
            {
                let found = base.distance(to: UnsafeRawPointer(hit))
                matches += 1
                guard body(found) else { return }
                offset = found + 1
            }
        }
    }
}