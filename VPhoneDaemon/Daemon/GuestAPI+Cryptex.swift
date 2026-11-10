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
        case .cryptexList: MethodSpec(summary: "List the installed cryptexes with cryptexctl; trusted darwinOS guests only (capability cryptex).", result: [.required("output", .string)])
        case .cryptexInstall: MethodSpec(.required("path", .string, "Guest path of an uploaded .cxbd directory under /var/mobile/Documents/vphone-cryptexes"),
                                         .required("variant", .string, "The cryptex variant it was created with"),
                                         .optional("persist", .boolean, "Install it again after each reboot", default: false),
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
            return ["output": try runCryptexctl(["list"])]
        case .cryptexInstall:
            let bundle = try cryptexBundle(try string(params, "path"))
            let variant = try string(params, "variant")
            let persist = params["persist"] as? Bool ?? false
            let signed = try personalizeCryptex(bundle, variant: variant)
            var arguments = ["install", "--variant", variant, "--print-info"]
            if persist { arguments.append("--persist") }
            return ["personalized": signed.path, "output": try runCryptexctl(arguments + [signed.path])]
        case .cryptexUninstall:
            let identifier = try string(params, "identifier")
            guard !identifier.isEmpty, !identifier.hasPrefix("-") else {
                throw GuestAPIError.invalidRequest("identifier must be a cryptex identifier")
            }
            // cryptexctl 26.5 exits 1 without a word after an uninstall that
            // worked; what `list` shows afterwards is the result.
            do {
                return ["output": try runCryptexctl(["uninstall", identifier])]
            } catch {
                let installed = (try? runCryptexctl(["list"]))?
                    .split(whereSeparator: \.isNewline)
                    .contains { $0 == Substring(identifier) } ?? true
                if installed { throw error }
                return ["output": ""]
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
