import Darwin
import Foundation

// MARK: - Activity

/// Whether a machine is in use, for operations that read or replace its state
/// files and need them to stand still: cloning, snapshotting and reverting.
///
/// A running `vphone-vm` keeps the disk image, `SEPStorage` and `nvram.bin`
/// open, and they move together: the SEP's anti-replay counters and the xART
/// gigalocker on the disk advance as a pair. A copy of a running machine can
/// take one at a different moment from the other, and the guest then panics in
/// the SEP on its next boot. So the check looks for any process holding one of
/// the three open, by device and inode rather than path. Another user's process
/// (a VM started under sudo) cannot be inspected without root, so a
/// `vphone.sock` counts as running too unless it is missing, not a socket, or
/// refuses the connection as a stale one does. A root-owned socket this user
/// may not connect to is running.
public enum VPhoneBundleActivity {
    /// The files a running VM holds open, and the ones a clone, snapshot or
    /// revert must take together, by their names inside the bundle.
    public static func stateFileNames(of bundle: VPhoneBundle) -> [String] {
        [bundle.manifest.diskImage, bundle.manifest.sepStorage, bundle.manifest.nvramStorage]
    }

    /// Throws `VPhoneBundleActivityError.running` unless the machine is stopped.
    ///
    /// Any holder refuses, not only a process that runs the machine: a file
    /// another program is reading or writing is not standing still either.
    /// The error names each holder's executable, so a refusal caused by, say,
    /// a backup tool reading `Disk.img` is not mistaken for a running VM.
    public static func requireStopped(_ bundle: VPhoneBundle) throws {
        try requireStopped(bundle, waitingForReaders: 0)
    }

    /// How long an operation that only reads a machine waits for holders
    /// that do not run it to close its files: Launchpad's disk meter holds an
    /// image for 0.1 s or less, longer on a slow Mac.
    public static let readerWait: TimeInterval = 2

    /// `requireStopped` for an operation that only reads the machine's files,
    /// a clone's source: while every holder is a process that does not run a
    /// machine (Launchpad's disk meter, Spotlight, a backup tool), it checks
    /// again every 0.1 s for up to `wait` seconds before refusing. A VM
    /// process holding a file, or a live control socket, refuses at once.
    /// Operations that write the files keep `requireStopped`.
    public static func requireStopped(_ bundle: VPhoneBundle, waitingForReaders wait: TimeInterval) throws {
        let socket = bundle.url.appendingPathComponent("vphone.sock")
        try requireStopped(
            name: bundle.name,
            waitingForReaders: wait,
            holders: { stateFileHolders(of: bundle).map { VPhoneProcessHolder(pid: $0) } },
            socketIsLive: { controlSocketIsLive(socket) },
            sleep: { Thread.sleep(forTimeInterval: $0) },
        )
    }

    /// The PIDs of this user's processes holding any of the machine's state
    /// files (disk image, SEP storage, nvram) open, by device and inode. The
    /// single definition of "holds the machine's files" that both the `vm
    /// launch` gate (`requireStopped`) and `vm stop`'s confirmation
    /// (`confirmStopped`) use, so the two cannot drift. Best-effort by
    /// construction: a missing or unstat-able state file contributes no holder
    /// (it counts as released), so the confirmation is never stricter than the
    /// gate it protects.
    public static func stateFileHolders(of bundle: VPhoneBundle) -> [pid_t] {
        processesHolding(stateFileNames(of: bundle).map { bundle.url.appendingPathComponent($0) })
    }

    /// `vm stop`'s confirmation, once the machine has been signalled (whether
    /// it quit on SIGINT or was killed): wait until the launch gate would let
    /// the machine start again, then report the outcome. A signal only
    /// requests termination and the kernel reaps asynchronously, so the VM
    /// service can hold the state files, or `vphone-vm` its control socket,
    /// for a short tail after the signals, and an immediate `vm launch` would
    /// be refused on it.
    ///
    /// Waits on the processes that run a machine and hold a state file,
    /// this machine's `vphone-vm` (found by `--config`; it binds `vphone.sock`
    /// and holds none of the files), and the control socket. Returns
    /// `(message: "<name>: stopped", isError: false)` once all are gone, or
    /// an error naming what is left after `maxSleeps` sleeps of `interval`.
    public static func confirmStopped(
        _ bundle: VPhoneBundle,
        maxSleeps: Int,
        interval: TimeInterval,
    ) -> (message: String, isError: Bool) {
        let socket = bundle.url.appendingPathComponent("vphone.sock")
        return confirmStopped(
            name: bundle.name,
            maxSleeps: maxSleeps,
            interval: interval,
            holders: {
                (stateFileHolders(of: bundle) + VPhoneGuestProcesses.virtualMachinePIDs(config: bundle.configURL))
                    .map { VPhoneProcessHolder(pid: $0) }
            },
            socketIsLive: { controlSocketIsLive(socket) },
            sleep: { Thread.sleep(forTimeInterval: $0) },
        )
    }

