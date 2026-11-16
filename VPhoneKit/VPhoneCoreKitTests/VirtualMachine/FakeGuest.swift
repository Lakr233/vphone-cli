import Foundation
@testable import VPhoneCoreKit

/// A stand-in for `vphone-vm`: an executable `#!/bin/sh` script in a temp
/// directory that records its arguments and exits with a status read from a
/// file, plus a library with one bundle and a `VPhoneResources` holding a fake
/// `vphoned`.
final class FakeGuestVM {
    let root: URL
    let library: VPhoneLibrary
    let bundle: VPhoneBundle
    let resources: VPhoneResources
    /// The fake `vphone-vm`.
    let executable: URL
    /// One argument per line, written by the script.
    let argumentsFile: URL
    /// The exit status the script returns; read when it runs.
    let statusFile: URL
    let vphonedContents = Data("fake vphoned".utf8)
    /// The log a detached launch appends to, and where a script may record its PID.
    var logURL: URL { root.appendingPathComponent("guest.log") }
    var pidFile: URL { root.appendingPathComponent("guest.pid") }

    init(name: String = "vm") throws {
        let fm = FileManager.default
        // Under /tmp, so `vphone.sock` fits the 104 bytes of `sun_path`.
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("fg-" + UUID().uuidString.prefix(8))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        library = VPhoneLibrary(root: root.appendingPathComponent("machines"))
        bundle = try VPhoneBundleOperations.create(
            .init(name: name, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: library,
        )

        let base = root.appendingPathComponent("resources")
        let guestResources = base.appendingPathComponent("guest-resources")
        try fm.createDirectory(at: guestResources, withIntermediateDirectories: true)
        resources = VPhoneResources(base: base)
        for family: VPhoneGuestDevice.Family in [.iPhone, .appleTV, .watch, .vision] {
            try vphonedContents.write(to: guestResources.appendingPathComponent(VPhoneResources.vphonedName(for: family)))
        }

        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        executable = bin.appendingPathComponent("vphone-vm")
        argumentsFile = root.appendingPathComponent("arguments.txt")
        statusFile = root.appendingPathComponent("status.txt")
        try write(status: 0)
        try writeScript("""
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done > '\(argumentsFile.path)'
        exit "$(cat '\(statusFile.path)')"
        """)
    }

    func write(status: Int32) throws {
        try Data("\(status)\n".utf8).write(to: statusFile)
    }

    func writeScript(_ body: String) throws {
        try Data((body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    var planner: VPhoneGuestLaunchPlanner {
        VPhoneGuestLaunchPlanner(unchecked: executable)
    }

    var layout: VPhoneLaunchLayout {
        VPhoneLaunchLayout(resources: resources)
    }

    func launch(
        options: VPhoneVirtualMachineLaunch.Options = .init(),
        restoredCustomisedSystem: Bool = false,
    ) -> VPhoneVirtualMachineLaunch {
        VPhoneVirtualMachineLaunch(
            bundle: bundle,
            planner: planner,
            layout: layout,
            options: options,
            restoredCustomisedSystem: restoredCustomisedSystem,
        )
    }

    var recordedArguments: [String] {
        guard let text = try? String(contentsOf: argumentsFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    var stagedVphoned: URL {
        bundle.url.appendingPathComponent(".vphoned.signed")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Control socket

/// A listener on a bundle's `vphone.sock`, bound once `waitFor` exists (the
/// fake guest has started) so it never makes the bundle look running before
/// the launch. Answers `{"ok":true}` to a request, or reads it and stays
/// silent.
final class FakeControlSocket: @unchecked Sendable {
    enum Mode { case answer, silent }

    let path: String
    private let mode: Mode
    private let reply: String
    private let waitFor: URL?
    private var received: [Data] = []
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    private var held: [Int32] = []

    /// The request bytes of each client so far, in arrival order.
    var requests: [Data] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    init(bundle: VPhoneBundle, mode: Mode = .answer, reply: String = "{\"ok\":true}", waitFor: URL? = nil) {
        path = bundle.url.appendingPathComponent("vphone.sock").path
        self.mode = mode
        self.reply = reply
        self.waitFor = waitFor
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        lock.lock()
        stopped = true
        if fd >= 0 { close(fd); fd = -1 }
        for client in held { close(client) }
        held = []
        lock.unlock()
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        if let waitFor {
            while !FileManager.default.fileExists(atPath: waitFor.path) {
                if isStopped { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 4) == 0 else { return }
        lock.lock()
        if stopped { lock.unlock(); close(listener); return }
        fd = listener
        lock.unlock()
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &buffer, buffer.count)
            if count > 0 {
                lock.lock(); received.append(Data(buffer.prefix(count))); lock.unlock()
            }
            if mode == .answer, count > 0 {
                let line = Array((reply + "\n").utf8)
                _ = write(client, line, line.count)
            }
            if mode == .answer { close(client) } else { lock.lock(); held.append(client); lock.unlock() }
        }
    }
}
