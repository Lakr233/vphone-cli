import Foundation
import VPhoneCoreKit

// MARK: - Cryptexes

/// Builds a cryptex on the host and has a trusted darwinOS guest install it
/// (vphoned's `cryptex.*`, capability `cryptex`).
///
/// The cryptex is made with the macOS Security Research tools' cryptexctl, the
/// same program `fw patch` uses for the trust cache: a disk image of the folder,
/// then `cryptexctl.research create` for the vresearch101 board the guest boots
/// on. vphoned personalizes and installs it in the guest.
/// Research/Firmware/trusted_darwinos_cryptexes.md has the details.
enum VPhoneCryptexBuilder {
    static let cryptexctl = URL(fileURLWithPath: "/System/Library/SecurityResearch/usr/bin/cryptexctl.research")
    /// Where cryptexes are mounted in the guest: each at
    /// `<mountRoot>/<identifier>`. The kernel's sandbox platform profile lets
    /// cryptexd mount only at a fixed list of paths (`file-mount`; any other
    /// fails `hdi_mount` with EPERM). This one, the mount path of PCC's Debug
    /// Shell cryptex, is on it with its subpaths, and vphone installs no PCC
    /// cryptex of its own there. cryptexd creates the last component only,
    /// and a fresh guest has no such directory (iOS 26.5): the install
    /// creates it first.
    static let mountRoot = "/private/var/DarwinDataCenterSupportImage"

    static func mountPoint(for identifier: String) -> String {
        "\(mountRoot)/\(identifier)"
    }

    /// Whether `cryptexctl list` output shows a cryptex with `identifier`;
    /// identifiers are its unindented lines.
    static func isInstalled(_ identifier: String, listed: String) -> Bool {
        listed.split(whereSeparator: \.isNewline).contains { $0 == Substring(identifier) }
    }

    enum Error: Swift.Error, LocalizedError {
        case missingTool
        case toolFailed(String, String)
        case incompatible(String)
        case alreadyInstalled(String)

        var errorDescription: String? {
            switch self {
            case .missingTool:
                "\(VPhoneCryptexBuilder.cryptexctl.path) is missing. Install the Security Research tools (the PCC Virtual Research Environment), then try again."
            case let .toolFailed(tool, detail):
                "\(tool) failed: \(detail)"
            case let .incompatible(reason):
                reason
            case let .alreadyInstalled(identifier):
                "A cryptex named \(identifier) is installed already. Uninstall it first, or rename the folder."
            }
        }
    }

    /// A cryptex identifier from a folder name: letters, digits, dots and dashes.
    static func identifier(for folder: URL) -> String {
        let name = folder.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "com.vphone.cryptex" : cleaned
    }

    /// Build `<identifier>.cxbd` from the contents of `source` in a new
    /// temporary directory, which the caller removes.
    static func build(from source: URL, identifier: String, mountPoint: String) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: cryptexctl.path) else { throw Error.missingTool }
        let work = FileManager.default.temporaryDirectory.appending(path: "vphone-cryptex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let image = work.appending(path: "cryptex.dmg")
            try run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["create", "-quiet", "-srcfolder", source.path, image.path])
            try run(cryptexctl, [
                "create",
                "--output-directory=\(work.path)",
                "--restricted-exec-mode-default=both",
                "--identifier=\(identifier)",
                "--mount-point=\(mountPoint)",
                "--version=1",
                "--variant=\(identifier)",
                // vresearch101, the board the guest boots on.
                "--FCHP=0xff10", "--TYPE=0x3", "--STYP=0x1", "--CLAS=0xf2",
                "--NDOM=0x3", "--BORD=0x90", "--CHIP=0xfe01", "--SDOM=0x1",
                image.path,
            ])
            try? FileManager.default.removeItem(at: image)
            return work.appending(path: "\(identifier).cxbd")
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// The variant a `.cxbd` was created with, from its BuildManifest.
    static func variant(of bundle: URL) -> String? {
        guard let info = buildIdentity(of: bundle)?["Info"] as? [String: Any] else { return nil }
        return info["Variant"] as? String
    }

    /// Why the guest cannot install a `.cxbd` made elsewhere, or nil if it
    /// can. Trusted darwinOS installs Cryptex1 cryptexes (`Cryptex1,GenericDmg`
    /// and its siblings) personalized for the board it boots on. A Security
    /// Research Device cryptex (`cryptexctl create --research`: `CryptexDMG`,
    /// `LoadableTrustCache`, no board) is personalized through the AP ticket of
    /// an SRD iPhone instead, and the guest's cryptexd refuses it.
    static func incompatibility(of bundle: URL) -> String? {
        let name = bundle.lastPathComponent
        let rebuild = "Choose the folder with the files the cryptex holds instead (for a cryptex built by a Makefile, often build/<identifier>.root), and Install Cryptex… builds one for this guest."
        guard let identity = buildIdentity(of: bundle),
              let manifest = identity["Manifest"] as? [String: Any]
        else {
            return "\(name) has no readable Restore/BuildManifest.plist, so it is not a cryptex this guest can install. \(rebuild)"
        }
        guard manifest["Cryptex1,GenericDmg"] != nil else {
            let srd = manifest["CryptexDMG"] != nil
            return srd
                ? "\(name) is a Security Research Device cryptex (made with cryptexctl create --research). This guest installs only Cryptex1 cryptexes made for its own board, vresearch101. \(rebuild)"
                : "\(name) is not a Cryptex1 cryptex, the only kind this guest installs. \(rebuild)"
        }
        let board = number(identity["ApBoardID"])
        let chip = number(identity["ApChipID"])
        guard board == 0x90, chip == 0xFE01 else {
            let found = [("ApBoardID", board), ("ApChipID", chip)]
                .map { "\($0.0) \($0.1.map { String(format: "0x%X", $0) } ?? "missing")" }
                .joined(separator: ", ")
            return "\(name) was made for another board (\(found)). This guest boots on vresearch101 (ApBoardID 0x90, ApChipID 0xFE01). \(rebuild)"
        }
        return nil
    }

    private static func buildIdentity(of bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Restore/BuildManifest.plist")),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (manifest["BuildIdentities"] as? [[String: Any]])?.first
    }

    /// A manifest number: an integer, or a string such as "0x90".
    private static func number(_ value: Any?) -> UInt64? {
        if let value = value as? NSNumber { return value.uint64Value }
        guard let string = value as? String else { return nil }
        return string.lowercased().hasPrefix("0x") ? UInt64(string.dropFirst(2), radix: 16) : UInt64(string)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let result = try VPhoneProcessRunner.runCapturing(executable, arguments)
        guard result.succeeded else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.toolFailed(executable.lastPathComponent, detail)
        }
    }
}