    /// The decision behind `confirmStopped`, with the process table, the
    /// socket probe and the clock injected. Iteration-counted (not
    /// wall-clock): at most `maxSleeps` sleeps, so at most `maxSleeps + 1`
    /// probes. A holder that does not run a machine (Launchpad's disk meter,
    /// Spotlight, a backup tool) neither extends the wait nor fails the stop.
    /// The socket is probed only once no process that runs a machine is left.
    static func confirmStopped(
        name: String,
        maxSleeps: Int,
        interval: TimeInterval,
        holders: () -> [VPhoneProcessHolder],
        socketIsLive: () -> Bool,
        sleep: (TimeInterval) -> Void,
    ) -> (message: String, isError: Bool) {
        var sleeps = 0
        while true {
            // PID order; a vphone-vm found both ways is named once.
            var seen = Set<pid_t>()
            let machine = holders()
                .filter(\.runsMachine)
                .sorted { $0.pid < $1.pid }
                .filter { seen.insert($0.pid).inserted }
            if machine.isEmpty, !socketIsLive() {
                return (message: "\(name): stopped", isError: false)
            }
            if sleeps >= maxSleeps {
                return machine.isEmpty
                    ? (message: "\(name): could not stop; its control socket is still live", isError: true)
                    : (message: "\(name): could not stop; still held by \(VPhoneProcessHolder.describe(machine))", isError: true)
            }
            sleep(interval)
            sleeps += 1
        }
    }

    /// The decision behind `requireStopped`, with the process table, the
    /// socket probe and the clock injected. With no holders the socket
    /// decides. Holders refuse at once when one runs a machine or the wait
    /// is over; otherwise, while the socket is not live, they are asked again
    /// after `interval`. With `wait` 0 the socket is not probed for a held
    /// machine, as before the wait existed.
    static func requireStopped(
        name: String,
        waitingForReaders wait: TimeInterval,
        interval: TimeInterval = 0.1,
        holders: () -> [VPhoneProcessHolder],
        socketIsLive: () -> Bool,
        sleep: (TimeInterval) -> Void,
    ) throws {
        var waited: TimeInterval = 0
        while true {
            let found = holders()
            if found.isEmpty {
                if socketIsLive() {
                    throw VPhoneBundleActivityError.running(name: name, holders: [])
                }
                return
            }
            // Compared with a margin, so 20 steps of 0.1 s make 2 s.
            if waited + interval / 2 >= wait || found.contains(where: \.runsMachine) || socketIsLive() {
                throw VPhoneBundleActivityError.running(name: name, holders: found)
            }
            sleep(interval)
            waited += interval
        }
    }

    // MARK: - Processes

    /// The processes of this user that have any of `urls` open, sorted. One
    /// pass over the process table, whatever the number of files; a missing
    /// file is held by nobody.
    static func processesHolding(_ urls: [URL]) -> [pid_t] {
        var targets = Set<FileID>()
        for url in urls {
            var info = stat()
            if stat(url.path, &info) == 0 {
                targets.insert(FileID(device: info.st_dev, inode: info.st_ino))
            }
        }
        guard !targets.isEmpty else { return [] }
        return VPhoneGuestProcesses.allPIDs().filter { holds(pid: $0, anyOf: targets) }
    }

    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func holds(pid: pid_t, anyOf targets: Set<FileID>) -> Bool {
        // EPERM for another user's process: it is skipped, and the socket
        // probe covers the case that matters (a VM under sudo, whose socket
        // refuses this user with EACCES).
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, Int32(MemoryLayout<vnode_fdinfo>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfo>.size) else { continue }
            let st = info.pvi.vi_stat
            // vst_dev is unsigned and dev_t signed: devfs can be numbered past
            // Int32.max (0xC6B21E7F on macOS 27), and every process holds
            // /dev/null, so a plain conversion traps on any scan.
            if targets.contains(FileID(device: dev_t(bitPattern: st.vst_dev), inode: ino_t(st.vst_ino))) {
                return true
            }
        }
        return false
    }

    // MARK: - Control socket

    /// Whether `vphone.sock` belongs to a live VM. Only two answers mean it
    /// does not: no socket there (nothing at the path, or something other than
    /// a socket, judged without following a link), and a socket whose
    /// `connect` fails with ECONNREFUSED or ENOENT, the file a VM that exited
    /// leaves behind. Any other failure counts as live: a VM started under
    /// sudo owns its socket as root with mode 0755, so this user's `connect`
    /// fails with EACCES while the VM runs, and its processes are hidden from
    /// `processesHolding` too.
    private static func controlSocketIsLive(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
        switch VPhoneUnixSocket.connect(to: url.path) {
        case let .success(fd):
            close(fd)
            return true
        case let .failure(.connect(failure)):
            return failure != ECONNREFUSED && failure != ENOENT
        case .failure(.pathTooLong), .failure(.socket):
            // A socket that cannot be probed (a path too long for sun_path, or
            // no descriptor to probe with) is there all the same, and calling
            // it stale would let a clone or revert copy or replace the state
            // files of a running guest, so it counts as live; removing a stale
            // one by hand clears the refusal.
            return true
        }
    }
}

// MARK: - Error

public enum VPhoneBundleActivityError: Error, Equatable {
    /// The machine's state files are held open by `holders`, or its control
    /// socket is live (then `holders` may be empty).
    case running(name: String, holders: [VPhoneProcessHolder])

    /// `running` with each process's executable looked up now.
    public static func running(name: String, pids: [pid_t]) -> VPhoneBundleActivityError {
        .running(name: name, holders: pids.map { VPhoneProcessHolder(pid: $0) })
    }
}

extension VPhoneBundleActivityError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .running(name, holders):
            let (machine, others) = VPhoneProcessHolder.classify(holders)
            guard machine.isEmpty, !others.isEmpty else {
                let who = holders.isEmpty ? "" : " (process \(VPhoneProcessHolder.describe(machine + others)))"
                return "VM '\(name)' is running\(who). Stop it, then try again."
            }
            // No VM process holds the files: say who does, so a backup tool
            // or Launchpad's disk meter is not taken for a running VM.
            return "VM '\(name)' is in use: its disk or state files are open in process "
                + "\(VPhoneProcessHolder.describe(others)), which does not run it. "
                + "Try again once that process closes them."
        }
    }

    public var errorDescription: String? {
        description
    }
}
