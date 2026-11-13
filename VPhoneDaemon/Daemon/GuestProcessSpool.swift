import Darwin
import Foundation

/// Spooled `processes.spawn` output: one private `<output_id>` directory per spawn under the guest
/// cache dir, holding `stdout` and `stderr`. The registry, the 10 minute TTL, the 64 MiB cap and
/// eviction run under one lock. Guest-free, so the logic harness compiles it.
final class GuestProcessSpool: @unchecked Sendable {
    static let shared = GuestProcessSpool(root: URL(fileURLWithPath: "/var/root/Library/Caches/vphoned-spool"))

    struct Reservation { let outputID: String; let outputDir: URL }
    struct Slice { let data: String; let total: Int; let nextOffset: Int? }

    private struct Entry {
        var created: Date
        var size = 0
        /// Bytes held back for a spawn that has not replied; 0 once it has.
        var reserved: Int
    }

    private let root: URL
    private let totalCap: Int
    private let ttl: TimeInterval
    private let now: () -> Date
    private let log: (String) -> Void
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(root: URL, totalCap: Int = 67_108_864, ttl: TimeInterval = 600, now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { NSLog("vphoned: %@", $0) })
    {
        self.root = root
        self.totalCap = totalCap
        self.ttl = ttl
        self.now = now
        self.log = log
    }

    // MARK: - Spawn side

