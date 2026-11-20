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
        for region in [dram] + (carveOut.map { [$0] } ?? []) {
            let start = region.guestAddress
            if address >= start, address - start + UInt64(count) <= region.size {
                return region.base + Int(address - start)
            }
        }
        return nil
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

    /// A property of the flattened Apple device tree in guest memory: a
    /// 32-byte name, a 32-bit length, then the value. Only 8-byte values.
    static func deviceTreeValue(_ name: String, in base: UnsafeRawPointer, size: UInt64) -> UInt64? {
        let limit = Int(min(size, deviceTreeSearchLimit))
        for offset in occurrences(of: Array(name.utf8) + [0], in: base, count: limit) where offset % 4 == 0 {
            guard offset + 44 <= limit else { continue }
            let length = (base + offset + 32).loadUnaligned(as: UInt32.self) & 0x7FFF_FFFF
            if length == 8 {
                return (base + offset + 36).loadUnaligned(as: UInt64.self)
            }
        }
        return nil
    }

    /// The device tree's `region-id-N` properties: (base, size) of each
    /// firmware carve-out.
    static func deviceTreeCarveOuts(in base: UnsafeRawPointer, size: UInt64) -> [(base: UInt64, size: UInt64)] {
        let limit = Int(min(size, deviceTreeSearchLimit))
        var result: [(UInt64, UInt64)] = []
        for offset in occurrences(of: Array("region-id-".utf8), in: base, count: limit) where offset % 4 == 0 {
            guard offset + 52 <= limit else { continue }
            let name = UnsafeRawBufferPointer(start: base + offset, count: 32)
            guard let end = name.firstIndex(of: 0), name[10 ..< end].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  end > 10
            else { continue }
            let length = (base + offset + 32).loadUnaligned(as: UInt32.self) & 0x7FFF_FFFF
            if length == 16 {
                let pair = ((base + offset + 36).loadUnaligned(as: UInt64.self),
                            (base + offset + 44).loadUnaligned(as: UInt64.self))
                if !result.contains(where: { $0 == pair }) { result.append(pair) }
            }
        }
        return result
    }

    private static func occurrences(of needle: [UInt8], in base: UnsafeRawPointer, count: Int) -> [Int] {
        var result: [Int] = []
        var offset = 0
        needle.withUnsafeBytes { pattern in
            while offset < count,
                  let hit = memmem(base + offset, count - offset, pattern.baseAddress, pattern.count)
            {
                result.append(base.distance(to: UnsafeRawPointer(hit)))
                offset = result.last! + 1
            }
        }
        return result
    }
}
