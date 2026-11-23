import Foundation

// MARK: - Guest Threads

/// Reads guest kernel memory by kernel virtual address.
protocol VPhoneKernelMemory {
    func read64(virtual address: UInt64) -> UInt64?
    func read32(virtual address: UInt64) -> UInt32?
}

extension VPhoneGuestKernel: VPhoneKernelMemory {}

/// The threads of a guest process and the user registers the kernel saved
/// for each, read from guest memory alone.
///
/// - The task follows the proc in one allocation; its `threads` queue holds
///   the process's threads. XNU links them with its classic queue macros: the
///   head and each thread's `task_threads` link point to the next *thread*,
///   and the last link points back to the head.
/// - Each user thread points to the registers the kernel saved when the
///   thread last entered the kernel (`machine.contextData`/`upcb`), an
///   `arm_saved_state` whose header says `ARM_SAVED_STATE64`, and to its
///   NEON registers (`machine.uNeon`), headed `ARM_NEON_SAVED_STATE64`.
///
/// These four offsets are found on the running guest, by those properties,
/// as `VPhoneGuestKernel` finds `p_pid`. The thread ID, the user TSD pointer
/// (`TPIDRRO_EL0`) and the thread name are read where the kernel's own
/// `thread_tid`, `thread_dispatchqaddr` and `thread_has_thread_name` read
/// them, and are left out when what is there is not believable.
///
/// A thread that was executing user code on a vCPU when the guest was
/// paused has its registers in that vCPU, not in memory; in memory are
/// those of its last entry into the kernel. That is at most one thread per
/// vCPU, and `withLiveRegisters` gives it the vCPU's, read through
/// `VPhoneGuestDebugStub`. See Research/Host/process_memory_dump.md.
enum VPhoneGuestThreads {
    struct Layout: Sendable {
        /// proc → the task's thread queue head (`task->threads`).
        let list: UInt64
        /// thread → its link in that queue (`thread->task_threads`).
        let link: UInt64
        /// thread → its saved user registers (`machine.contextData`).
        let userState: UInt64
        /// thread → its saved NEON registers (`machine.uNeon`).
        let neonState: UInt64?
        /// thread → `thread_id`, from `thread_tid`.
        var id: UInt64?
        /// thread → the user TSD pointer, from `thread_dispatchqaddr`.
        var tsd: UInt64?
        /// thread → the name buffer pointer, from `thread_has_thread_name`.
        var name: UInt64?
        /// The reads of guest memory discovery took.
        var reads = 0
    }

    /// `arm_saved_state64`, as `ARM_THREAD_STATE64` and
    /// `ARM_EXCEPTION_STATE64` carry it.
    struct Registers: Sendable, Equatable {
        var x: [UInt64]
        var fp: UInt64
        var lr: UInt64
        var sp: UInt64
        var pc: UInt64
        var cpsr: UInt32
        var far: UInt64
        var esr: UInt32
    }

    struct Thread: Sendable {
        let address: UInt64
        var registers: Registers
        /// `ARM_NEON_STATE64`: v0–v31, then fpsr and fpcr, then padding:
        /// 66 little-endian words.
        var neon: [UInt64]?
        let id: UInt64?
        let tsd: UInt64?
        let name: String?
        /// For a thread that was running on a vCPU when the guest was
        /// paused: the registers the kernel had saved, which `registers`
        /// replaced with the vCPU's.
        var saved: Registers? = nil
    }

    /// `arm_state_hdr_t.flavor` of the kernel's saved-state records.
    static let savedStateFlavor: UInt32 = 21  // ARM_SAVED_STATE64
    static let neonStateFlavor: UInt32 = 23  // ARM_NEON_SAVED_STATE64
    /// The records' word counts must cover what is read: through `esr` at
    /// +0x120, and v0–v31, fpsr and fpcr.
    static let savedStateWords: ClosedRange<UInt32> = 72 ... 256
    static let neonStateWords: ClosedRange<UInt32> = 130 ... 256

    /// More threads than one iOS process may have; a longer queue is refused.
    static let threadLimit = 8192
    /// How far into a thread its link and register pointers are looked for.
    static let threadFieldLimit: UInt64 = 0x1000
    /// The threads of each sampled process that are checked for register
    /// pointers.
    static let sampleThreadLimit = 16
    /// Reads of guest memory discovery may make in all. Wrong offsets lead
    /// into whatever the kernel's memory holds, and the guest stays paused
    /// while they are tried; see Research/Host/process_memory_dump.md.
    static let discoveryReadLimit = 4_000_000

    /// Kernel memory that answers at most `limit` reads, then none.
    final class ReadBudget<Memory: VPhoneKernelMemory>: VPhoneKernelMemory {
        let memory: Memory
        private(set) var reads = 0
        let limit: Int

