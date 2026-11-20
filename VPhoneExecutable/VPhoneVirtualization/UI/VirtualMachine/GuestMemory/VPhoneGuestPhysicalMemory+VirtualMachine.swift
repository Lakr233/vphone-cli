import Darwin
import Foundation
import ObjectiveC
import Virtualization

// MARK: - Mapping a VM's Memory

extension VPhoneGuestPhysicalMemory {
    /// Maps the guest memory of `virtualMachine`. Call on the main actor, where
    /// the VM lives; the result may be used from any thread. The mapping ends
    /// when the result is released.
    @MainActor
    static func map(_ virtualMachine: VZVirtualMachine) throws -> VPhoneGuestPhysicalMemory {
        guard let pid = serviceProcessIdentifier(virtualMachine), pid > 0 else {
            throw Failure.serviceUnknown
        }
        return try map(servicePID: pid)
    }

    /// Maps the guest memory held by the Virtualization service process `pid`.
    static func map(servicePID pid: pid_t) throws -> VPhoneGuestPhysicalMemory {
        var task: mach_port_t = 0
        let status = task_for_pid(mach_task_self_, pid, &task)
        guard status == KERN_SUCCESS else { throw Failure.taskPort(status) }
        var keepsTask = false
        defer {
            if !keepsTask { mach_port_deallocate(mach_task_self_, task) }
        }

        let regions = guestRegions(task: task)
        guard let largest = regions.max(by: { $0.size < $1.size }) else { throw Failure.noGuestMemory }

        var mapped: [(mach_vm_address_t, mach_vm_size_t)] = []
        func remap(_ source: mach_vm_address_t, _ size: mach_vm_size_t) throws -> UnsafeRawPointer {
            var target: mach_vm_address_t = 0
            var current: vm_prot_t = 0
            var maximum: vm_prot_t = 0
            let status = mach_vm_remap(
                mach_task_self_, &target, size, 0, VM_FLAGS_ANYWHERE, task, source, 0,
                &current, &maximum, VM_INHERIT_NONE,
            )
            guard status == KERN_SUCCESS else { throw Failure.remap(status) }
            mapped.append((target, size))
            // A view, never a way to change the guest.
            mach_vm_protect(mach_task_self_, target, size, 0, VM_PROT_READ)
            return UnsafeRawPointer(bitPattern: UInt(target))!
        }
        do {
            let dramBase = try remap(largest.address, largest.size)
            guard let base = deviceTreeValue("dram-base", in: dramBase, size: largest.size) else {
                throw Failure.dramBaseUnknown
            }
            let dram = Region(guestAddress: base, size: largest.size, base: dramBase, serviceAddress: largest.address)

            // The carve-out block sits directly below DRAM: accept a region as
            // it only if every device-tree carve-out below DRAM falls inside.
            let carveOuts = deviceTreeCarveOuts(in: dramBase, size: largest.size).filter { $0.base < base }
            var found: Region?
            if !carveOuts.isEmpty {
                for region in regions where region.address != largest.address && region.size < base {
                    let low = base - region.size
                    if carveOuts.allSatisfy({ low <= $0.base && $0.base + $0.size <= base }) {
                        found = try Region(
                            guestAddress: low,
                            size: region.size,
                            base: remap(region.address, region.size),
                            serviceAddress: region.address,
                        )
                        break
                    }
                }
            }
            keepsTask = true
            return VPhoneGuestPhysicalMemory(dram: dram, carveOut: found, mappings: mapped, task: task)
        } catch {
            for (address, size) in mapped {
                mach_vm_deallocate(mach_task_self_, address, size)
            }
            throw error
        }
    }

    /// The pid of the Virtualization service process that runs the VM.
    /// `_serviceProcessIdentifier` returns an `int`, which `perform` cannot
    /// carry; call its implementation instead.
    @MainActor
    private static func serviceProcessIdentifier(_ virtualMachine: VZVirtualMachine) -> Int32? {
        typealias Function = @convention(c) (AnyObject, Selector) -> Int32
        let selector = NSSelectorFromString("_serviceProcessIdentifier")
        guard let method = class_getInstanceMethod(type(of: virtualMachine), selector) else { return nil }
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        return function(virtualMachine, selector)
    }
}
