import Foundation

// MARK: - Cryptexes

/// Cryptexes on a trusted darwinOS guest (`filesystem-exp-trusted_darwinos`),
/// through the cloudOS cryptexctl the restore image adds at /usr/bin. Only such
/// a guest has it, and only there does cryptexd accept a cryptex, so the
/// capability is the file's presence.
///
/// The host builds the cryptex (`cryptexctl.research create`, which needs the
/// macOS Security Research tools) and uploads its `.cxbd` directory; here it is
/// personalized for this guest by Apple's signing server (`--host-identity`) and
/// installed. Research/Firmware/trusted_darwinos_cryptexes.md has the flow.
enum GuestCryptex {
    static let cryptexctl = "/usr/bin/cryptexctl"
    /// Where the host uploads a `.cxbd`. install accepts nothing outside it.
    static let uploadDirectory = "/var/mobile/Documents/vphone-cryptexes"
    /// Personalization asks Apple's signing server; give it time.
    static let timeout: Double = 100
    /// Cryptexes installed with `persist`, one directory per identifier:
    /// the uploaded `.cxbd`, its personalized copy and `record.plist`.
    static let persistDirectory = "/var/db/vphoned/cryptexes"
    /// Every cryptexctl run goes through this queue, one at a time. Two
    /// installs that overlap can panic TXM: cryptexd's own `--persist`
    /// reinstalls in parallel at boot and did (`0xF3 | 4`, 3 of 12 boots with
    /// two cryptexes), so vphoned keeps the cryptexes itself and installs them
    /// again in turn. Research/Firmware/trusted_darwinos_cryptexes.md.
    static let queue = DispatchQueue(label: "vphoned.cryptex")

    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: cryptexctl)
    }

    static var capabilities: [String] {
        available ? ["cryptex"] : []
    }
}

enum CryptexMethod: String, GuestMethod {
    case cryptexList = "cryptex.list"
    case cryptexInstall = "cryptex.install"
    case cryptexUninstall = "cryptex.uninstall"

    var spec: MethodSpec {
        switch self {
        case .cryptexList: MethodSpec(summary: "List installed cryptexes and those vphoned installs again after a reboot; trusted darwinOS guests only.", result: [.required("output", .string), .required("persisted", .array)])
        case .cryptexInstall: MethodSpec(.required("path", .string, "Guest path of an uploaded .cxbd directory under /var/mobile/Documents/vphone-cryptexes"),
                                         .required("variant", .string, "The cryptex variant it was created with"),
                                         .optional("persist", .boolean, "Have vphoned install it again each time it starts after a reboot", default: false),
                                         summary: "Personalize an uploaded .cxbd with Apple's signing server and install it; trusted darwinOS guests only.",
                                         result: [.required("personalized", .string), .required("output", .string)])
        case .cryptexUninstall: MethodSpec(.required("identifier", .string, "Identifier of an installed cryptex, as cryptex.list shows it"),
                                           summary: "Uninstall a cryptex; trusted darwinOS guests only (capability cryptex).",
                                           result: [.required("output", .string)])
        }
    }
}

extension GuestAPI {
    static func executeCryptex(_ m: CryptexMethod, _ params: [String: Any]) throws -> [String: Any] {
        guard GuestCryptex.available else {
            throw GuestAPIError.operationFailed("This guest has no \(GuestCryptex.cryptexctl): restore it with the Trusted darwinOS environment (filesystem-exp-trusted_darwinos) on.")
        }
        switch m {
        case .cryptexList:
            return try GuestCryptex.queue.sync {
                ["output": try runCryptexctl(["list"]), "persisted": persistedCryptexes().map(\.identifier)]
            }
        case .cryptexInstall:
            let bundle = try cryptexBundle(try string(params, "path"))
            let variant = try string(params, "variant")
            let persist = params["persist"] as? Bool ?? false
            return try GuestCryptex.queue.sync {
                let signed = try personalizeCryptex(bundle, variant: variant)
                // Never cryptexctl's --persist; see GuestCryptex.queue.
                let output = try runCryptexctl(["install", "--variant", variant, "--print-info", signed.path])
                if persist { try keepCryptex(bundle: bundle, signed: signed, variant: variant, output: output) }
                return ["personalized": signed.path, "output": output]
            }
        case .cryptexUninstall:
            let identifier = try string(params, "identifier")
            guard !identifier.isEmpty, !identifier.hasPrefix("-") else {
                throw GuestAPIError.invalidRequest("identifier must be a cryptex identifier")
            }
            return try GuestCryptex.queue.sync { try uninstallCryptex(identifier) }
        }
    }

    private static func uninstallCryptex(_ identifier: String) throws -> [String: Any] {
        // cryptexctl 26.5 exits 1 without a word after an uninstall that
        // worked; what `list` shows afterwards is the result.
        let output: String
        do {
            output = try runCryptexctl(["uninstall", identifier])
        } catch {
            if (try? runCryptexctl(["list"])).map({ isListed(identifier, in: $0) }) ?? true { throw error }
            output = ""
        }
        forgetCryptex(identifier)
        return ["output": output]
    }

    /// Whether `cryptexctl list` output names `identifier`: identifiers are its
    /// unindented lines.
    private static func isListed(_ identifier: String, in listed: String) -> Bool {
        listed.split(whereSeparator: \.isNewline).contains { $0 == Substring(identifier) }
    }

    // MARK: Persisted cryptexes

    private struct PersistedCryptex {
        let identifier: String
        let variant: String
        let directory: URL
        var bundle: URL { directory.appendingPathComponent("bundle.cxbd") }
    }