        init(_ memory: Memory, limit: Int) {
            self.memory = memory
            self.limit = limit
        }

        var exhausted: Bool { reads >= limit }

        func read64(virtual address: UInt64) -> UInt64? {
            guard !exhausted else { return nil }
            reads += 1
            return memory.read64(virtual: address)
        }

        func read32(virtual address: UInt64) -> UInt32? {
            guard !exhausted else { return nil }
            reads += 1
            return memory.read32(virtual: address)
        }
    }

    // MARK: Discovery

    /// Finds the thread queue and the saved-register pointers in `sample`,
    /// procs with an address space; `map` is where the proc points to its
    /// task's map, near the queue head. The first combination under which
    /// every sampled queue closes, at least half the sample has threads, and
    /// (nearly) every thread found points to a saved user state, is the one.
    /// Gives up after `readLimit` reads.
    static func discover(
        _ memory: some VPhoneKernelMemory, sample: [UInt64], map: UInt64, readLimit: Int = discoveryReadLimit,
    ) throws -> Layout {
        guard !sample.isEmpty else { throw VPhoneGuestKernel.Failure.unexpected("no process to find threads in") }
        let memory = ReadBudget(memory, limit: readLimit)
        let exhausted = VPhoneGuestKernel.Failure.unexpected(
            "no thread queue with saved registers within \(readLimit) reads of guest memory"
        )
        let window = stride(from: map >= 0x100 ? map - 0x100 : 0, to: map &+ 0x300, by: 8)
        for list in window {
            let heads = sample.map { $0 &+ list }
            for link in stride(from: UInt64(0), to: threadFieldLimit, by: 8) {
                guard !memory.exhausted else { throw exhausted }
                var threads: [UInt64] = []
                var populated = 0
                var closed = true
                for head in heads {
                    guard let ring = queue(memory, head: head, link: link) else {
                        closed = false
                        break
                    }
                    if !ring.isEmpty { populated += 1 }
                    threads += ring.prefix(sampleThreadLimit)
                }
                guard closed, populated * 2 >= sample.count, !threads.isEmpty else { continue }
                guard let userState = fieldOffset(memory, threads, flavor: savedStateFlavor, words: savedStateWords),
                      mostly(threads, { registers(memory, thread: $0, userState: userState) != nil })
                else { continue }
                let neonState = fieldOffset(memory, threads, flavor: neonStateFlavor, words: neonStateWords)
                // A read refused at the end would have decided nothing.
                guard !memory.exhausted else { throw exhausted }
                return Layout(list: list, link: link, userState: userState, neonState: neonState, reads: memory.reads)
            }
        }
        throw VPhoneGuestKernel.Failure.unexpected("no thread queue with saved registers")
    }

    /// The threads on the queue at `head`, in queue order; nil unless the
    /// queue closes within `threadLimit` without repeating a thread.
    static func queue(_ memory: some VPhoneKernelMemory, head: UInt64, link: UInt64) -> [UInt64]? {
        guard var next = memory.read64(virtual: head).map(VPhoneGuestKernel.strip) else { return nil }
        var threads: [UInt64] = []
        var seen: Set<UInt64> = []
        while next != head {
            guard threads.count < threadLimit, isKernelPointer(next), seen.insert(next).inserted,
                  let following = memory.read64(virtual: next &+ link).map(VPhoneGuestKernel.strip)
            else { return nil }
            threads.append(next)
            next = following
        }
        return threads
    }

    /// Whether all but at most one in ten of `items` satisfy `test`: a thread
    /// being created or torn down while the guest was paused may not. Stops
    /// at the first failure too many.
    static func mostly(_ items: [UInt64], _ test: (UInt64) -> Bool) -> Bool {
        let allowed = items.count / 10
        var failed = 0
        for item in items where !test(item) {
            failed += 1
            if failed > allowed { return false }
        }
        return failed < items.count
    }

    /// The first offset below `threadFieldLimit` at which (nearly) every thread points
    /// to a 16-byte-aligned record headed by `flavor` and a count in `words`.
    static func fieldOffset(
        _ memory: some VPhoneKernelMemory, _ threads: [UInt64], flavor: UInt32, words: ClosedRange<UInt32>,
    ) -> UInt64? {
        stride(from: UInt64(0), to: threadFieldLimit, by: 8).first { offset in
            mostly(threads) { record(memory, thread: $0, at: offset, flavor: flavor, words: words) != nil }
        }
    }

    /// The record a thread points to at `offset`, past its 8-byte header.
    static func record(
        _ memory: some VPhoneKernelMemory, thread: UInt64, at offset: UInt64, flavor: UInt32, words: ClosedRange<UInt32>,
    ) -> UInt64? {
        guard let pointer = memory.read64(virtual: thread &+ offset).map(VPhoneGuestKernel.strip),
              isKernelPointer(pointer), pointer & 0xF == 0,
              memory.read32(virtual: pointer) == flavor,
              let count = memory.read32(virtual: pointer &+ 4), words.contains(count)
        else { return nil }
        return pointer
    }

