import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// Telling a running machine from a stopped one before its state files are
/// copied or replaced.
struct BundleActivityTests {
    private func makeBundle() throws -> (root: URL, bundle: VPhoneBundle) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let bundle = try VPhoneBundleOperations.create(
            .init(name: "vm", cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: VPhoneLibrary(root: root),
        )
        try Data([1, 2, 3]).write(to: bundle.url.appendingPathComponent("nvram.bin"))
        return (root, bundle)
    }

    private func isRunning(_ bundle: VPhoneBundle) -> Bool {
        (try? VPhoneBundleActivity.requireStopped(bundle)) == nil
    }

    @Test func `finds this process holding an open file`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = bundle.url.appendingPathComponent("Disk.img")

        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        let fd = open(disk.path, O_RDONLY)
        #expect(fd >= 0)
        #expect(VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        close(fd)
        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
    }

    @Test func `finds a holder on a device numbered past Int32.max`() throws {
        // /dev is such a device on macOS 27; the scan must match it, not trap.
        let null = URL(fileURLWithPath: "/dev/null")
        let fd = open(null.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(VPhoneBundleActivity.processesHolding([null]).contains(getpid()))
    }

    @Test func `a missing file has no holders`() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(VPhoneBundleActivity.processesHolding([missing]).isEmpty)
    }

    @Test func `a stopped machine passes and a held state file refuses`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        try VPhoneBundleActivity.requireStopped(bundle)
        #expect(!isRunning(bundle))

        for name in ["Disk.img", "SEPStorage", "nvram.bin"] {
            let fd = open(bundle.url.appendingPathComponent(name).path, O_RDONLY)
            #expect(fd >= 0)
            #expect(isRunning(bundle))
            #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])) {
                try VPhoneBundleActivity.requireStopped(bundle)
            }
            close(fd)
        }
    }

    /// A socket bound and listening at the bundle's `vphone.sock`.
    private func listenAtControlSocket(of bundle: VPhoneBundle) throws -> (fd: Int32, path: String) {
        let path = bundle.url.appendingPathComponent("vphone.sock").path
        // A socket path must fit sun_path; the temporary directory usually does.
        try #require(path.utf8.count < 104)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() {
                buffer[index] = byte
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        return (fd, path)
    }

    @Test func `a listening control socket counts as running and a stale one does not`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, path) = try listenAtControlSocket(of: bundle)
        #expect(isRunning(bundle))

        // The socket file outlives the listener, as it does after a crash.
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!isRunning(bundle))
    }

    @Test func `a control socket this user may not connect to counts as running`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, path) = try listenAtControlSocket(of: bundle)
        defer { close(fd) }

        // Like a root-owned socket of a VM started under sudo: connect fails
        // with EACCES, here even for the owner, while the listener is up.
        #expect(chmod(path, 0) == 0)
        defer { chmod(path, 0o755) }
        #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [])) {
            try VPhoneBundleActivity.requireStopped(bundle)
        }
    }

    // MARK: - Waiting for readers

    private static let meter = VPhoneProcessHolder(pid: 900, executablePath: "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad")
    private static let vm = VPhoneProcessHolder(pid: 410, executablePath: "/opt/VPhone.bundle/Contents/MacOS/vphone-vm")
    private static let service = VPhoneProcessHolder(
        pid: 412,
        executablePath: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
            + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
    )

    /// Runs the decision over `answers`, one per probe (the last repeats),
    /// and returns how many times it slept and probed the socket.
    private func decide(
        wait: TimeInterval,
        _ answers: [[VPhoneProcessHolder]],
        socketIsLive: Bool = false,
    ) -> (error: VPhoneBundleActivityError?, sleeps: [TimeInterval], probes: Int, socketProbes: Int) {
        var probes = 0
        var socketProbes = 0
        var sleeps: [TimeInterval] = []
        var error: VPhoneBundleActivityError?
        do {
            try VPhoneBundleActivity.requireStopped(
                name: "tpl",
                waitingForReaders: wait,
                holders: {
                    defer { probes += 1 }
                    return answers[min(probes, answers.count - 1)]
                },
                socketIsLive: {
                    socketProbes += 1
                    return socketIsLive
                },
                sleep: { sleeps.append($0) },
            )
        } catch let refusal as VPhoneBundleActivityError {
            error = refusal
        } catch {
            Issue.record(error)
        }
        return (error, sleeps, probes, socketProbes)
    }

    @Test func `a reader that closes within the wait lets a clone through`() {
        let found = decide(wait: 2, [[Self.meter], [Self.meter], []])
        #expect(found.error == nil)
        #expect(found.sleeps == [0.1, 0.1])
        #expect(found.probes == 3)
    }

    @Test func `a reader that stays refuses once the wait is over`() {
        let found = decide(wait: 2, [[Self.meter]])
        #expect(found.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter]))
        // 20 waits of 0.1 s, 21 probes: about 2 s, not more.
        #expect(found.sleeps.count == 20)
        #expect(found.probes == 21)
    }

    @Test func `a VM holding the files refuses at once, with or without readers`() {
        for holders in [[Self.vm], [Self.service], [Self.meter, Self.service]] {
            let found = decide(wait: 2, [holders, []])
            #expect(found.error == VPhoneBundleActivityError.running(name: "tpl", holders: holders))
            #expect(found.sleeps.isEmpty)
        }
        // A VM that starts during the wait refuses on the next probe.
        let starting = decide(wait: 2, [[Self.meter], [Self.meter, Self.vm], []])
        #expect(starting.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter, Self.vm]))
        #expect(starting.sleeps.count == 1)
    }

    @Test func `a live control socket refuses at once`() {
        let held = decide(wait: 2, [[Self.meter], []], socketIsLive: true)
        #expect(held.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter]))
        #expect(held.sleeps.isEmpty)
        let free = decide(wait: 2, [[]], socketIsLive: true)
        #expect(free.error == VPhoneBundleActivityError.running(name: "tpl", holders: []))
    }

    @Test func `without a wait any holder refuses as before`() {
        let found = decide(wait: 0, [[Self.meter], []])
        #expect(found.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter]))
        #expect(found.sleeps.isEmpty)
        #expect(found.socketProbes == 0)
        #expect(decide(wait: 0, [[]]).error == nil)
    }

    @Test func `a held state file is waited for and then refused`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = open(bundle.url.appendingPathComponent("Disk.img").path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let began = Date()
        #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])) {
            try VPhoneBundleActivity.requireStopped(bundle, waitingForReaders: 0.3)
        }
        #expect(Date().timeIntervalSince(began) >= 0.25)
    }

    @Test func `a control socket path that is not a socket counts as stopped`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: bundle.url.appendingPathComponent("vphone.sock"))
        #expect(!isRunning(bundle))
    }

    // MARK: - Waiting for the machine to release its files (vm stop)

    /// `Self.service` or `Self.vm` with another PID.
    private func holder(_ pid: pid_t, _ like: VPhoneProcessHolder) -> VPhoneProcessHolder {
        VPhoneProcessHolder(pid: pid, executablePath: like.executablePath)
    }

    /// Runs `confirmStopped` over `holders` and `socket` (one answer per
    /// probe, the last repeats), with a counting fake sleep, and returns the
    /// result with how many times it slept and probed the holders.
    private func confirm(
        maxSleeps: Int,
        _ holders: [[VPhoneProcessHolder]],
        socket: [Bool] = [false],
    ) -> (message: String, isError: Bool, sleeps: Int, probes: Int) {
        var probes = 0
        var socketProbes = 0
        var sleeps = 0
        let r = VPhoneBundleActivity.confirmStopped(
            name: "m",
            maxSleeps: maxSleeps,
            interval: 0.1,
            holders: {
                defer { probes += 1 }
                return holders[min(probes, holders.count - 1)]
            },
            socketIsLive: {
                defer { socketProbes += 1 }
                return socket[min(socketProbes, socket.count - 1)]
            },
            sleep: { _ in sleeps += 1 },
        )
        return (r.message, r.isError, sleeps, probes)
    }

    @Test func `vm stop waits for a VM service holder that outlives vphone-vm, then reports stopped`() {
        // vphone-vm quit on SIGINT; the VM service, never signalled, still
        // holds SEPStorage or nvram.bin for two probes.
        let svc = holder(410, Self.service)
        let r = confirm(maxSleeps: 30, [[svc], [svc], []])
        #expect(r.message == "m: stopped")
        #expect(!r.isError)
        #expect(r.sleeps == 2)
        #expect(r.probes == 3)
    }

    @Test func `vm stop that cannot free the files exits non-zero naming them`() {
        let r = confirm(maxSleeps: 4, [[holder(410, Self.service)]])
        #expect(r.message == "m: could not stop; still held by 410 com.apple.Virtualization.VirtualMachine")
        #expect(r.isError)
        #expect(r.sleeps == 4)
        #expect(r.probes == 5)
    }

    @Test func `vm stop does not wait on or fail for a holder that does not run a machine`() {
        let r = confirm(maxSleeps: 30, [[VPhoneProcessHolder(pid: 999, executablePath: "/usr/bin/backupd")]])
        #expect(r.message == "m: stopped")
        #expect(!r.isError)
        #expect(r.sleeps == 0)
        #expect(r.probes == 1)
    }

    @Test func `vm stop names what is left in PID order`() {
        let r = confirm(maxSleeps: 1, [[holder(4242, Self.service), holder(101, Self.vm)]])
        #expect(r.message == "m: could not stop; still held by 101 vphone-vm, 4242 com.apple.Virtualization.VirtualMachine")
        #expect(r.isError)
    }

    @Test func `vm stop names a vphone-vm found both ways once`() {
        let r = confirm(maxSleeps: 1, [[holder(101, Self.vm), holder(101, Self.vm)]])
        #expect(r.message == "m: could not stop; still held by 101 vphone-vm")
        #expect(r.isError)
    }

    @Test func `vm stop waits for vphone-vm to close its control socket`() {
        // No process holds the files, but vphone.sock still answers for two
        // probes.
        let r = confirm(maxSleeps: 30, [[]], socket: [true, true, false])
        #expect(r.message == "m: stopped")
        #expect(!r.isError)
        #expect(r.sleeps == 2)
    }

    @Test func `vm stop with a control socket that stays live exits non-zero`() {
        let r = confirm(maxSleeps: 3, [[]], socket: [true])
        #expect(r.message == "m: could not stop; its control socket is still live")
        #expect(r.isError)
        #expect(r.sleeps == 3)
    }

    @Test func `vm stop on a bundle probes its control socket and its vphone-vm`() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        // This process holds a state file but runs no machine: never waited on.
        let fd = open(bundle.url.appendingPathComponent("Disk.img").path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let confirm = { VPhoneBundleActivity.confirmStopped(bundle, maxSleeps: 0, interval: 0.1) }
        #expect(confirm() == (message: "vm: stopped", isError: false))

        let (listener, _) = try listenAtControlSocket(of: bundle)
        #expect(confirm() == (message: "vm: could not stop; its control socket is still live", isError: true))
        close(listener)
        #expect(confirm() == (message: "vm: stopped", isError: false))

        // A vphone-vm of this machine's config that holds none of its files.
        let program = root.appendingPathComponent("vphone-vm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: program)
        let process = Process()
        process.executableURL = program
        // cat reads "-" first and blocks on a pipe that is never written to.
        process.arguments = ["-", "--config", bundle.configURL.path]
        process.standardInput = Pipe()
        try process.run()
        defer { process.terminate() }
        let expected = "vm: could not stop; still held by \(process.processIdentifier) vphone-vm"
        // The stand-in takes a moment to become observable, and the first run
        // of a freshly copied executable can take over 5 s under full-suite
        // load: poll on a bounded deadline until it is named. A passing run
        // stops polling as soon as it is.
        let deadline = Date().addingTimeInterval(30)
        var r = confirm()
        while r.message != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            r = confirm()
        }
        #expect(r == (message: expected, isError: true))
    }
}