    func reserve(maxCaptureBytes: Int) throws -> Reservation {
        lock.lock(); defer { lock.unlock() }
        try verifyRoot(create: true)
        sweepExpiredLocked()
        let need = 2 * maxCaptureBytes
        while sizeLocked() + need > totalCap {
            guard let oldest = entries.filter({ $0.value.reserved == 0 }).min(by: { $0.value.created < $1.value.created })?.key else {
                throw GuestAPIError.unavailable("spool full: release outputs with processes.output_release or repeat later")
            }
            removeLocked(oldest)
        }
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id)
        guard mkdir(dir.path, 0o700) == 0 else { throw writeFailure(String(cString: strerror(errno))) }
        entries[id] = Entry(created: now(), reserved: need)
        do { try verifyPrivate(dir.path) } catch {
            removeLocked(id)
            throw error
        }
        return Reservation(outputID: id, outputDir: dir)
    }

    func writer(_ r: Reservation, stream: String) throws -> FileHandle {
        let descriptor = open(r.outputDir.appendingPathComponent(stream).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw writeFailure(String(cString: strerror(errno))) }
        fchmod(descriptor, 0o600)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Releases the reservation. `keep` records the spool's actual size; otherwise the spool is removed.
    func finish(_ r: Reservation, keep: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[r.outputID] else { return }
        if keep {
            entry.reserved = 0
            entry.created = now()
            entry.size = ["stdout", "stderr"].reduce(0) { $0 + fileSize(r.outputDir.appendingPathComponent($1).path) }
            entries[r.outputID] = entry
        } else {
            removeLocked(r.outputID)
        }
    }

    // MARK: - Reading

    /// The first `cap` spooled bytes of `stream`, cut on a UTF-8 boundary; `truncated` when more was spooled.
    func firstPage(outputID: String, stream: String, cap: Int) throws -> (text: String, truncated: Bool) {
        let (id, descriptor) = try openStream(outputID, stream)
        defer { close(descriptor) }
        let cut = GuestProcessSpawnPolicy.cutOutput(try read(descriptor, id, offset: 0, count: cap + 1), cap: cap)
        return (String(decoding: cut.data, as: UTF8.self), cut.truncated)
    }

    func slice(outputID: String, stream: String, offset: Int, limit: Int, binary: Bool) throws -> Slice {
        let (id, descriptor) = try openStream(outputID, stream)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw released(id) }
        let total = Int(info.st_size)
        guard offset < total else { return Slice(data: "", total: total, nextOffset: nil) }
        let raw = try read(descriptor, id, offset: offset, count: limit + 1)
        var bytes = raw.prefix(limit)
        if !binary {
            let cut = GuestProcessSpawnPolicy.cutOutput(raw, cap: limit)
            // a cap inside the first character would return nothing and stall a paging caller
            if !cut.data.isEmpty || raw.isEmpty { bytes = cut.data }
        }
        let next = offset + bytes.count
        return Slice(data: binary ? Data(bytes).base64EncodedString() : String(decoding: bytes, as: UTF8.self),
                     total: total, nextOffset: next < total ? next : nil)
    }

    func release(outputID: String) throws {
        let id = try validID(outputID)
        lock.lock(); defer { lock.unlock() }
        sweepExpiredLocked()
        guard entries[id] != nil else { throw released(id) }
        removeLocked(id)
    }

    // MARK: - Sweeps

    /// Removes every spool subdir; used once when the daemon starts.
    func sweepAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        guard (try? verifyRoot(create: false)) != nil else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            removeDirectory(root.appendingPathComponent(name).path)
        }
    }

    // MARK: - Internals (lock held)

    private func sizeLocked() -> Int {
        entries.values.reduce(0) { $0 + $1.size + $1.reserved }
    }

    private func sweepExpiredLocked() {
        let cutoff = now().addingTimeInterval(-ttl)
        for (id, entry) in entries where entry.reserved == 0 && entry.created < cutoff { removeLocked(id) }
    }

    /// Drops the registry entry, then removes the directory when the root is still private.
    private func removeLocked(_ id: String) {
        entries.removeValue(forKey: id)
        guard (try? verifyRoot(create: false)) != nil else { return }
        removeDirectory(root.appendingPathComponent(id).path)
    }

    private func removeDirectory(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                if unlink(path + "/" + name) != 0, errno != ENOENT { log("spool: cannot remove \(path)/\(name): \(String(cString: strerror(errno)))") }
            }
            if rmdir(path) != 0, errno != ENOENT { log("spool: cannot remove \(path): \(String(cString: strerror(errno)))") }
        } else if unlink(path) != 0, errno != ENOENT {
            log("spool: cannot remove \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// The root must be a daemon-owned 0700 directory and not a symlink. `create` makes a missing root.
    private func verifyRoot(create: Bool) throws {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT, create else {
                if errno != ENOENT { log("spool: cannot inspect \(root.path): \(String(cString: strerror(errno)))") }
                throw GuestAPIError.operationFailed(notPrivate(root.path))
            }
            do { try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw writeFailure(error.localizedDescription)
            }
            guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else { throw writeFailure(String(cString: strerror(errno))) }
        }
        do { try verifyPrivate(root.path) } catch {
            log("spool: \(error)")
            throw error
        }
    }

    private func verifyPrivate(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o700
        else { throw GuestAPIError.operationFailed(notPrivate(path)) }
    }

    // MARK: - Helpers

    private func notPrivate(_ path: String) -> String {
        "spool directory \(path) is not private (it must be a daemon-owned 0700 directory, not a symlink); remove it on the guest and repeat"
    }

    private func writeFailure(_ reason: String) -> GuestAPIError {
        .operationFailed("spool write failed: \(reason); repeat the command")
    }

    private func released(_ id: String) -> GuestAPIError {
        .notFound("output_id \(id) is released, expired or evicted; repeat processes.spawn to capture the output again")
    }

    private func validID(_ text: String) throws -> String {
        guard let uuid = UUID(uuidString: text) else { throw GuestAPIError.invalidRequest("output_id must be a UUID") }
        return uuid.uuidString
    }

    private func fileSize(_ path: String) -> Int {
        var info = stat()
        return lstat(path, &info) == 0 ? Int(info.st_size) : 0
    }

    /// Validates the id and stream, checks the registry, and opens the stream file without following symlinks.
    private func openStream(_ outputID: String, _ stream: String) throws -> (id: String, descriptor: Int32) {
        let id = try validID(outputID)
        guard stream == "stdout" || stream == "stderr" else { throw GuestAPIError.invalidRequest("stream must be stdout or stderr") }
        lock.lock()
        sweepExpiredLocked()
        let known = entries[id] != nil
        lock.unlock()
        guard known else { throw released(id) }
        let descriptor = open(root.appendingPathComponent(id).appendingPathComponent(stream).path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw released(id) }
        return (id, descriptor)
    }

    private func read(_ descriptor: Int32, _ id: String, offset: Int, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = pread(descriptor, &buffer[filled], count - filled, off_t(offset + filled))
            if got < 0, errno == EINTR { continue }
            if got < 0 { throw released(id) }
            if got == 0 { break }
            filled += got
        }
        return Data(buffer[..<filled])
    }
}
