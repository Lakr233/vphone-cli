// VPhoneFirmwareDownloadCLI.swift — `fw urls` and `fw seal-tool`.
//
// The last two shapes `ipsw` was called in from scripts/fw_prepare.sh:
//
//     ipsw download ipsw --device D --urls        ->  vphone-cli fw urls --device D
//     ipsw download appledb --os macOS … +
//       ipsw img4 im4p extract + hdiutil          ->  vphone-cli fw seal-tool
//
// The second was five steps in shell: resolve a macOS build for the iOS
// version, range-fetch BuildManifest.plist out of an 18 GB remote zip, read the
// restore ramdisk's path out of it, range-fetch that, unwrap the IM4P, mount
// the ramdisk and copy one binary out. All of it is here because the parts it
// needed — a remote zip reader, an IM4P unwrapper, an AppleDB client — are
// things the project now owns.

import ArgumentParser
import FirmwarePatcher
import Foundation
import Img4tool
import VPhoneCore

// MARK: - urls

struct VPhoneFirmwareURLsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "urls",
        abstract: "List downloadable restore URLs for a device (replaces `ipsw download ipsw --urls`)",
        discussion: """
        Reads Apple's own iTunes version plist — the document Finder consults to
        decide what it can restore a device to. One URL per line, which is what
        fw_prepare.sh feeds into DOWNLOADABLE_IPSW_URLS.
        """,
    )

    @Option(help: "Device identifier, e.g. iPhone17,3") var device: String

    func run() throws {
        let urls = try vphoneRunBlocking {
            try await VPhoneFirmwareIndex.restoreURLs(forDevice: device)
        }
        for url in urls {
            print(url)
        }
    }
}

// MARK: - seal-tool

struct VPhoneFirmwareSealToolCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seal-tool",
        abstract: "Fetch apfs_sealvolume for an OS version out of the matching macOS restore ramdisk",
        discussion: """
        `apfs_sealvolume` is what turns a rebuilt system volume into a sealed
        one, and it is not in an iPhone restore image — only in a macOS one. The
        two have shared a marketing version since 2025, so "the tool for iOS
        26.1" means "the one in macOS 26.1".

        The macOS IPSW is about 18 GB and two files in it are wanted, so nothing
        is downloaded whole: the archive is read over HTTP range requests, the
        same way `ipsw --pattern` read it. Expect a few megabytes of traffic.

        The result is ad-hoc signed before it is used, because a binary lifted
        out of a ramdisk carries a signature that does not validate once it is
        somewhere else.
        """,
    )

    @Option(help: "OS marketing version, e.g. 26.1") var version: String

    @Option(help: "Directory to write apfs_sealvolume_<version> into",
            transform: URL.init(fileURLWithPath:))
    var output: URL

    func run() throws {
        let destination = output.appendingPathComponent("apfs_sealvolume_\(version)")
        if FileManager.default.fileExists(atPath: destination.path) {
            print("apfs_sealvolume_\(version) already present")
            return
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let ramdisk = try vphoneRunBlocking { try await Self.fetchRamdisk(version: version) }
        defer { try? FileManager.default.removeItem(at: ramdisk.deletingLastPathComponent()) }

        try Self.copyOut(of: ramdisk, to: destination)
        // Lifted out of someone else's signed image; re-seal it so the kernel
        // will exec it here.
        try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", destination.path])
        print("  Downloaded: \(destination.path)")
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
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
    private static func fetchRamdisk(version: String) async throws -> URL {
        let release = try await VPhoneFirmwareIndex.macOSRelease(version: version)
        print("  macOS \(release.version) (\(release.build))")

        let zip = try await VPhoneRemoteZip.open(release.url)
        let manifestEntry = try zip.entry(endingWith: "BuildManifest.plist")
        let manifestData = try await zip.read(manifestEntry)

        guard let manifest = try PropertyListSerialization.propertyList(
            from: manifestData, format: nil,
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
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-sealtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("ramdisk.dmg")
        try IM4P(im4p).payload().write(to: dmg)
        return dmg
    }

    /// Mount the ramdisk read-only and take the one file out of it.
    private static func copyOut(of dmg: URL, to destination: URL) throws {
        let attached = try run("/usr/bin/hdiutil",
                               ["attach", "-readonly", "-nobrowse", "-plist", dmg.path])
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(attached.utf8), format: nil,
        ) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw VPhoneRemoteZip.Error.malformed("hdiutil attached nothing with a mount point") }
        defer { try? run("/usr/bin/hdiutil", ["detach", mount]) }

        let source = URL(fileURLWithPath: mount).appending(
            path: "System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_sealvolume",
        )
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: destination.path)
    }
}