    static func isKernelPointer(_ value: UInt64) -> Bool { value >> 47 == 0x1FFFF }

    // MARK: Reading

    /// A thread's saved user registers; nil unless they are a user state
    /// (AArch64, EL0).
    static func registers(_ memory: some VPhoneKernelMemory, thread: UInt64, userState: UInt64) -> Registers? {
        guard let state = record(memory, thread: thread, at: userState, flavor: savedStateFlavor, words: savedStateWords)
        else { return nil }
        var words: [UInt64] = []
        for index in 0 ..< 36 {  // x0–x28, fp, lr, sp, pc, cpsr, far, esr
            guard let word = memory.read64(virtual: state &+ 8 &+ UInt64(index * 8)) else { return nil }
            words.append(word)
        }
        let cpsr = UInt32(truncatingIfNeeded: words[33])
        guard cpsr & 0x1F == 0 else { return nil }  // M[4:0]: AArch64 EL0t
        return Registers(
            x: Array(words[0 ..< 29]), fp: words[29], lr: words[30], sp: words[31], pc: words[32],
            cpsr: cpsr, far: words[34], esr: UInt32(truncatingIfNeeded: words[35]),
        )
    }

    /// v0–v31 from 16 bytes into the record, then fpsr and fpcr, then the
    /// padding `ARM_NEON_STATE64` has.
    static func neon(_ memory: some VPhoneKernelMemory, thread: UInt64, neonState: UInt64) -> [UInt64]? {
        guard let state = record(memory, thread: thread, at: neonState, flavor: neonStateFlavor, words: neonStateWords)
        else { return nil }
        var words: [UInt64] = []
        for index in 0 ..< 65 {
            guard let word = memory.read64(virtual: state &+ 16 &+ UInt64(index * 8)) else { return nil }
            words.append(word)
        }
        return words + [0]
    }

    /// The process's threads, in queue order (oldest first). A thread whose
    /// registers are not a user state (one being created or torn down) is
    /// counted in `skipped` and left out.
    static func threads(
        _ memory: some VPhoneKernelMemory, process: UInt64, layout: Layout,
    ) throws -> (threads: [Thread], skipped: Int) {
        guard let list = queue(memory, head: process &+ layout.list, link: layout.link) else {
            throw VPhoneGuestKernel.Failure.unexpected("the process's thread queue does not close")
        }
        var threads: [Thread] = []
        for address in list {
            guard let registers = registers(memory, thread: address, userState: layout.userState) else { continue }
            threads.append(Thread(
                address: address,
                registers: registers,
                neon: layout.neonState.flatMap { neon(memory, thread: address, neonState: $0) },
                id: layout.id.flatMap { memory.read64(virtual: address &+ $0) },
                tsd: layout.tsd.flatMap { memory.read64(virtual: address &+ $0) },
                name: layout.name.flatMap { name(memory, thread: address, at: $0) ?? nil },
            ))
        }
        return (threads, list.count - threads.count)
    }

    // MARK: - Live Registers

    /// Whether a vCPU was running user code of one of these threads when the
    /// guest was paused: it was at EL0 in AArch64 (`cpsr` M[4:0] = 0), on
    /// the process's page tables (`TTBR0_EL1` BADDR, without the ASID and
    /// CnP bits), and the kernel's current thread (`TPIDR_EL1`) is one of
    /// them.
    static func isRunning(
        cpsr: UInt32, ttbr0: UInt64, thread: UInt64, root: UInt64, threads: Set<UInt64>,
    ) -> Bool {
        cpsr & 0x1F == 0 && ttbr0 & 0x0000_FFFF_FFFF_FFFE == root && threads.contains(thread)
    }

    /// The threads, with the registers of each one a vCPU was running
    /// replaced by that vCPU's; the saved ones move to `saved`. A running
    /// thread has no pending exception, so its `far` and `esr` are zero:
    /// those in memory are from its last entry into the kernel, and LLDB
    /// would show them as a stop reason (a fault long handled). `saved`
    /// keeps them. A vCPU whose registers are incomplete, or a second vCPU
    /// naming the same thread, changes nothing.
    static func withLiveRegisters(_ threads: [Thread], vcpus: [VPhoneGuestDebugStub.VCPU]) -> [Thread] {
        var threads = threads
        var claimed = Set<UInt64>()
        for vcpu in vcpus {
            guard let live = vcpu.registers, live.count == 33,
                  let index = threads.firstIndex(where: { $0.address == vcpu.thread }),
                  claimed.insert(vcpu.thread).inserted
            else { continue }
            let saved = threads[index].registers
            threads[index].saved = saved
            threads[index].registers = Registers(
                x: Array(live[0 ..< 29]), fp: live[29], lr: live[30], sp: live[31], pc: live[32],
                cpsr: vcpu.cpsr, far: 0, esr: 0,
            )
            // Saved vector registers would not belong with live general ones.
            threads[index].neon = vcpu.neon?.count == 66 ? vcpu.neon : nil
        }
        return threads
    }