extension VPhoneGuestControl {
    /// Install a cryptex: `source` is a folder to build one from, or a
    /// `.cxbd` made already. Returns what the guest's cryptexctl printed.
    func installCryptex(from source: URL, persist: Bool = false) async throws -> String {
        guard guestCapabilities.contains("cryptex") else {
            throw ControlError.unsupportedCapability("cryptex")
        }
        let prebuilt = source.pathExtension == "cxbd"
        if prebuilt, let reason = VPhoneCryptexBuilder.incompatibility(of: source) {
            throw VPhoneCryptexBuilder.Error.incompatible(reason)
        }
        let identifier = VPhoneCryptexBuilder.identifier(for: source)
        // A folder's cryptex is mounted at its own path; a .cxbd keeps the
        // one it was made with.
        let mountPoint = prebuilt ? nil : VPhoneCryptexBuilder.mountPoint(for: identifier)
        if !prebuilt, VPhoneCryptexBuilder.isInstalled(identifier, listed: try await listCryptexes()) {
            throw VPhoneCryptexBuilder.Error.alreadyInstalled(identifier)
        }
        let bundle = try await prebuilt ? source : Task.detached { [mountPoint] in
            try VPhoneCryptexBuilder.build(from: source, identifier: identifier, mountPoint: mountPoint!)
        }.value
        defer { if !prebuilt { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) } }

        let remoteDirectory = "\(GuestCryptexPaths.uploadDirectory)/\(UUID().uuidString)"
        let remoteBundle = "\(remoteDirectory)/\(bundle.lastPathComponent)"
        try await createDirectory(path: GuestCryptexPaths.uploadDirectory)
        if !prebuilt {
            try await createDirectory(path: VPhoneCryptexBuilder.mountRoot)
        }
        try await uploadTree(bundle, to: remoteBundle)
        defer { Task { try? await deleteFile(path: remoteDirectory) } }
        let result = try await call("cryptex.install", params: [
            "path": remoteBundle, "variant": VPhoneCryptexBuilder.variant(of: bundle) ?? identifier, "persist": persist,
        ])
        let output = (result["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty, let mountPoint {
            return "\(identifier), mounted at \(mountPoint)"
        }
        return output
    }

    func listCryptexes() async throws -> String {
        let result = try await call("cryptex.list")
        return result["output"] as? String ?? ""
    }

    func uninstallCryptex(identifier: String) async throws -> String {
        let result = try await call("cryptex.uninstall", params: ["identifier": identifier])
        return result["output"] as? String ?? ""
    }

    /// Recreate a local directory tree in the guest: a directory per
    /// directory, an upload per file.
    private func uploadTree(_ local: URL, to remote: String) async throws {
        try await createDirectory(path: remote)
        let entries = try FileManager.default.contentsOfDirectory(
            at: local, includingPropertiesForKeys: [.isDirectoryKey], options: [],
        )
        for entry in entries {
            let target = "\(remote)/\(entry.lastPathComponent)"
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try await uploadTree(entry, to: target)
            } else {
                try await uploadFile(path: target, data: Data(contentsOf: entry, options: .mappedIfSafe))
            }
        }
    }
}

/// vphoned's upload directory for `cryptex.install` (GuestCryptex.uploadDirectory).
enum GuestCryptexPaths {
    static let uploadDirectory = "/var/mobile/Documents/vphone-cryptexes"
}
