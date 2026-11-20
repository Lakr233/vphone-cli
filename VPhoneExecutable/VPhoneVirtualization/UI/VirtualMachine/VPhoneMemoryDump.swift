import Foundation
import Virtualization
import VPhoneCoreKit

// MARK: - Memory Dump

/// Saves the memory of a running guest through Virtualization's own core
/// writer, `-[VZVirtualMachine _createCoresWithCompletionHandler:]`.
///
/// Virtualization pauses the guest, writes one Mach-O core (`MH_CORE`) for the
/// application processor and one for each coprocessor into shared memory, and
/// lets the guest carry on before it calls back. Its own pause and resume
/// keep the guest's devices and the SEP in step, so nothing outside the
/// framework halts a vCPU or suspends the VM service.
///
/// - `AP`: guest RAM as the kernel maps it (kernel virtual addresses), plus
///   `ARM_THREAD_STATE64` for every vCPU and an `addrable bits` note. LLDB opens
///   it with the guest's kernelcache: `lldb kernelcache -c AP.core`.
/// - `SEP-coproc`: the SEP's address space, about 20 MB.
///
/// The cores are copied out of shared memory into one folder, without the
/// all-zero 16 KiB blocks, so on APFS each file takes only the space of its
/// data. See Research/Host/memory_dump.md.
struct VPhoneMemoryDump {
    struct Core {
        /// Virtualization's name for the processor, such as `AP` or `SEP-coproc`.
        let name: String
        let file: URL
        /// The core's length; its file has this logical size.
        let bytes: UInt64
        /// The bytes written: the core without its all-zero blocks.
        let storedBytes: UInt64
    }

    let folder: URL
    let cores: [Core]
    /// From the request to Virtualization's reply. The guest is paused for
    /// most of it.
    let captureSeconds: Double
    let writeSeconds: Double

