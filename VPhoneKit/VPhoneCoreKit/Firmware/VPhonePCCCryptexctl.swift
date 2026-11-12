import Foundation

/// Stages cloudOS's `/usr/bin/cryptexctl` for a trusted darwinOS guest
/// (`filesystem-exp-trusted_darwinos`). iOS ships no cryptexctl; cloudOS's is an
/// iOS-platform binary, Apple ad hoc signed, with the cryptex and trust cache
/// entitlements its `personalize` and `install` need. The restore image adds it
/// to the merged system, whose trust cache scan then takes its cdhash. It is
/// never shipped in the bundle.
public enum VPhonePCCCryptexctl {
    public static let name = "cryptexctl"
    /// Where the guest finds it, as on cloudOS.
    public static let guestPath = "usr/bin/cryptexctl"

    public enum Error: Swift.Error, LocalizedError {
        case missingOSImage(URL)
        case toolFailed(String, String)
        case notFound(URL)

        public var errorDescription: String? {
            switch self {
            case let .missingOSImage(path):
                "The cloudOS restore tree at \(path.path) has no OS image to take cryptexctl from. Download the cloudOS firmware again and retry."
            case let .toolFailed(tool, detail):
                "\(tool) failed while staging cryptexctl: \(detail)"
            case let .notFound(path):
                "The cloudOS system at \(path.path) has no usr/bin/cryptexctl."
            }
        }
    }

    public static func staged(in restoreDirectory: URL) -> URL {
        restoreDirectory.appending(path: ".pcc-cryptexctl/\(name)")
    }

    /// Decrypt the cloudOS OS image, copy cryptexctl out of it into
    /// `restoreDirectory`, and remove the decrypted image again.
    public static func stage(cloudOSDirectory: URL, into restoreDirectory: URL) throws {
        let fm = FileManager.default
        let image = try osImage(in: cloudOSDirectory)
        let work = restoreDirectory.deletingLastPathComponent()
            .appending(path: ".pcc-cryptexctl-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work) }

        var disk = image
        if image.pathExtension == "aea" {
            disk = work.appending(path: image.deletingPathExtension().lastPathComponent)
            let key = try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: image) }
            try run("/usr/bin/aea", ["decrypt", "-i", image.path, "-o", disk.path, "-key-value", key])
        }

        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, disk.path,
        ])
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", mount.path])) == nil {
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            }
        }

        let source = mount.appending(path: guestPath)
        guard fm.fileExists(atPath: source.path) else { throw Error.notFound(mount) }
        let destination = staged(in: restoreDirectory)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        print("[+] cryptexctl staged: \(destination.path)")
    }

    /// Stage a cryptexctl taken from this cloudOS build before.
    public static func stage(file: URL, into restoreDirectory: URL) throws {
        let fm = FileManager.default
        let destination = staged(in: restoreDirectory)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: file, to: destination)
    }

    /// The OS image the cloudOS research identity restores.
    static func osImage(in cloudOSDirectory: URL) throws -> URL {
        let manifestURL = cloudOSDirectory.appending(path: "BuildManifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identities = manifest["BuildIdentities"] as? [[String: Any]]
        else { throw Error.missingOSImage(cloudOSDirectory) }
        for identity in identities {
            guard let components = identity["Manifest"] as? [String: Any],
                  let os = components["OS"] as? [String: Any],
                  let info = os["Info"] as? [String: Any],
                  let path = info["Path"] as? String,
                  !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..")
            else { continue }
            let url = cloudOSDirectory.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw Error.missingOSImage(cloudOSDirectory)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: executable), arguments)
        guard result.succeeded else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.toolFailed(URL(fileURLWithPath: executable).lastPathComponent, detail)
        }
    }
}