    /// The thread's name: nil if it has none (`.some(nil)`), or `nil` if the
    /// pointer or buffer is not a name. The kernel keeps up to 63 bytes and a
    /// terminator (`MAXTHREADNAMESIZE`).
    static func name(_ memory: some VPhoneKernelMemory, thread: UInt64, at offset: UInt64) -> String?? {
        guard let pointer = memory.read64(virtual: thread &+ offset).map(VPhoneGuestKernel.strip) else { return nil }
        if pointer == 0 { return .some(nil) }
        guard isKernelPointer(pointer) else { return nil }
        var bytes: [UInt8] = []
        for index in 0 ..< 8 {
            guard let word = memory.read64(virtual: pointer &+ UInt64(index * 8)) else { return nil }
            withUnsafeBytes(of: word.littleEndian) { bytes += $0 }
        }
        guard let end = bytes.firstIndex(of: 0),
              let text = String(validating: bytes[..<end], as: UTF8.self),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return .some(text)
    }

    // MARK: Accessors

    /// The offset of the first `ldr xN, [x0, #imm]` in a function, before any
    /// branch or return: where a one-field accessor such as `thread_tid`
    /// reads its field.
    static func accessorOffset(_ code: [UInt32]) -> UInt64? {
        for instruction in code {
            if [0xD65F_03C0, 0xD65F_0BFF, 0xD65F_0FFF].contains(instruction) { return nil }  // ret, retaa, retab
            if instruction & 0x7C00_0000 == 0x1400_0000 { return nil }  // b, bl
            if instruction & 0xFFC0_03E0 == 0xF940_0000 {  // ldr (unsigned offset), 64-bit, base x0
                return UInt64((instruction >> 10) & 0xFFF) * 8
            }
        }
        return nil
    }

    /// Keeps the accessor offsets that hold for `threads`: thread IDs all
    /// set and distinct; TSD pointers user addresses, set for most threads;
    /// names readable.
    static func checkAccessors(
        _ memory: some VPhoneKernelMemory, _ layout: Layout, threads: [UInt64],
    ) -> Layout {
        var checked = layout
        if let id = layout.id {
            let values = threads.map { memory.read64(virtual: $0 &+ id) ?? 0 }
            if values.contains(0) || Set(values).count != values.count || values.contains(where: { $0 >> 48 != 0 }) {
                checked.id = nil
            }
        }
        if let tsd = layout.tsd {
            let values = threads.compactMap { memory.read64(virtual: $0 &+ tsd) }
            if values.count != threads.count || values.contains(where: { $0 >> 47 != 0 || $0 & 7 != 0 })
                || values.filter({ $0 != 0 }).count * 2 < threads.count
            {
                checked.tsd = nil
            }
        }
        if let name = layout.name, threads.contains(where: { self.name(memory, thread: $0, at: name) == nil }) {
            checked.name = nil
        }
        return checked
    }
}

// MARK: - Kernel

extension VPhoneGuestKernel {
    /// The thread layout of this kernel, found in the first eight processes
    /// after kernel_task that have an address space.
    func threadLayout(_ processes: [Process]) throws -> VPhoneGuestThreads.Layout {
        guard let layout else { throw Failure.unexpected("the process list has not been read") }
        let sample = processes.dropFirst().filter { $0.pageTableRoot != nil }.prefix(8).map(\.address)
        var found = try VPhoneGuestThreads.discover(self, sample: Array(sample), map: layout.map)
        found.id = accessorOffset("_thread_tid")
        found.tsd = accessorOffset("_thread_dispatchqaddr")
        found.name = accessorOffset("_thread_has_thread_name")
        let threads = sample.flatMap {
            let queue = VPhoneGuestThreads.queue(self, head: $0 &+ found.list, link: found.link) ?? []
            return queue.prefix(VPhoneGuestThreads.sampleThreadLimit)
        }
        return VPhoneGuestThreads.checkAccessors(self, found, threads: threads)
    }

    private func accessorOffset(_ symbol: String) -> UInt64? {
        guard let start = try? address(symbol: symbol) else { return nil }
        let code = (0 ..< 16).compactMap { read32(virtual: start &+ UInt64($0 * 4)) }
        return VPhoneGuestThreads.accessorOffset(code)
    }
}
