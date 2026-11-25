import Foundation
import Virtualization
import VPhoneCoreKit

// MARK: - Pausing

/// Runs `body` while Virtualization holds the guest paused, so the memory it
/// reads is one consistent state, and lets the guest run again afterwards
/// even when `body` fails. A VM the user had paused stays paused.
///
/// If Virtualization cannot resume the guest, even on a second try, a dump
/// that was saved is still returned, with `resumeFailure` saying so; a dump
/// that failed throws `VPhoneGuestStillPaused`.
@MainActor
func vphoneWithGuestPaused<T: Sendable>(
    _ vm: VPhoneVirtualMachine,
    _ body: @escaping @Sendable () throws -> T,
) async throws -> (value: T, pausedSeconds: Double, resumeFailure: String?) {
    nonisolated(unsafe) let machine = vm.virtualMachine
    let wasRunning = machine.state == .running
    if wasRunning {
        guard machine.canPause else { throw VPhoneMemoryDump.Failure.notRunning }
        try await machine.pause()
    } else if machine.state != .paused {
        throw VPhoneMemoryDump.Failure.notRunning
    }
    let started = Date()
    let result = await Task.detached(priority: .userInitiated) { Result { try body() } }.value
    let seconds = Date().timeIntervalSince(started)
    var resumeFailure: String?
    if wasRunning {
        for attempt in 1 ... 2 {
            do {
                try await machine.resume()
                resumeFailure = nil
                break
            } catch {
                resumeFailure = error.localizedDescription
                print("[memdump] Unable to resume the guest (attempt \(attempt)): \(error.localizedDescription)")
                if attempt == 1 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        if resumeFailure == nil {
            NotificationCenter.default.post(name: VPhoneMemoryDump.guestResumedNotification, object: nil)
        }
    }
    switch result {
    case let .success(value):
        return (value, seconds, resumeFailure.map(VPhoneGuestStillPaused.advice))
    case let .failure(error):
        if let resumeFailure { throw VPhoneGuestStillPaused(dumpError: error, resumeError: resumeFailure) }
        throw error
    }
}

/// A dump failed, and the guest could not be resumed afterwards either.
struct VPhoneGuestStillPaused: LocalizedError, CustomStringConvertible {
    let dumpError: Error
    let resumeError: String

    var errorDescription: String? {
        "\(dumpError.localizedDescription) \(Self.advice(resumeError))"
    }

    var description: String { errorDescription ?? "guest still paused" }

    static func advice(_ resumeError: String) -> String {
        "The guest could not be resumed (\(resumeError)) and is still paused. Stop the VM and start it again."
    }
}

/// The guest's kernel, placed by its vCPUs' `TTBR1_EL1` and `VBAR_EL1`,
/// read through the kernel debug stub at `stubPort`, and the view of guest
/// RAM it was found in: `memory` with DRAM at the `dram-base` the registers
/// agree with, or as mapped when the kernel was not found. Call it while the
/// guest is paused: connecting to the stub halts the vCPUs, and only a paused
/// guest stays halted when the session ends.
func vphoneFindGuestKernel(
    _ memory: VPhoneGuestPhysicalMemory,
    stubPort: Int?,
) -> (memory: VPhoneGuestPhysicalMemory, kernel: Result<VPhoneGuestKernel, Error>) {
    vphoneFindGuestKernel(memory, registers: Result {
        try VPhoneGuestDebugStub.kernelRegisters(port: vphoneDebugStubPort(stubPort))
    })
}

/// The guest's kernel, placed by `registers` already read from the stub.
func vphoneFindGuestKernel(
    _ memory: VPhoneGuestPhysicalMemory,
    registers: Result<VPhoneGuestDebugStub.KernelRegisters, Error>,
) -> (memory: VPhoneGuestPhysicalMemory, kernel: Result<VPhoneGuestKernel, Error>) {
    let kernel = Result { try VPhoneGuestKernel.locate(in: memory, registers: registers.get()) }
    return ((try? kernel.get())?.memory ?? memory, kernel)
}

func vphoneDebugStubPort(_ port: Int?) throws -> Int {
    guard let port else { throw VPhoneGuestDebugStub.Failure.unavailable("Virtualization did not report its port") }
    return port
}

// MARK: - Physical Memory

/// Guest RAM by guest physical address, as an ELF core: a `PT_LOAD` for
/// DRAM and one for the firmware carve-outs below it, with `p_paddr` and
/// `p_vaddr` the guest physical address, and a `VPHONE` note (type 0x5650)
/// holding JSON about the guest and its kernel.
struct VPhonePhysicalMemoryDump {
    let folder: URL
    let file: URL
    let bytes: UInt64
    let storedBytes: UInt64
    let pausedSeconds: Double
    /// Set when the guest could not be resumed after the dump was saved.
    let resumeFailure: String?

    static let noteType: UInt32 = 0x5650

    @MainActor
    static func save(from vm: VPhoneVirtualMachine, machineName: String, to folder: URL) async throws -> Self {
        try VPhoneMemoryDump.beginSaving(vm.virtualMachine)
        defer { VPhoneMemoryDump.endSaving(vm.virtualMachine) }
        let mapped = try await VPhoneGuestPhysicalMemory.map(vm.virtualMachine)
        let stubPort = VPhoneGuestDebugStub.port(of: vm.virtualMachine)
        let size = [mapped.carveOut, mapped.dram].compactMap(\.self).reduce(0) { $0 + $1.size }
        try VPhoneMemoryDump.prepare(folder, needed: size + (256 << 20))
        let file = folder.appendingPathComponent("physical.elf")
        do {
            print("[memdump] Saving the guest's physical memory to \(folder.path)")
            let ((stored, memory, verified), seconds, resumeFailure) = try await vphoneWithGuestPaused(vm) {
                // The kernel's registers place DRAM; without them its base is
                // unverified (`VPhoneGuestPhysicalMemory.dramBases(found:)`).
                let (memory, kernel) = vphoneFindGuestKernel(mapped, stubPort: stubPort)
                let regions = [memory.carveOut, memory.dram].compactMap(\.self)
                let stored = try write(memory: memory, regions: regions, kernel: kernel, machineName: machineName, to: file)
                return (stored, memory, (try? kernel.get()) != nil)
            }
            let dump = Self(
                folder: folder, file: file, bytes: [memory.carveOut, memory.dram].compactMap(\.self).reduce(0) { $0 + $1.size },
                storedBytes: stored, pausedSeconds: seconds, resumeFailure: resumeFailure,
            )
            try dump.writeInfo(machineName: machineName, memory: memory, dramBaseVerified: verified)
            print("[memdump] Saved physical.elf (\(VPhoneMemoryDump.Failure.gigabytes(stored)) stored); "
                + String(format: "guest paused %.1f s", seconds))
            return dump
        } catch {
            try? FileManager.default.removeItem(at: folder)
            print("[memdump] Failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Writes the ELF core; returns the bytes stored. `kernel` is what the
    /// note says about the kernel, if it was looked for.
    static func write(
        memory: VPhoneGuestPhysicalMemory,
        regions: [VPhoneGuestPhysicalMemory.Region],
        kernel: Result<VPhoneGuestKernel, Error>? = nil,
        machineName: String,
        to url: URL,
    ) throws -> UInt64 {
        let note = noteRecord(json: kernelDescription(memory: memory, kernel: kernel, machineName: machineName))
        let headersSize = 64 + 56 * (1 + regions.count)
        let noteOffset = UInt64(headersSize)
        var offset = (noteOffset + UInt64(note.count) + 0x3FFF) & ~0x3FFF
        var programHeaders = Data()
        programHeaders.append(programHeader(type: 4, flags: 4, offset: noteOffset, address: 0, size: UInt64(note.count), align: 4))
        var placements: [(VPhoneGuestPhysicalMemory.Region, UInt64)] = []
        for region in regions {
            programHeaders.append(programHeader(
                type: 1, flags: 6, offset: offset, address: region.guestAddress, size: region.size, align: 0x4000,
            ))
            placements.append((region, offset))
            offset += (region.size + 0x3FFF) & ~0x3FFF
        }
        var header = Data()
        header.append(contentsOf: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8))
        header.appendLittle(UInt16(4))  // ET_CORE
        header.appendLittle(UInt16(183))  // EM_AARCH64
        header.appendLittle(UInt32(1))
        header.appendLittle(UInt64(0))  // e_entry
        header.appendLittle(UInt64(64))  // e_phoff
        header.appendLittle(UInt64(0))  // e_shoff
        header.appendLittle(UInt32(0))
        header.appendLittle(UInt16(64))
        header.appendLittle(UInt16(56))
        header.appendLittle(UInt16(1 + regions.count))
        header.appendLittle(UInt16(64))
        header.appendLittle(UInt16(0))
        header.appendLittle(UInt16(0))

        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw VPhoneMemoryDump.Failure.writeFailed(url.path, String(cString: strerror(errno))) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(offset)) == 0 else {
            throw VPhoneMemoryDump.Failure.writeFailed(url.path, String(cString: strerror(errno)))
        }
        let head = header + programHeaders + note
        let written = head.withUnsafeBytes { pwrite(fd, $0.baseAddress, head.count, 0) }
        guard written == head.count else {
            throw VPhoneMemoryDump.Failure.writeFailed(url.path, String(cString: strerror(errno)))
        }
        var stored = UInt64(head.count)
        for (region, fileOffset) in placements {
            // Pages the guest never used are holes, read or not.
            for run in VPhoneGuestPhysicalMemory.usedRuns(memory.usedPages(of: region), size: region.size) {
                stored += try VPhoneMemoryDump.writeSparse(
                    region.base + Int(run.lowerBound), length: Int(run.upperBound - run.lowerBound),
                    into: fd, at: fileOffset + run.lowerBound, path: url.path,
                )
            }
        }
        guard fsync(fd) == 0 else {
            throw VPhoneMemoryDump.Failure.writeFailed(url.path, String(cString: strerror(errno)))
        }
        return stored
    }

    /// What the note tells a reader: the RAM layout and, when the kernel was
    /// found, where it is and its root translation table. Without the
    /// kernel, DRAM's base was not checked against its registers: an app
    /// can plant a `dram-base` value, so the note says so and lists every
    /// value found.
    static func kernelDescription(
        memory: VPhoneGuestPhysicalMemory,
        kernel: Result<VPhoneGuestKernel, Error>?,
        machineName: String,
    ) -> [String: Any] {
        var json: [String: Any] = [
            "format": "vphone-physical-memory/1",
            "machine": machineName,
            "created": ISO8601DateFormatter().string(from: Date()),
            "dram": ["guest_address": hex(memory.dram.guestAddress), "size": memory.dram.size],
        ]
        if let carveOut = memory.carveOut {
            json["carve_out"] = ["guest_address": hex(carveOut.guestAddress), "size": carveOut.size]
        }
        let verified = (try? kernel?.get()) != nil
        json["dram_base"] = [
            "verified": verified,
            "how": verified
                ? "the kernel's TTBR1_EL1 and VBAR_EL1 lie in DRAM at this base"
                : "unverified: without the kernel's registers, 0x70a00000 if the device tree search found "
                + "it, found nothing or was capped, else the first value found, which an app can plant",
            "candidates": memory.dramCandidates.map(hex),
            "candidates_capped": memory.dramCandidates.count >= VPhoneGuestPhysicalMemory.deviceTreeMatchLimit,
        ] as [String: Any]
        do {
            guard let kernel = try kernel?.get() else { return json }
            json["kernel"] = [
                "kernelcache_physical": hex(kernel.kernelcachePhysical),
                "kernel_uuid": kernel.kernelUUID,
                "ttbr1_root": hex(kernel.root),
                "symbol_map": kernel.symbols.id,
                "segments": kernel.segments.map { segment in
                    ["name": segment.name, "address": hex(segment.address), "size": segment.size,
                     "physical": kernel.translate(segment.address).map(hex) ?? NSNull()] as [String: Any]
                },
            ]
        } catch {
            json["kernel_error"] = error.localizedDescription
        }
        return json
    }

    private func writeInfo(machineName: String, memory: VPhoneGuestPhysicalMemory, dramBaseVerified: Bool) throws {
        let info: [String: Any] = [
            "format": "vphone-physical-memory/1",
            "machine": machineName,
            "created": ISO8601DateFormatter().string(from: Date()),
            "file": file.lastPathComponent,
            "bytes": bytes,
            "stored_bytes": storedBytes,
            "paused_seconds": VPhoneMemoryDump.tenths(pausedSeconds),
            "dram_base": hex(memory.dram.guestAddress),
            "dram_base_verified": dramBaseVerified,
            "notes": "ELF core of the guest's RAM: each PT_LOAD's p_paddr is a guest physical address. "
                + "The VPHONE note (type 0x5650) holds JSON with the RAM layout and, when found, the "
                + "kernelcache's physical address and the kernel's root translation table (TTBR1). "
                + "Without the kernel, DRAM's base is unverified; the note lists every dram-base value found.",
        ]
        try VPhoneMemoryDump.writeJSON(info, to: folder.appendingPathComponent("info.json"))
        try VPhoneHostFilePermissions.makeAccessible(at: folder)
        try VPhoneHostFilePermissions.makeAccessible(at: file)
    }

    static func noteRecord(json: [String: Any]) -> Data {
        let description = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        var note = Data()
        let name = Array("VPHONE".utf8) + [0]
        note.appendLittle(UInt32(name.count))
        note.appendLittle(UInt32(description.count))
        note.appendLittle(noteType)
        note.append(contentsOf: name + [UInt8](repeating: 0, count: (4 - name.count % 4) % 4))
        note.append(description)
        note.append(contentsOf: [UInt8](repeating: 0, count: (4 - description.count % 4) % 4))
        return note
    }

    private static func programHeader(
        type: UInt32, flags: UInt32, offset: UInt64, address: UInt64, size: UInt64, align: UInt64,
    ) -> Data {
        var data = Data()
        data.appendLittle(type)
        data.appendLittle(flags)
        data.appendLittle(offset)
        data.appendLittle(address)  // p_vaddr
        data.appendLittle(address)  // p_paddr
        data.appendLittle(size)
        data.appendLittle(size)
        data.appendLittle(align)
        return data
    }
}

// MARK: - Process Memory

/// The resident memory of one guest process, read through its own page
/// tables, as a Mach-O core (`MH_CORE`) with one `LC_SEGMENT_64` per run of
/// pages with the same permissions. Pages the process has not touched, and
/// pages the guest has compressed, are not in its page tables and so not in
/// the core.
struct VPhoneProcessMemoryDump {
    let folder: URL
    let file: URL
    let pid: Int32
    let name: String
    let segments: Int
    let bytes: UInt64
    let unreadableBytes: UInt64
    let pausedSeconds: Double
    /// Set when the guest could not be resumed after the dump was saved.
    let resumeFailure: String?
    let kernelUUID: String
    let symbolMap: String
    /// The threads in the core, each an `LC_THREAD`.
    let threads: Int
    /// Why the core has no threads, when it has none for a reason.
    let threadsError: String?
    /// The threads whose registers are the live ones of the vCPU running them.
    let liveThreads: Int
    /// Why the vCPUs' live registers could not be read.
    let liveError: String?

    enum Failure: LocalizedError, CustomStringConvertible {
        case renamed(Int32, expected: String, found: String)
        case noAddressSpace(Int32, String)

        var errorDescription: String? {
            switch self {
            case let .renamed(pid, expected, found):
                "pid \(pid) is now \(found), not \(expected). Refresh the process list, then try again."
            case let .noAddressSpace(pid, name):
                "\(name) (pid \(pid)) has no user address space to dump."
            }
        }

        var description: String { errorDescription ?? "process dump failed" }
    }

    /// Room asked for before the guest is paused, when the process's size
    /// is not known yet: enough for the headers and a small process.
    static let spaceNeededBeforePause: UInt64 = 256 << 20

    /// Room for a core of `mappings`: their pages, the load commands, and a
    /// margin. Checked in the pause, once the mappings are known; a process
    /// with its share of the shared cache is usually 1 to 1.5 GB.
    static func spaceNeeded(_ mappings: [VPhoneGuestKernel.Mapping]) -> UInt64 {
        mappings.reduce(UInt64(0)) { $0 &+ $1.size } &+ UInt64(mappings.count) &* 72 &+ spaceNeededBeforePause
    }

    @MainActor
    static func save(
        from vm: VPhoneVirtualMachine,
        machineName: String,
        pid: Int32,
        expectedName: String?,
        to folder: URL,
    ) async throws -> Self {
        try VPhoneMemoryDump.beginSaving(vm.virtualMachine)
        defer { VPhoneMemoryDump.endSaving(vm.virtualMachine) }
        let memory = try await VPhoneGuestPhysicalMemory.map(vm.virtualMachine)
        let stubPort = VPhoneGuestDebugStub.port(of: vm.virtualMachine)
        try VPhoneMemoryDump.prepare(folder, needed: spaceNeededBeforePause)
        do {
            print("[memdump] Saving the memory of pid \(pid) to \(folder.path)")
            let (dump, seconds, resumeFailure) = try await vphoneWithGuestPaused(vm) {
                try capture(memory: memory, pid: pid, expectedName: expectedName, folder: folder, stubPort: stubPort)
            }
            let result = Self(
                folder: folder, file: dump.file, pid: pid, name: dump.name, segments: dump.segments,
                bytes: dump.bytes, unreadableBytes: dump.unreadable, pausedSeconds: seconds,
                resumeFailure: resumeFailure,
                kernelUUID: dump.kernelUUID, symbolMap: dump.symbolMap,
                threads: dump.threads.count, threadsError: dump.threadsError,
                liveThreads: dump.threads.count(where: { $0.live }), liveError: dump.liveError,
            )
            try result.writeInfo(machineName: machineName, pageTableRoot: dump.root, captured: dump)
            print("[memdump] Saved \(dump.file.lastPathComponent): \(dump.segments) segments, "
                + VPhoneMemoryDump.Failure.gigabytes(dump.bytes) + ", \(dump.threads.count) threads"
                + String(format: "; guest paused %.1f s", seconds))
            return result
        } catch {
            try? FileManager.default.removeItem(at: folder)
            print("[memdump] Failed: \(error.localizedDescription)")
            throw error
        }
    }

    private struct Captured: Sendable {
        let file: URL
        let name: String
        let segments: Int
        let bytes: UInt64
        let unreadable: UInt64
        let root: UInt64
        let kernelUUID: String
        let symbolMap: String
        /// Where the process is, and the offsets the kernel walk found.
        let kernelDetails: [String: String]
        let threads: [ThreadInfo]
        let skippedThreads: Int
        let threadsError: String?
        let liveError: String?
        let addressBits: Int
    }

    private static func capture(
        memory: VPhoneGuestPhysicalMemory,
        pid: Int32,
        expectedName: String?,
        folder: URL,
        stubPort: Int?,
    ) throws -> Captured {
        // One stub session reads where the kernel is and every vCPU's
        // identity, with the registers of each one running user code (EL0):
        // the threads are not known yet, so which of those it ran is decided
        // below.
        let reading = Result {
            try VPhoneGuestDebugStub.registers(port: vphoneDebugStubPort(stubPort)) { $0.cpsr & 0x1F == 0 }
        }
        let kernel = try vphoneFindGuestKernel(memory, registers: reading.map(\.kernel)).kernel.get()
        // DRAM where the kernel's registers place it.
        let memory = kernel.memory
        let processes = try kernel.processes()
        guard let process = processes.first(where: { $0.pid == pid }) else {
            throw VPhoneGuestKernel.Failure.noProcess(pid)
        }
        // vphoned's name is p_comm, cut at 16 characters.
        if let expectedName, !expectedName.isEmpty, !process.name.isEmpty,
           !expectedName.hasPrefix(process.name), !process.name.hasPrefix(expectedName)
        {
            throw Failure.renamed(pid, expected: expectedName, found: process.name)
        }
        guard let root = process.pageTableRoot else { throw Failure.noAddressSpace(pid, process.name) }
        let mappings = try kernel.userMappings(root: root)
        try VPhoneMemoryDump.checkSpace(at: folder, needed: spaceNeeded(mappings))
        // The memory is worth saving without the threads.
        var threads: [VPhoneGuestThreads.Thread] = []
        var skipped = 0
        var threadLayout: VPhoneGuestThreads.Layout?
        var threadsError: String?
        do {
            let layout = try kernel.threadLayout(processes)
            (threads, skipped) = try VPhoneGuestThreads.threads(kernel, process: process.address, layout: layout)
            threadLayout = layout
        } catch {
            threadsError = error.localizedDescription
        }
        // A thread running user code on a vCPU has its registers there, not
        // in memory; the stub session that placed the kernel read them. If
        // it could not, such a thread keeps the registers of its last entry
        // into the kernel.
        var liveError: String?
        if !threads.isEmpty {
            let addresses = Set(threads.map(\.address))
            do {
                let vcpus = try reading.get().vcpus.get().filter {
                    VPhoneGuestThreads.isRunning(
                        cpsr: $0.cpsr, ttbr0: $0.ttbr0, thread: $0.thread, root: root, threads: addresses,
                    )
                }
                threads = VPhoneGuestThreads.withLiveRegisters(threads, vcpus: vcpus)
            } catch {
                liveError = error.localizedDescription
            }
        }
        let file = folder.appendingPathComponent(VPhoneMemoryDump.fileName(forCore: process.name.isEmpty ? "process" : process.name))
        let (segments, bytes, unreadable) = try writeCore(mappings: mappings, threads: threads, memory: memory, to: file)
        var kernelDetails = [
            "proc": hex(process.address),
            "proc_p_pid": kernel.layout.map { hex($0.pid) } ?? "",
            "proc_p_comm": kernel.layout.map { hex($0.name) } ?? "",
            "proc_task_map": kernel.layout.map { hex($0.map) } ?? "",
            "map_pmap": kernel.layout.map { hex($0.pmap) } ?? "",
        ]
        if let threadLayout {
            kernelDetails["proc_task_threads"] = hex(threadLayout.list)
            kernelDetails["thread_task_threads"] = hex(threadLayout.link)
            kernelDetails["thread_user_state"] = hex(threadLayout.userState)
            kernelDetails["thread_neon_state"] = threadLayout.neonState.map(hex) ?? ""
            kernelDetails["thread_id"] = threadLayout.id.map(hex) ?? ""
            kernelDetails["thread_tsd"] = threadLayout.tsd.map(hex) ?? ""
            kernelDetails["thread_name"] = threadLayout.name.map(hex) ?? ""
            kernelDetails["thread_discovery_reads"] = String(threadLayout.reads)
        }
        return Captured(
            file: file, name: process.name, segments: segments, bytes: bytes, unreadable: unreadable,
            root: root, kernelUUID: kernel.kernelUUID, symbolMap: kernel.symbols.id,
            kernelDetails: kernelDetails,
            threads: threads.map(Self.threadDescription), skippedThreads: skipped, threadsError: threadsError,
            liveError: liveError, addressBits: addressBits(mappings),
        )
    }

    /// What info.json says about a thread; the registers are in the core.
    static func threadDescription(_ thread: VPhoneGuestThreads.Thread) -> ThreadInfo {
        ThreadInfo(
            id: thread.id, name: thread.name, tsd: thread.tsd,
            pc: thread.registers.pc, lr: thread.registers.lr, sp: thread.registers.sp,
            esr: thread.registers.esr, far: thread.registers.far,
            saved: thread.saved,
        )
    }

    struct ThreadInfo: Sendable {
        let id: UInt64?
        let name: String?
        let tsd: UInt64?
        let pc: UInt64
        let lr: UInt64
        let sp: UInt64
        let esr: UInt32
        let far: UInt64
        /// Set when the registers are a vCPU's: the ones the kernel had saved.
        var saved: VPhoneGuestThreads.Registers? = nil

        var live: Bool { saved != nil }

        var json: [String: Any] {
            var json: [String: Any] = [
                "pc": hex(pc), "lr": hex(lr), "sp": hex(sp), "esr": hex(UInt64(esr)), "far": hex(far),
            ]
            if let id { json["thread_id"] = id }
            if let name { json["name"] = name }
            if let tsd { json["tsd"] = hex(tsd) }
            if let saved {
                json["live"] = true
                json["saved"] = [
                    "pc": hex(saved.pc), "lr": hex(saved.lr), "sp": hex(saved.sp),
                    "esr": hex(UInt64(saved.esr)), "far": hex(saved.far),
                ]
            }
            return json
        }
    }

    /// The protection of a page from its descriptor: EL0 read/write from
    /// AP[2:1], execute unless UXN. Readable is assumed, so LLDB reads every
    /// page; the guest may refine these through permission indirection.
    static func protection(_ entry: UInt64) -> Int32 {
        var protection: Int32 = 1
        if (entry >> 6) & 3 == 1 { protection |= 2 }
        if entry & (1 << 54) == 0 { protection |= 4 }
        return protection
    }

    /// How many low address bits a user pointer of this process uses: the
    /// fewest, from 39 up, that cover every mapping. LLDB strips the bits
    /// above (pointer authentication codes) from return addresses and
    /// pointers; no mapped address needs them.
    static func addressBits(_ mappings: [VPhoneGuestKernel.Mapping]) -> Int {
        guard let end = mappings.map({ $0.virtual &+ $0.size }).max(), end > 1 else { return 39 }
        return max(39, 64 - (end - 1).leadingZeroBitCount)
    }

    /// One `LC_THREAD` the way XNU's and LLDB's cores write one: the user
    /// registers (`ARM_THREAD_STATE64`), the fault registers
    /// (`ARM_EXCEPTION_STATE64`) and, when known, the vector registers
    /// (`ARM_NEON_STATE64`).
    static func threadCommand(_ thread: VPhoneGuestThreads.Thread) -> Data {
        var state = Data()
        let registers = thread.registers
        state.appendLittle(UInt32(6))  // ARM_THREAD_STATE64
        state.appendLittle(UInt32(68))
        for value in registers.x + [registers.fp, registers.lr, registers.sp, registers.pc] {
            state.appendLittle(value)
        }
        state.appendLittle(registers.cpsr)
        state.appendLittle(UInt32(0))  // flags: the pointers are as the thread had them
        state.appendLittle(UInt32(7))  // ARM_EXCEPTION_STATE64
        state.appendLittle(UInt32(4))
        state.appendLittle(registers.far)
        state.appendLittle(registers.esr)
        state.appendLittle(UInt32(0))  // exception
        if let neon = thread.neon, neon.count == 66 {
            state.appendLittle(UInt32(17))  // ARM_NEON_STATE64
            state.appendLittle(UInt32(132))
            for word in neon { state.appendLittle(word) }
        }
        var command = Data()
        command.appendLittle(UInt32(4))  // LC_THREAD
        command.appendLittle(UInt32(8 + state.count))
        return command + state
    }

    /// An `LC_NOTE` naming `payload` at `offset` in the file.
    static func noteCommand(_ name: String, offset: UInt64, size: Int) -> Data {
        var command = Data()
        command.appendLittle(UInt32(0x31))  // LC_NOTE
        command.appendLittle(UInt32(40))
        let bytes = Array(name.utf8.prefix(16))
        command.append(contentsOf: bytes + [UInt8](repeating: 0, count: 16 - bytes.count))
        command.appendLittle(offset)
        command.appendLittle(UInt64(size))
        return command
    }

    /// The `LC_NOTE`s LLDB reads from a user process core: "addrable bits"
    /// (version 4: the bits for low and high addresses) and, when every
    /// thread's ID is known, "process metadata", whose `threads` list gives
    /// the `LC_THREAD`s their IDs in order.
    static func notes(threads: [VPhoneGuestThreads.Thread], addressBits: Int) -> [(String, Data)] {
        var bits = Data()
        bits.appendLittle(UInt32(4))
        bits.appendLittle(UInt32(addressBits))
        bits.appendLittle(UInt32(addressBits))
        bits.appendLittle(UInt32(0))
        var notes = [("addrable bits", bits)]
        let ids = threads.compactMap(\.id)
        if !threads.isEmpty, ids.count == threads.count {
            let metadata: [String: Any] = ["threads": ids.map { ["thread_id": $0] }]
            if let json = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                notes.append(("process metadata", json))
            }
        }
        return notes
    }

    /// Writes the Mach-O core; returns (segments, bytes, bytes outside guest RAM).
    static func writeCore(
        mappings: [VPhoneGuestKernel.Mapping],
        threads: [VPhoneGuestThreads.Thread] = [],
        memory: VPhoneGuestPhysicalMemory,
        to url: URL,
    ) throws -> (Int, UInt64, UInt64) {
        // Runs of adjacent pages with one protection become one segment.
        var runs: [(address: UInt64, size: UInt64, protection: Int32, first: Int, count: Int)] = []
        for (index, mapping) in mappings.enumerated() {
            let protection = protection(mapping.entry)
            if let last = runs.last, last.address + last.size == mapping.virtual, last.protection == protection {
                runs[runs.count - 1].size += mapping.size
                runs[runs.count - 1].count += 1
            } else {
                runs.append((mapping.virtual, mapping.size, protection, index, 1))
            }
        }
        // Segments, then the threads, then the notes, whose payloads follow
        // the load commands; the memory starts at the next 16 KB.
        let threadCommands = threads.map(threadCommand)
        let notes = notes(threads: threads, addressBits: addressBits(mappings))
        let commandCount = runs.count + threadCommands.count + notes.count
        let commandsSize = runs.count * 72 + threadCommands.reduce(0) { $0 + $1.count } + notes.count * 40
        // The mappings (`VPhoneGuestPageTables.Limits`) and threads
        // (`VPhoneGuestThreads.threadLimit`) are bounded, so this holds; a
        // header beyond it would not fit its 32-bit fields.
        guard commandsSize <= Int(UInt32.max) / 2 else {
            throw VPhoneMemoryDump.Failure.writeFailed(url.path, "too many load commands (\(commandCount))")
        }
        var notePayloads = Data()
        var noteCommands = Data()
        for (name, payload) in notes {
            noteCommands += noteCommand(name, offset: UInt64(32 + commandsSize + notePayloads.count), size: payload.count)
            notePayloads += payload
            notePayloads.append(contentsOf: [UInt8](repeating: 0, count: (16 - payload.count % 16) % 16))
        }
        var fileOffset = (UInt64(32 + commandsSize + notePayloads.count) + 0x3FFF) & ~0x3FFF
        var head = Data()
        head.appendLittle(UInt32(0xFEED_FACF))
        head.appendLittle(UInt32(0x0100_000C))  // CPU_TYPE_ARM64
        head.appendLittle(UInt32(2))  // CPU_SUBTYPE_ARM64E
        head.appendLittle(UInt32(4))  // MH_CORE
        head.appendLittle(UInt32(commandCount))
        head.appendLittle(UInt32(commandsSize))
        head.appendLittle(UInt32(0))
        head.appendLittle(UInt32(0))
        var placements: [UInt64] = []
        for run in runs {
            head.appendLittle(UInt32(0x19))  // LC_SEGMENT_64
            head.appendLittle(UInt32(72))
            head.append(contentsOf: [UInt8](repeating: 0, count: 16))
            head.appendLittle(run.address)
            head.appendLittle(run.size)
            head.appendLittle(fileOffset)
            head.appendLittle(run.size)
            head.appendLittle(run.protection)
            head.appendLittle(run.protection)
            head.appendLittle(UInt32(0))
            head.appendLittle(UInt32(0))
            placements.append(fileOffset)
            fileOffset += run.size
        }
        for command in threadCommands { head += command }
        head += noteCommands + notePayloads

        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw VPhoneMemoryDump.Failure.writeFailed(url.path, String(cString: strerror(errno))) }
        defer { close(fd) }
        func fail() -> Error { VPhoneMemoryDump.Failure.writeFailed(url.path, String(cString: strerror(errno))) }
        guard ftruncate(fd, off_t(fileOffset)) == 0 else { throw fail() }
        guard head.withUnsafeBytes({ pwrite(fd, $0.baseAddress, head.count, 0) }) == head.count else { throw fail() }

        var unreadable: UInt64 = 0
        for (run, start) in zip(runs, placements) {
            var position = start
            for mapping in mappings[run.first ..< run.first + run.count] {
                if let source = memory.pointer(physical: mapping.physical, count: Int(mapping.size)) {
                    var done = 0
                    while done < Int(mapping.size) {
                        let result = pwrite(fd, source + done, Int(mapping.size) - done, off_t(position) + off_t(done))
                        if result < 0 {
                            if errno == EINTR { continue }
                            throw fail()
                        }
                        done += result
                    }
                } else {
                    unreadable += mapping.size  // outside guest RAM: left as zeros
                }
                position += mapping.size
            }
        }
        guard fsync(fd) == 0 else { throw fail() }
        return (runs.count, runs.reduce(0) { $0 + $1.size }, unreadable)
    }

    private func writeInfo(machineName: String, pageTableRoot: UInt64, captured: Captured) throws {
        var info: [String: Any] = [
            "kernel": captured.kernelDetails,
            "format": "vphone-process-memory/1",
            "machine": machineName,
            "created": ISO8601DateFormatter().string(from: Date()),
            "pid": pid,
            "name": name,
            "file": file.lastPathComponent,
            "segments": segments,
            "bytes": bytes,
            "unreadable_bytes": unreadableBytes,
            "page_table_root": hex(pageTableRoot),
            "kernel_uuid": kernelUUID,
            "symbol_map": symbolMap,
            "paused_seconds": VPhoneMemoryDump.tenths(pausedSeconds),
            "address_bits": captured.addressBits,
            "threads": captured.threads.map(\.json),
            "notes": "Mach-O core of the process's resident pages, read through its page tables in guest "
                + "RAM without the guest's help. Pages the process never touched, and pages the guest "
                + "compressed, are not included. Permissions come from the page table entries and are "
                + "approximate. Each thread is an LC_THREAD with the user registers the kernel saved when "
                + "the thread last entered it (general, exception and NEON registers), in queue order; "
                + "\"threads\" lists them in the same order. A thread that was running user code on a vCPU "
                + "when the guest was paused (at most one per vCPU) has that vCPU's registers instead, read "
                + "through Virtualization's kernel debug stub, and is marked \"live\", with the saved pc, lr, "
                + "sp, esr and far under \"saved\"; its own esr and far are zero, as no exception is pending. "
                + "If the vCPUs' registers could not be read, \"live_registers_error\" says why, "
                + "and such a thread has its registers from its last entry into the kernel.",
        ]
        info["live_threads"] = liveThreads
        if captured.skippedThreads > 0 { info["skipped_threads"] = captured.skippedThreads }
        if let error = captured.threadsError { info["threads_error"] = error }
        if let error = captured.liveError { info["live_registers_error"] = error }
        try VPhoneMemoryDump.writeJSON(info, to: folder.appendingPathComponent("info.json"))
        try VPhoneHostFilePermissions.makeAccessible(at: folder)
        try VPhoneHostFilePermissions.makeAccessible(at: file)
    }

    /// "myphone launchd (1) Memory 2026-11-20 at 10.02.03".
    static func folderName(machine: String, process: String, pid: Int32, date: Date) -> String {
        let base = VPhoneMemoryDump.folderName(machine: machine, date: date)
        let safe = process.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return base.replacingOccurrences(of: "\(machine) Memory", with: "\(machine) \(safe) (\(pid)) Memory")
    }
}

// MARK: - Helpers

func hex(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
}

extension Data {
    mutating func appendLittle<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
