import Darwin
import Foundation

// MARK: - Socket

/// The local control channel between `vphone-launchpad-cli` and a running
/// Launchpad. The app listens on a Unix socket in its Application Support
/// folder, mode 0600, and serves only peers with its own user ID. Nothing
/// listens on the network: a remote agent reaches it over ssh.
///
/// One connection carries one request. The client writes the request as one
/// JSON line; the app answers with any number of `output` events, streamed
/// while the command runs, and ends with one `done` event. The client closing
/// its end cancels the command where the command supports it.
nonisolated enum VPhoneLaunchpadControl {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vphone-launchpad", isDirectory: true)
    }

    static var socketPath: String {
        directory.appendingPathComponent("control.sock").path
    }

    /// Requests are small; a guest request carries at most vphoned's own
    /// 1 MiB body limit.
    static let maximumRequestLength = 2 << 20

    /// Fills `address` with `path`, or returns false when it does not fit.
    static func address(_ path: String, into address: inout sockaddr_un) -> Bool {
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        return true
    }

    /// Writes all of `data`, retrying short writes. False once the peer is gone.
    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

// MARK: - Messages

nonisolated struct VPhoneLaunchpadControlRequest: Codable, Sendable {
    /// A command name from `VPhoneLaunchpadControlCommand.all`.
    var command: String
    var arguments: [String] = []
    /// Valued options by name; a flag that is set has the value "true".
    var options: [String: String] = [:]

    func option(_ name: String) -> String? {
        options[name]
    }

    func flag(_ name: String) -> Bool {
        options[name] == "true"
    }
}

/// One line from the app. `output` lines stream while a command runs; the
/// last line has `done` set, `ok`, and either a JSON `result` or an `error`.
nonisolated struct VPhoneLaunchpadControlEvent: Codable, Sendable {
    var output: String?
    var done: Bool?
    var ok: Bool?
    /// The command's result as a JSON document.
    var result: String?
    var error: String?
    var detail: String?

    static func line(_ text: String) -> Self {
        Self(output: text)
    }

    static func success(_ result: String) -> Self {
        Self(done: true, ok: true, result: result)
    }

    static func failure(_ message: String, detail: String? = nil) -> Self {
        Self(done: true, ok: false, error: message, detail: detail)
    }

    func encodedLine() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data(#"{"done":true,"ok":false,"error":"unencodable event"}"#.utf8)
        data.append(0x0A)
        return data
    }
}

// MARK: - Commands

/// The commands both sides know. The CLI parses its arguments and prints
/// help from this table; the app dispatches on `name`.
nonisolated struct VPhoneLaunchpadControlCommand: Sendable {
    let name: String
    /// Positional arguments, in order. A trailing `...` takes the rest.
    let arguments: [String]
    /// Options that take a value.
    let options: [String]
    /// Options without a value.
    let flags: [String]
    let summary: String

    var usage: String {
        var parts = [name.replacingOccurrences(of: ".", with: " ")]
        parts += arguments.map { "<\($0)>" }
        parts += options.map { "[--\($0) <value>]" }
        parts += flags.map { "[--\($0)]" }
        return parts.joined(separator: " ")
    }

    var takesRest: Bool {
        arguments.last?.hasSuffix("...") == true
    }

    static let all: [Self] = [
        Self(name: "status", arguments: [], options: [], flags: [],
             summary: "Host checks, helper, active bundle and machine counts."),

        Self(name: "bundle.list", arguments: [], options: [], flags: [],
             summary: "Installed VPhone.bundle versions and their checks."),
        Self(name: "bundle.install-local", arguments: ["path"], options: [], flags: [],
             summary: "Install a VPhone.bundle folder or .zip built on this Mac as <version>-local, make it active and check it."),
        Self(name: "bundle.install-release", arguments: ["version"], options: [], flags: [],
             summary: "Download and install a GitHub release (a version, or \"latest\")."),
        Self(name: "bundle.use", arguments: ["version"], options: [], flags: [],
             summary: "Make an installed version active and check it."),
        Self(name: "bundle.verify", arguments: ["version"], options: [], flags: [],
             summary: "Add the execution policy exception, allow vphone-vm if AMFI refuses it, and run host preflight."),
        Self(name: "bundle.accept", arguments: ["version"], options: [], flags: ["off"],
             summary: "Use a version even though its checks failed (--off takes that back)."),
        Self(name: "bundle.remove", arguments: ["version"], options: [], flags: [],
             summary: "Remove an installed version."),

        Self(name: "vm.list", arguments: [], options: [], flags: [],
             summary: "Machines in every library, with their run state."),
        Self(name: "vm.start", arguments: ["name"], options: ["root", "timeout"], flags: ["headless", "wait"],
             summary: "Launch a machine. --wait blocks until vphoned answers on vphone.sock."),
        Self(name: "vm.stop", arguments: ["name"], options: ["root"], flags: [],
             summary: "Stop a machine."),
        Self(name: "vm.wait", arguments: ["name"], options: ["root", "timeout"], flags: [],
             summary: "Wait until vphoned answers on the machine's vphone.sock."),
        Self(name: "vm.log", arguments: ["name"], options: ["root", "lines", "kind"], flags: [],
             summary: "The last lines of the console log (--kind create, dfu or patch for those logs)."),
        Self(name: "vm.create", arguments: ["name"], options: [
            "root", "iphone-source", "cloudos-source", "cpu", "memory", "disk-size", "network", "preset", "from",
        ], flags: ["keep-artifacts", "no-wait"],
        summary: "Create a machine through every step, as New Machine does. --from <step> retries a failed creation from that step."),

        Self(name: "cfw.install", arguments: ["name"], options: ["root"], flags: ["keep-artifacts"],
             summary: "Install CFW into a stopped machine through the root helper."),

        Self(name: "guest.send", arguments: ["name", "json"], options: ["root"], flags: [],
             summary: "Send one raw vphone.sock request, such as {\"t\":\"tap\",\"x\":645,\"y\":1398}."),
        Self(name: "guest.rpc", arguments: ["name", "method", "params..."], options: ["root"], flags: ["screen"],
             summary: "Call a vphoned method; params is one JSON object."),

        Self(name: "exec", arguments: ["arguments..."], options: [], flags: [],
             summary: "Run the active bundle's vphone-cli with these arguments and stream its output."),
    ]

    static func named(_ name: String) -> Self? {
        all.first { $0.name == name }
    }
}
