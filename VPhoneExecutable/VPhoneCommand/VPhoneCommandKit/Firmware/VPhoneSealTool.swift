import ArgumentParser
import FirmwarePatcher
import Foundation
import Img4tool
import VPhoneCoreKit

// MARK: - VPhoneSealTool

/// Stages `apfs_sealvolume` for an OS version out of the matching macOS
/// restore ramdisk. `fw seal-tool` and `fw prepare` both call it.
public enum VPhoneSealTool {
    /// Write `apfs_sealvolume_<version>` into `output` unless it is already
    /// there. `fw prepare` stages it into the restore tree for the restore
    /// image patches, which seal the merged system with it.
    public static func stage(version: String, into output: URL) throws {
        guard !version.isEmpty, version.count < 32,
              version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            throw ValidationError("Invalid OS version for the seal tool.")
        }
        let destination = output.appendingPathComponent("apfs_sealvolume_\(version)")
        if FileManager.default.fileExists(atPath: destination.path) {
            print("apfs_sealvolume_\(version) already present")
            return
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let ramdisk = try vphoneRunBlocking { try await Self.fetchRamdisk(version: version, in: output) }
        var attached = false
        defer {
            if attached {
                fputs("warning: restore ramdisk is still mounted; left it at \(ramdisk.path)\n", stderr)
            } else {
                try? FileManager.default.removeItem(at: ramdisk.deletingLastPathComponent())
            }
        }

        try Self.copyOut(of: ramdisk, to: destination, attached: &attached)
        // Lifted out of someone else's signed image; re-seal it so the kernel
        // will exec it here.
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", destination.path])
        try VPhoneHostFilePermissions.makeAccessible(at: destination)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: output)
        print("  Downloaded: \(destination.path)")
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: tool), args)
        guard result.succeeded else {
            throw VPhoneRemoteZip.Error.malformed(
                "\(tool) exited \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
            )
        }
        return result.stdout
    }

    /// Resolve the macOS release, then take BuildManifest.plist and the restore
    /// ramdisk out of its IPSW without downloading the IPSW.
    private static func fetchRamdisk(version: String, in output: URL) async throws -> URL {
        let release = try await VPhoneFirmwareIndex.sealToolRelease(forOSVersion: version)
        // The catalog supplies discovery metadata, not executable trust.
        // A privileged seal tool must come directly from Apple's restore CDN.
        guard isAppleHost(release.url) else {
            throw ValidationError("The seal tool restore image must come from Apple's HTTPS CDN.")
        }
        print("  macOS \(release.version) (\(release.build))")

        let zip = try await VPhoneRemoteZip.open(release.url)
        let manifestEntry = try zip.entry(endingWith: "BuildManifest.plist")
        let manifestData = try await zip.read(manifestEntry)

        guard let manifest = try PropertyListSerialization.propertyList(
            from: manifestData,
            format: nil,
        ) as? [String: Any],
            let identities = manifest["BuildIdentities"] as? [[String: Any]]
        else {
            throw VPhoneRemoteZip.Error.malformed(
                "\(manifestEntry.name) (\(manifestData.count) bytes) has no BuildIdentities",
            )
        }
        // Any identity will do — every one of them names the same restore
        // ramdisk — but not all of them carry the key, so this takes the first
        // that does rather than assuming identity 0.
        guard let path = identities.lazy.compactMap({ identity -> String? in
            (((identity["Manifest"] as? [String: Any])?["RestoreRamDisk"]
                    as? [String: Any])?["Info"] as? [String: Any])?["Path"] as? String
        }).first else {
            throw VPhoneRemoteZip.Error.malformed(
                "none of \(identities.count) build identities names a RestoreRamDisk",
            )
        }
        print("  ramdisk: \(path)")

        let im4p = try await zip.read(zip.entry(endingWith: path))
        let work = output.appendingPathComponent(".vphone-sealtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let dmg = work.appendingPathComponent("ramdisk.dmg")
        do {
            try IM4P(im4p).payload().write(to: dmg)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        return dmg
    }

    /// Mount the ramdisk read-only and take the one file out of it.
    static func copyOut(of dmg: URL, to destination: URL, attached: inout Bool) throws {
        let output = try run("/usr/sbin/diskutil",
                             ["image", "attach", "-readOnly", "-nobrowse", dmg.path])
        attached = true
        let entities = output.split(whereSeparator: \.isNewline).compactMap { line -> (device: String, mount: String?)? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let device = fields.first, device.hasPrefix("/dev/disk") else { return nil }
            let mount = fields.count > 2 && fields[2].hasPrefix("/") ? fields[2] : nil
            return (device, mount)
        }
        let mount = entities.compactMap(\.mount).first
        let device = entities.first?.device
        guard let target = device ?? mount else {
            throw VPhoneRemoteZip.Error.malformed("diskutil attached nothing that can be detached")
        }

        let copied: Result<Void, Swift.Error> = Result {
            guard let mount else {
                throw VPhoneRemoteZip.Error.malformed("diskutil attached nothing with a mount point")
            }
            let source = URL(fileURLWithPath: mount).appending(
                path: "System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_sealvolume",
            )
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: destination.path)
        }
        do {
            try run("/usr/sbin/diskutil", ["eject", target])
        } catch {
            try run("/usr/sbin/diskutil", ["unmountDisk", "force", target])
            try run("/usr/sbin/diskutil", ["eject", target])
        }
        attached = false
        try copied.get()
    }

    /// True for an https URL on one of Apple's restore CDN hosts, without
    /// credentials.
    static func isAppleHost(_ url: URL) -> Bool {
        let appleHosts = ["updates.cdn-apple.com", "updates-http.cdn-apple.com", "appldnld.apple.com", "swcdn.apple.com"]
        return url.scheme == "https" && appleHosts.contains(url.host ?? "")
            && url.user == nil && url.password == nil
    }
}
