import Foundation

// MARK: - IPA Installer

/// Host-side IPA installer. Uses VPhoneSigner for re-signing,
/// ideviceinstaller for USB installation via usbmuxd.
@MainActor
class VPhoneIPAInstaller {
    let signer: VPhoneSigner
    private let ideviceInstallerURL: URL
    private let ideviceIdURL: URL

    init?(signer: VPhoneSigner, bundle: Bundle = .main) {
        guard let execURL = bundle.executableURL else { return nil }
        let macosDir = execURL.deletingLastPathComponent()

        ideviceInstallerURL = macosDir.appendingPathComponent("ideviceinstaller")
        ideviceIdURL = macosDir.appendingPathComponent("idevice_id")

        let fm = FileManager.default
        guard fm.fileExists(atPath: ideviceInstallerURL.path),
              fm.fileExists(atPath: ideviceIdURL.path)
        else { return nil }

        self.signer = signer
    }

    // MARK: - Install

    /// Install an IPA. If `resign` is true, re-sign all Mach-O binaries
    /// preserving their original entitlements before installing.
    func install(ipaURL: URL, resign: Bool) async throws {
        let udid = try await getUDID()
        print("[ipa] device UDID: \(udid)")

        var installURL = ipaURL
        var tempDir: URL?

        if resign {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("vphone-cli-resign-\(UUID().uuidString)")
            tempDir = dir
            installURL = try await resignIPA(ipaURL: ipaURL, tempDir: dir)
        }

        defer {
            if let tempDir {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        print("[ipa] installing \(installURL.lastPathComponent) to \(udid)...")
        let result = try await signer.run(
            ideviceInstallerURL,
            arguments: ["-u", udid, "install", installURL.path]
        )
        guard result.status == 0 else {
            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw IPAError.installFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        print("[ipa] installed successfully")
    }

    // MARK: - UDID Discovery

    private func getUDID() async throws -> String {
        let result = try await signer.run(ideviceIdURL, arguments: ["-l"])
        guard result.status == 0 else {
            throw IPAError.noDevice
        }
        let udids = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = udids.first else {
            throw IPAError.noDevice
        }
        return first
    }

    // MARK: - Re-sign IPA

    private func resignIPA(ipaURL: URL, tempDir: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Unzip
        print("[ipa] extracting \(ipaURL.lastPathComponent)...")
        let unzip = try await signer.run(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-o", ipaURL.path, "-d", tempDir.path]
        )
        guard unzip.status == 0 else {
            throw IPAError.extractFailed(unzip.stderr)
        }

        // Remove macOS resource fork files that break iOS installd
        _ = try? await signer.run(
            URL(fileURLWithPath: "/usr/bin/find"),
            arguments: [tempDir.path, "-name", "._*", "-delete"]
        )
        _ = try? await signer.run(
            URL(fileURLWithPath: "/usr/bin/find"),
            arguments: [tempDir.path, "-name", ".DS_Store", "-delete"]
        )

        // Find Payload/*.app
        let payloadDir = tempDir.appendingPathComponent("Payload")
        guard fm.fileExists(atPath: payloadDir.path) else {
            throw IPAError.invalidIPA("no Payload directory")
        }
        let contents = try fm.contentsOfDirectory(atPath: payloadDir.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw IPAError.invalidIPA("no .app bundle in Payload")
        }
        let appDir = payloadDir.appendingPathComponent(appName)

        // Walk and re-sign all Mach-O files
        let machoFiles = signer.findMachOFiles(in: appDir)
        print("[ipa] re-signing \(machoFiles.count) Mach-O binaries...")

        for file in machoFiles {
            do {
                try await signer.signFile(at: file, tempDir: tempDir)
            } catch {
                print("[ipa] warning: \(error)")
            }
        }

        // Re-zip (use zip from the temp dir so Payload/ is at the root)
        let outputIPA = tempDir.appendingPathComponent("resigned.ipa")
        print("[ipa] re-packaging...")
        let zip = try await signer.run(
            URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-r", "-y", outputIPA.path, "Payload"],
            currentDirectory: tempDir
        )
        guard zip.status == 0 else {
            throw IPAError.repackFailed(zip.stderr)
        }

        return outputIPA
    }

    // MARK: - Errors

    enum IPAError: Error, CustomStringConvertible {
        case noDevice
        case extractFailed(String)
        case invalidIPA(String)
        case repackFailed(String)
        case installFailed(String)

        var description: String {
            switch self {
            case .noDevice: "no device found (is the VM running?)"
            case let .extractFailed(msg): "failed to extract IPA: \(msg)"
            case let .invalidIPA(msg): "invalid IPA: \(msg)"
            case let .repackFailed(msg): "failed to repackage IPA: \(msg)"
            case let .installFailed(msg): "install failed: \(msg)"
            }
        }
    }
}