    enum Failure: LocalizedError, CustomStringConvertible {
        case unsupported
        case notRunning
        case busy
        case destinationExists(String)
        case parentMissing(String)
        case insufficientSpace(needed: UInt64, available: UInt64)
        case captureFailed(String)
        case unexpectedReply(String)
        case writeFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "This version of macOS does not offer Virtualization's core writer."
            case .notRunning:
                "The guest is not running. Start it or resume it, then try again."
            case .busy:
                "A memory dump of this machine is already being saved."
            case let .destinationExists(path):
                "\(path) already exists. Choose a name that is not taken."
            case let .parentMissing(path):
                "The folder \(path) does not exist."
            case let .insufficientSpace(needed, available):
                "The memory dump needs up to \(Self.gigabytes(needed)) of free space, and the volume has "
                    + "\(Self.gigabytes(available)). Free some space or choose another volume."
            case let .captureFailed(reason):
                "Virtualization could not create the memory dump: \(reason)"
            case let .unexpectedReply(reason):
                "Virtualization replied with something other than memory cores: \(reason)"
            case let .writeFailed(path, reason):
                "Unable to write \(path): \(reason)"
            }
        }

        /// The control socket reports errors by their description.
        var description: String { errorDescription ?? "memory dump failed" }

        static func gigabytes(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        }
    }

    // MARK: - Capture

    /// Posted once the guest runs again after a dump's pause or
    /// `VPhoneVirtualMachine.resume()`. The guest's clock stood still while it
    /// was paused, so it is behind the Mac's by as long as the pause lasted;
    /// `VPhoneClockSync` sets it again at once.
    static let guestResumedNotification = Notification.Name("VPhoneMemoryDumpGuestResumed")

    private static let createCores = NSSelectorFromString("_createCoresWithCompletionHandler:")
    private static let canCreateCore = NSSelectorFromString("_canCreateCore")
    @MainActor private static var savingMachines: Set<ObjectIdentifier> = []

    /// A dump of this VM is being taken; it is paused or about to be.
    @MainActor
    static func isSaving(_ virtualMachine: VZVirtualMachine) -> Bool {
        savingMachines.contains(ObjectIdentifier(virtualMachine))
    }

    /// Whether this macOS has the core writer at all. The guest must still be
    /// running or paused for a dump to start.
    @MainActor
    static func isSupported(by virtualMachine: VZVirtualMachine) -> Bool {
        virtualMachine.responds(to: createCores)
    }

    /// Creates `folder`, which must not exist yet, and saves the guest's
    /// memory cores and an `info.json` describing them into it. On failure
    /// nothing is left behind.
    @MainActor
    static func save(
        from vm: VPhoneVirtualMachine,
        machineName: String,
        to folder: URL,
    ) async throws -> VPhoneMemoryDump {
        let virtualMachine = vm.virtualMachine
        guard isSupported(by: virtualMachine) else { throw Failure.unsupported }
        // Virtualization refuses itself when the VM is not running or paused;
        // asking first leaves the guest alone instead of reaching the service.
        guard virtualMachine.state == .running || virtualMachine.state == .paused,
              canCreateCoreValue(virtualMachine)
        else { throw Failure.notRunning }
        try beginSaving(virtualMachine)
        defer { endSaving(virtualMachine) }

        try prepare(folder, needed: spaceNeeded(memorySize: vm.memorySize))
        do {
            let started = Date()
            print("[memdump] Saving the guest's memory to \(folder.path)")
            let cores = try await captureCores(virtualMachine)
            let captureSeconds = Date().timeIntervalSince(started)
            // A guest paused with `VPhoneVirtualMachine.pause()` stays paused.
            if virtualMachine.state == .running {
                NotificationCenter.default.post(name: guestResumedNotification, object: nil)
            }
            print("[memdump] Virtualization returned \(cores.map(\.name).joined(separator: ", ")) "
                + String(format: "in %.1f s", captureSeconds))

            let writeStarted = Date()
            let written = try await Task.detached(priority: .userInitiated) {
                try cores.map { core in
                    try write(core, into: folder)
                }
            }.value
            let dump = VPhoneMemoryDump(
                folder: folder,
                cores: written,
                captureSeconds: captureSeconds,
                writeSeconds: Date().timeIntervalSince(writeStarted),
            )
            try dump.writeInfo(machineName: machineName, memorySize: vm.memorySize, cpuCount: vm.cpuCount)
            try VPhoneHostFilePermissions.makeAccessible(at: folder)
            for core in written {
                try VPhoneHostFilePermissions.makeAccessible(at: core.file)
            }
            print("[memdump] Saved " + written.map {
                "\($0.file.lastPathComponent) (\(Failure.gigabytes($0.bytes)), \(Failure.gigabytes($0.storedBytes)) stored)"
            }.joined(separator: ", ") + String(format: "; written in %.1f s", dump.writeSeconds))
            return dump
        } catch {
            try? FileManager.default.removeItem(at: folder)
            print("[memdump] Failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// `_canCreateCore` returns a BOOL, which `perform` cannot carry; read it
    /// through its implementation instead. A macOS without it is not refused
    /// here: the core writer itself reports a VM it cannot dump.
    @MainActor
    private static func canCreateCoreValue(_ virtualMachine: VZVirtualMachine) -> Bool {
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        guard let method = class_getInstanceMethod(type(of: virtualMachine), canCreateCore) else { return true }
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        return function(virtualMachine, canCreateCore)
    }

    /// The most a dump of a guest with this much RAM can take. The AP core is
    /// a little larger than guest RAM (8.58 GB for 8 GiB); most of RAM is
    /// usually in use, so the zero blocks left out cannot be counted on.
    static func spaceNeeded(memorySize: UInt64) -> UInt64 {
        memorySize + memorySize / 16 + (256 << 20)
    }

    /// One dump of a machine at a time, of either kind.
    @MainActor
    static func beginSaving(_ virtualMachine: VZVirtualMachine) throws {
        let key = ObjectIdentifier(virtualMachine)
        guard !savingMachines.contains(key) else { throw Failure.busy }
        savingMachines.insert(key)
    }

    @MainActor
    static func endSaving(_ virtualMachine: VZVirtualMachine) {
        savingMachines.remove(ObjectIdentifier(virtualMachine))
    }

    /// Checks the destination before the guest is paused, so a dump that
    /// cannot be written never stops it, and creates the folder.
    static func prepare(_ folder: URL, needed: UInt64) throws {
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.parentMissing(parent.path)
        }
        guard !manager.fileExists(atPath: folder.path) else {
            throw Failure.destinationExists(folder.path)
        }
        // "Important usage" counts purgeable space, but some volumes, a disk
        // image for one, report it as 0; the larger of the two is the space.
        let values = try? parent.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let important = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        let plain = values?.volumeAvailableCapacity.map { UInt64(max($0, 0)) }
        if important != nil || plain != nil {
            let available = max(important ?? 0, plain ?? 0)
            if available < needed {
                throw Failure.insufficientSpace(needed: needed, available: available)
            }
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw Failure.writeFailed(folder.path, error.localizedDescription)
        }
    }

    /// One core in shared memory, still owned by Virtualization's reply.
    private struct CapturedCore: @unchecked Sendable {
        let name: String
        let data: NSData
    }

    @MainActor
    private static func captureCores(_ virtualMachine: VZVirtualMachine) async throws -> [CapturedCore] {
        try await withCheckedThrowingContinuation { continuation in
            typealias Handler = @convention(block) (AnyObject?, NSError?) -> Void
            let handler: Handler = { reply, error in
                if let error {
                    continuation.resume(throwing: Failure.captureFailed(error.localizedDescription))
                    return
                }
                guard let dictionary = reply as? NSDictionary, dictionary.count > 0 else {
                    let kind = reply.map { String(describing: type(of: $0)) } ?? "nothing"
                    continuation.resume(throwing: Failure.unexpectedReply(kind))
                    return
                }
                var cores: [CapturedCore] = []
                for case let (name as String, data as NSData) in dictionary {
                    cores.append(CapturedCore(name: name, data: data))
                }
                guard cores.count == dictionary.count else {
                    continuation.resume(throwing: Failure.unexpectedReply("\(dictionary.allKeys)"))
                    return
                }
                // The application processor first, then the coprocessors by name.
                cores.sort { ($0.name == "AP" ? 0 : 1, $0.name) < ($1.name == "AP" ? 0 : 1, $1.name) }
                continuation.resume(returning: cores)
            }
            virtualMachine.perform(createCores, with: unsafeBitCast(handler, to: AnyObject.self))
        }
    }

    // MARK: - Writing

    /// "myphone Memory 2026-11-19 at 15.20.11", in the Mac's local time, as
    /// macOS names screenshots.
    static func folderName(machine: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(machine) Memory \(formatter.string(from: date))"
    }

    private static let blockSize = 16 * 1024
    /// Contiguous data is written in runs of up to this many bytes.
    private static let maximumRun = 16 << 20

    /// `AP` becomes `AP.core`. Anything but letters, digits, `-`, `_` and `.`
    /// in a coprocessor's name becomes `_`.
    static func fileName(forCore name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let safe = String(name.map { allowed.contains($0) ? $0 : "_" })
        return (safe.isEmpty || safe.hasPrefix(".") ? "core" + safe : safe) + ".core"
    }

    private static func write(_ core: CapturedCore, into folder: URL) throws -> Core {
        let url = folder.appendingPathComponent(fileName(forCore: core.name))
        let length = core.data.length
        let stored = try writeSparse(core.data.bytes, length: length, to: url)
        return Core(name: core.name, file: url, bytes: UInt64(length), storedBytes: stored)
    }

    /// Writes `length` bytes to a new file, leaving holes for the all-zero
    /// blocks. Returns the number of bytes written.
    static func writeSparse(_ bytes: UnsafeRawPointer, length: Int, to url: URL) throws -> UInt64 {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else {
            throw Failure.writeFailed(url.path, "open: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else {
            throw Failure.writeFailed(url.path, "ftruncate: \(String(cString: strerror(errno)))")
        }
        let stored = try writeSparse(bytes, length: length, into: fd, at: 0, path: url.path)
        guard fsync(fd) == 0 else { throw Failure.writeFailed(url.path, "fsync: \(String(cString: strerror(errno)))") }
        return stored
    }

    /// Writes `length` bytes at `offset` of an open file that is already
    /// long enough, leaving the all-zero blocks as holes.
    static func writeSparse(
        _ bytes: UnsafeRawPointer,
        length: Int,
        into fd: Int32,
        at offset: UInt64,
        path: String,
    ) throws -> UInt64 {
        func failure(_ call: String) -> Failure {
            Failure.writeFailed(path, "\(call): \(String(cString: strerror(errno)))")
        }
        let base = Int64(offset)

        let zero = [UInt8](repeating: 0, count: blockSize)
        var stored: UInt64 = 0
        var position = 0
        while position < length {
            // Skip a run of zero blocks, then gather the data blocks after it.
            let size = min(blockSize, length - position)
            if memcmp(bytes + position, zero, size) == 0 {
                position += size
                continue
            }
            var end = position + size
            while end < length, end - position < maximumRun {
                let next = min(blockSize, length - end)
                if memcmp(bytes + end, zero, next) == 0 { break }
                end += next
            }
            var written = position
            while written < end {
                let result = pwrite(fd, bytes + written, end - written, off_t(base + Int64(written)))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw failure("pwrite")
                }
                written += result
            }
            stored += UInt64(end - position)
            position = end
        }
        return stored
    }

    // MARK: - Description

    /// Pretty, key-sorted JSON without escaped slashes, readable by everyone.
    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        )
        try data.write(to: url)
        try VPhoneHostFilePermissions.makeAccessible(at: url)
    }

    /// Seconds to one decimal, written as such: a Double would come out of
    /// JSONSerialization as 14.300000000000001.
    static func tenths(_ seconds: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds))
    }

    /// `info.json` beside the cores: where they came from and how to open them.
    private func writeInfo(machineName: String, memorySize: UInt64, cpuCount: Int) throws {
        let bundle = Bundle.main
        let info: [String: Any] = [
            "format": "vphone-memory-dump/1",
            "machine": machineName,
            "created": ISO8601DateFormatter().string(from: Date()),
            "vphone": [
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": bundle.object(forInfoDictionaryKey: "VPhoneBuildHash") as? String ?? "",
            ],
            "host_os": ProcessInfo.processInfo.operatingSystemVersionString,
            "guest_memory_bytes": memorySize,
            "cpu_count": cpuCount,
            "capture_seconds": Self.tenths(captureSeconds),
            "write_seconds": Self.tenths(writeSeconds),
            "cores": cores.map { core in
                [
                    "name": core.name,
                    "file": core.file.lastPathComponent,
                    "bytes": core.bytes,
                    "stored_bytes": core.storedBytes,
                ] as [String: Any]
            },
            "notes": "Mach-O MH_CORE files written by Virtualization.framework "
                + "(-[VZVirtualMachine _createCoresWithCompletionHandler:]). AP holds guest RAM at the "
                + "kernel's virtual addresses and the general registers of every vCPU; open it with "
                + "`lldb <kernelcache> -c AP.core`. All-zero 16 KiB blocks are holes in the files.",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: info,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        )
        let url = folder.appendingPathComponent("info.json")
        try data.write(to: url)
        try VPhoneHostFilePermissions.makeAccessible(at: url)
    }
}