    private static func persistedCryptexes() -> [PersistedCryptex] {
        let root = URL(fileURLWithPath: GuestCryptex.persistDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        return names.compactMap { name in
            let directory = root.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent("record.plist").path),
                  let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  let identifier = record["identifier"], let variant = record["variant"]
            else { return nil }
            return PersistedCryptex(identifier: identifier, variant: variant, directory: directory)
        }
    }

    /// Keep an installed cryptex: its `.cxbd` to personalize again, and the
    /// personalized copy, which is tried first. `--print-info` starts with
    /// the identifier.
    private static func keepCryptex(bundle: URL, signed: URL, variant: String, output: String) throws {
        let identifier = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !identifier.isEmpty, !identifier.contains("/"), !identifier.hasPrefix(".") else {
            throw GuestAPIError.operationFailed("installed, but not kept: cryptexctl named no identifier")
        }
        let directory = URL(fileURLWithPath: GuestCryptex.persistDirectory).appendingPathComponent(identifier)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        let personalized = directory.appendingPathComponent("bundle.personalized")
        try fileManager.createDirectory(at: personalized, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundle, to: directory.appendingPathComponent("bundle.cxbd"))
        try fileManager.copyItem(at: signed, to: personalized.appendingPathComponent("bundle.cxbd.signed"))
        let record = try PropertyListSerialization.data(fromPropertyList: ["identifier": identifier, "variant": variant], format: .xml, options: 0)
        try record.write(to: directory.appendingPathComponent("record.plist"))
    }

    private static func forgetCryptex(_ identifier: String) {
        for cryptex in persistedCryptexes() where cryptex.identifier == identifier {
            try? FileManager.default.removeItem(at: cryptex.directory)
        }
    }

    /// At startup, install the kept cryptexes that are not mounted, one after
    /// another on GuestCryptex.queue: first with the personalized copy; if
    /// cryptexd refuses that ticket, personalized again, which needs the
    /// network, so it is retried for a few minutes.
    static func reinstallPersistedCryptexesOnStartup() {
        guard GuestCryptex.available else { return }
        GuestCryptex.queue.async {
            let kept = persistedCryptexes()
            guard !kept.isEmpty else { return }
            let listed = (try? runCryptexctl(["list"])) ?? ""
            for cryptex in kept where !isListed(cryptex.identifier, in: listed) {
                reinstall(cryptex)
            }
        }
    }

    private static func reinstall(_ cryptex: PersistedCryptex) {
        let signed = cryptex.directory.appendingPathComponent("bundle.personalized/bundle.cxbd.signed")
        do {
            _ = try runCryptexctl(["install", "--variant", cryptex.variant, "--print-info", signed.path])
            NSLog("vphoned: cryptex %@ installed again with its kept ticket", cryptex.identifier)
            return
        } catch {
            NSLog("vphoned: cryptex %@ kept ticket refused, personalizing again: %@", cryptex.identifier, "\(error)")
        }
        for attempt in 1 ... 8 {
            do {
                let fresh = try personalizeCryptex(cryptex.bundle, variant: cryptex.variant)
                _ = try runCryptexctl(["install", "--variant", cryptex.variant, "--print-info", fresh.path])
                if fresh.lastPathComponent != signed.lastPathComponent {
                    try? FileManager.default.removeItem(at: signed)
                    try? FileManager.default.moveItem(at: fresh, to: signed)
                }
                NSLog("vphoned: cryptex %@ personalized and installed again", cryptex.identifier)
                return
            } catch {
                NSLog("vphoned: cryptex %@ not installed again (try %d): %@", cryptex.identifier, attempt, "\(error)")
                Thread.sleep(forTimeInterval: 20)
            }
        }
    }

    /// A `.cxbd` directory inside the upload directory, symlinks resolved.
    private static func cryptexBundle(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: GuestCryptex.uploadDirectory).resolvingSymlinksInPath().path + "/"
        let bundle = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard bundle.path.hasPrefix(root), bundle.pathExtension == "cxbd",
              FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw GuestAPIError.invalidRequest("path must be a .cxbd directory under \(GuestCryptex.uploadDirectory)")
        }
        return bundle
    }

    /// `cryptexctl personalize` writes the personalized cryptex, under the
    /// same name, into its output directory.
    private static func personalizeCryptex(_ bundle: URL, variant: String) throws -> URL {
        let output = bundle.deletingLastPathComponent().appendingPathComponent(bundle.deletingPathExtension().lastPathComponent + ".personalized")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try runCryptexctl([
            "personalize", "--variant", variant, "--replace", "--host-identity",
            "--output-directory", output.path, bundle.path,
        ])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        guard let name = names.first(where: { $0.hasSuffix(".cxbd") }) ?? names.first else {
            throw GuestAPIError.operationFailed("cryptexctl personalize wrote nothing to \(output.path)")
        }
        return output.appendingPathComponent(name)
    }

    private static func runCryptexctl(_ arguments: [String]) throws -> String {
        let run = try runProgram(GuestCryptex.cryptexctl, arguments, timeout: GuestCryptex.timeout)
        let output = [run.stdout, run.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard run.exitCode == 0 else {
            let reason = run.timedOut ? "timed out" : run.signal.map { "killed by signal \($0)" } ?? "exited \(run.exitCode ?? -1)"
            throw GuestAPIError.operationFailed("cryptexctl \(arguments.first ?? "") \(reason): \(output)")
        }
        return output
    }
}
