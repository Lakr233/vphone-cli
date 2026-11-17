import Foundation

/// `vphone-launchpad-cli`'s command line, parsed into the request the
/// control socket carries.
@main
struct ControlTests {
    static func main() throws {
        try parsing()
        try repeatedOptions()
        try requestCoding()
        print("Control tests passed")
    }

    static func parse(_ words: [String]) throws -> (VPhoneLaunchpadControlRequest, foreground: Bool) {
        var foreground = false
        let request = try VPhoneLaunchpadControlRequest.parse(words, foreground: &foreground)
        return (request, foreground)
    }

    static func failure(_ words: [String]) -> VPhoneLaunchpadControlUsageError? {
        do {
            _ = try parse(words)
            return nil
        } catch {
            return error as? VPhoneLaunchpadControlUsageError
        }
    }

    // MARK: - Commands and options

    static func parsing() throws {
        let (start, foreground) = try parse(["vm", "start", "lab-01", "--headless", "--timeout=30", "--foreground"])
        precondition(start.command == "vm.start" && start.arguments == ["lab-01"], "Grouped command: \(start)")
        precondition(start.flag("headless") && start.option("timeout") == "30" && foreground, "Options: \(start)")
        precondition(start.repeated == nil, "No repeated options")

        let (exec, _) = try parse(["exec", "--bundle", "2.9.0", "vm", "list", "--json"])
        precondition(exec.option("bundle") == "2.9.0" && exec.arguments == ["vm", "list", "--json"], "exec: \(exec)")

        let (root, _) = try parse(["vm", "stop", "lab-01", "--root", "/tmp/a/../b"])
        precondition(root.option("root") == "/tmp/b", "Root standardized: \(String(describing: root.option("root")))")

        // The host side of a copy is resolved here; the guest side stays as typed.
        let cwd = FileManager.default.currentDirectoryPath
        let (push, _) = try parse(["guest", "push", "lab-01", "build/./tool", "/var/jb/usr/bin/", "--mode", "755"])
        precondition(push.command == "guest.push" && push.option("mode") == "755", "Push: \(push)")
        precondition(push.arguments == ["lab-01", URL(fileURLWithPath: cwd).appendingPathComponent("build/tool").path, "/var/jb/usr/bin/"], "Push paths: \(push.arguments)")
        let (pull, _) = try parse(["guest", "pull", "lab-01", "/var/mobile/a.log", "/tmp/x/../out"])
        precondition(pull.command == "guest.pull" && pull.arguments == ["lab-01", "/var/mobile/a.log", "/tmp/out"], "Pull paths: \(pull.arguments)")
        precondition(failure(["guest", "pull", "lab-01", "/a"])?.message == "wrong number of arguments.", "Pull needs a local path")
        precondition(failure(["guest", "pull", "lab-01", "/a", "/b", "--mode", "644"])?.message == "unknown option --mode.", "Pull has no mode")

        precondition(failure(["vm"])?.message == "vm needs a command.", "A group alone")
        precondition(failure(["vm", "start"])?.message == "wrong number of arguments.", "Missing name")
        precondition(failure(["vm", "start", "a", "--nope"])?.message == "unknown option --nope.", "Unknown option")
        precondition(failure(["vm", "log", "a", "--lines"])?.message == "--lines needs a value.", "Missing value")
        // Only vm create repeats --block.
        precondition(failure(["vm", "start", "a", "--block", "x"])?.message == "unknown option --block.", "Not repeatable elsewhere")
    }

    static func repeatedOptions() throws {
        let (create, _) = try parse([
            "vm", "create", "rt-e", "--preset", "standard",
            "--block", "system-debugserver-cfw-install", "--allow=kernel-exp-x", "--block", "ibss-cfw-serial_label",
        ])
        precondition(create.command == "vm.create" && create.arguments == ["rt-e"], "Create: \(create)")
        precondition(create.option("preset") == "standard", "Preset")
        precondition(create.values("block") == ["system-debugserver-cfw-install", "ibss-cfw-serial_label"], "Blocks in order: \(create.values("block"))")
        precondition(create.values("allow") == ["kernel-exp-x"], "Allows: \(create.values("allow"))")
        precondition(create.option("block") == nil, "A repeated option is not a single one")
        precondition(failure(["vm", "create", "a", "--block"])?.message == "--block needs a value.", "Block needs a value")

        let usage = try require(VPhoneLaunchpadControlCommand.named("vm.create")).usage
        precondition(usage.contains("[--block <value>]...") && usage.contains("[--allow <value>]..."), usage)

        // The ssh builder of bundles up to 2.17 is gone.
        precondition(failure(["vm", "create", "xs", "--kmutil-ssh", "test@host"])?.message == "unknown option --kmutil-ssh.", "No ssh builder")
    }

    /// A request from a CLI without repeated options still decodes, and
    /// the values survive the socket.
    static func requestCoding() throws {
        let old = try JSONDecoder().decode(VPhoneLaunchpadControlRequest.self, from: Data(#"{"command":"vm.create","arguments":["a"],"options":{"preset":"standard"}}"#.utf8))
        precondition(old.values("block").isEmpty && old.option("preset") == "standard", "Old request")

        let (create, _) = try parse(["vm", "create", "a", "--block", "x", "--block", "y"])
        let decoded = try JSONDecoder().decode(VPhoneLaunchpadControlRequest.self, from: JSONEncoder().encode(create))
        precondition(decoded.values("block") == ["x", "y"], "Round trip: \(decoded.values("block"))")
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            preconditionFailure("missing value")
        }
        return value
    }
}
