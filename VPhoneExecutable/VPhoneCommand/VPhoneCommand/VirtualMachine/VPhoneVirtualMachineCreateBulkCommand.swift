import ArgumentParser
import Foundation
import VPhoneCoreKit

struct VPhoneVirtualMachineCreateBulkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-bulk",
        abstract: "Create every VM a machine list plist describes",
        discussion: """
        The plist holds version (1), defaults and machines. Each machine is a \
        dictionary with a name; every other key is a vm create option's long \
        name without the dashes, with the value it takes: a string or integer, \
        true for a flag, an array for keep-apps. A machine's keys override \
        defaults; false leaves an option unset, so it clears a default.

        A relative path (library-root, iphone-source, cloudos-source, \
        gpu-driver-bundle, ipsw-cache, ota-source, a preset file) resolves \
        against the plist's folder. -l on the command line overrides \
        library-root.

        Each machine names its firmware (iphone-version, iphone-build, or \
        iphone-source with cloudos-source) or a template, so nothing prompts. \
        Every machine is checked as vm create checks it before the first is \
        made. A name that exists already is an error. --skip-existing skips \
        it, so a run that stopped can be run again for the rest; \
        --force-override deletes that VM just before its machine is created, \
        and refuses a running one. \
        Machines are created in order, as vm create creates them, so machines \
        with the same template key clone the template the first built. The \
        first failure stops the run.

        Run it with sudo when a machine needs a build: as vm create, cfw \
        install needs root.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "Machine list plist") var file: String
    @Flag(help: "Print each machine's vm create arguments; create nothing") var dryRun = false
    @Flag(help: "Skip a machine whose name exists") var skipExisting = false
    @Flag(help: "Delete an existing VM with a machine's name and create it again") var forceOverride = false
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func validate() throws {
        if skipExisting, forceOverride {
            throw ValidationError("--skip-existing and --force-override exclude each other.")
        }
    }

    func run() throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL
        let list = try VPhoneMachineList(
            data: VPhoneInvokingUserFile.read(url, kind: "machine list"),
            folder: url.deletingLastPathComponent(),
        )

        var problems: [String] = []
        var planned: [(name: String, arguments: [String], library: VPhoneLibrary, replaces: Bool)] = []
        var skipped: [String] = []
        for machine in list.machines {
            do {
                try VPhoneBundleOperations.requireValidName(machine.name)
                var keys = machine.keys
                // -l on the command line wins over the list's library-root.
                if let root = lib.libraryRoot {
                    keys["library-root"] = URL(fileURLWithPath: root).standardizedFileURL.path
                }
                let arguments = try [machine.name] + VPhoneMachineList.options(keys, folder: list.folder)
                    + Array(repeating: "-v", count: verboseCount)
                let command = try VPhoneVirtualMachineCreateCommand.parse(arguments)
                let library = command.lib.library
                let replaces = FileManager.default.fileExists(atPath: library.url(forName: machine.name).path)
                if replaces, skipExisting {
                    skipped.append(machine.name)
                    continue
                }
                if replaces {
                    guard forceOverride else {
                        throw ValidationError("exists already (--skip-existing skips it, --force-override replaces it)")
                    }
                    try Self.requireReplaceable(machine.name, in: library)
                }
                _ = try command.checkOptions()
                planned.append((machine.name, arguments, library, replaces))
            } catch {
                problems.append("\(machine.name): \(VPhoneVirtualMachineCreateCommand.message(for: error))")
            }
        }
        guard problems.isEmpty else {
            throw ValidationError(problems.joined(separator: "\n"))
        }

        for name in skipped {
            print("[-] \(name): exists, skipped")
        }

        if dryRun {
            for machine in planned {
                let replaces = machine.replaces ? " (replaces the existing VM)" : ""
                print("[+] \(machine.name)\(replaces): vphone-cli vm create \(machine.arguments.map(Self.quoted).joined(separator: " "))")
            }
            return
        }

        var created: [String] = []
        for (index, machine) in planned.enumerated() {
            print("\n=== [\(index + 1)/\(planned.count)] \(machine.name) ===")
            do {
                if machine.replaces {
                    try Self.requireReplaceable(machine.name, in: machine.library)
                    try VPhoneBundleOperations.delete(bundleNamed: machine.name, in: machine.library)
                    print("[-] Deleted the existing \(machine.name)")
                }
                let command = try VPhoneVirtualMachineCreateCommand.parse(machine.arguments)
                try command.run()
                created.append(machine.name)
            } catch {
                let remaining = planned.dropFirst(index + 1).map(\.name)
                print("\n[!] \(machine.name) failed. Created: \(Self.names(created)). Not started: \(Self.names(remaining)).")
                if FileManager.default.fileExists(atPath: machine.library.url(forName: machine.name).path) {
                    print("[!] \(machine.name) was left as it stopped. Delete it before running again with --skip-existing, or it is skipped.")
                } else {
                    print("[!] Run again with --skip-existing to create the rest.")
                }
                throw error
            }
        }
        print("\n[+] Created: \(Self.names(created))")
    }

    /// Only a stopped VM is deleted; a folder that is not a VM never is.
    private static func requireReplaceable(_ name: String, in library: VPhoneLibrary) throws {
        let bundle: VPhoneBundle
        do {
            bundle = try library.bundle(named: name)
        } catch VPhoneLibraryError.notFound {
            throw ValidationError("\(library.url(forName: name).path) exists but is not a VM; --force-override deletes only a VM.")
        }
        try VPhoneBundleActivity.requireStopped(bundle)
    }

    private static func names(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=,:+@%"))
        guard !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) else {
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return argument
    }
}

// MARK: - Machine List

/// A `create-bulk` plist: each machine's vm create options, defaults merged in.
struct VPhoneMachineList {
    struct Machine {
        var name: String
        /// vm create options by long name, defaults merged in.
        var keys: [String: Any]
    }

    static let version = 1
    /// Options whose relative paths resolve against the plist's folder.
    static let pathOptions: Set = ["library-root", "iphone-source", "cloudos-source", "gpu-driver-bundle", "ipsw-cache", "ota-source"]
    /// Options vm create takes more than once.
    static let repeatedOptions: Set = ["keep-apps"]
    /// Set on create-bulk's command line, not per machine.
    static let commandLineOptions: Set = ["v", "help"]

    var machines: [Machine]
    /// The folder relative paths resolve against.
    var folder: URL

    init(data: Data, folder: URL) throws {
        self.folder = folder
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ValidationError("The machine list is not a property list: \(error.localizedDescription)")
        }
        guard let root = plist as? [String: Any] else {
            throw ValidationError("The machine list is not a dictionary.")
        }
        if let unknown = Set(root.keys).subtracting(["version", "defaults", "machines"]).sorted().first {
            throw ValidationError("The machine list has an unknown key '\(unknown)'; it holds version, defaults and machines.")
        }
        guard Self.isInteger(root["version"]), (root["version"] as? Int) == Self.version else {
            throw ValidationError("The machine list needs version \(Self.version).")
        }
        guard let defaults = (root["defaults"] ?? [String: Any]()) as? [String: Any] else {
            throw ValidationError("defaults is not a dictionary.")
        }
        if defaults["name"] != nil {
            throw ValidationError("defaults cannot set a name.")
        }
        guard let entries = root["machines"] as? [Any], !entries.isEmpty else {
            throw ValidationError("The machine list needs a machines array with at least one machine.")
        }

        var seen = Set<String>()
        machines = try entries.enumerated().map { index, entry in
            guard let entry = entry as? [String: Any] else {
                throw ValidationError("Machine \(index + 1) is not a dictionary.")
            }
            guard let name = entry["name"] as? String, !name.isEmpty else {
                throw ValidationError("Machine \(index + 1) has no name.")
            }
            guard seen.insert(name).inserted else {
                throw ValidationError("The machine list names \(name) twice.")
            }
            var keys = defaults.merging(entry) { _, machine in machine }
            keys["name"] = nil
            return Machine(name: name, keys: keys)
        }
    }

    /// `keys` as vm create arguments, in key order.
    static func options(_ keys: [String: Any], folder: URL) throws -> [String] {
        let names = Set(keys.keys)
        if names.isDisjoint(with: ["template", "iphone-version", "iphone-build"]),
           !names.isSuperset(of: ["iphone-source", "cloudos-source"])
        {
            throw ValidationError("name its firmware (iphone-version, iphone-build, or iphone-source with cloudos-source) or a template.")
        }
        var arguments: [String] = []
        for key in keys.keys.sorted() {
            if commandLineOptions.contains(key) {
                throw ValidationError("\(key) is set on create-bulk's command line, not in the machine list.")
            }
            let values: [Any]
            if let array = keys[key] as? [Any] {
                guard repeatedOptions.contains(key) else {
                    throw ValidationError("\(key) takes one value, not an array.")
                }
                values = array
            } else {
                values = [keys[key] as Any]
            }
            for value in values {
                if isBoolean(value) {
                    if value as? Bool == true {
                        arguments.append("--\(key)")
                    }
                } else if isInteger(value), let number = value as? Int {
                    arguments.append("--\(key)=\(number)")
                } else if let text = value as? String {
                    arguments.append("--\(key)=\(resolved(text, key: key, folder: folder))")
                } else {
                    throw ValidationError("\(key) takes a string, an integer, true, or an array of them.")
                }
            }
        }
        return arguments
    }

    private static func resolved(_ value: String, key: String, folder: URL) -> String {
        let isPath = pathOptions.contains(key) || (key == "preset" && VPhonePatchPresetStore.isPresetFile(value))
        guard isPath, !value.contains("://") else {
            return value
        }
        // As the user's shell would have expanded it, before sudo.
        let path = if value == "~" || value.hasPrefix("~/"), let user = VPhoneInvokingUser.current {
            user.home.path + value.dropFirst()
        } else {
            (value as NSString).expandingTildeInPath
        }
        guard !path.hasPrefix("/") else {
            return path
        }
        return folder.appendingPathComponent(path).standardizedFileURL.path
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func isInteger(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, !isBoolean(value) else { return false }
        return !CFNumberIsFloatType(value)
    }
}
