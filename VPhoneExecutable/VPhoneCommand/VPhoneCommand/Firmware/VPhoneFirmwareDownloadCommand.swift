// VPhoneFirmwareDownloadCommand.swift — `fw urls` and `fw seal-tool`.
//
// The last two shapes `ipsw` was called in from scripts/fw_prepare.sh:
//
//     ipsw download ipsw --device D --urls        ->  vphone-cli fw urls --device D
//     ipsw download appledb --os macOS … +
//       ipsw img4 im4p extract + diskutil          ->  vphone-cli fw seal-tool
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
import VPhoneCommandKit
import VPhoneCoreKit

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
        26.1" means "the one in macOS 26.1"; iOS 18.x.y goes with macOS 15.x.y.
        Without an exact match, the newest macOS of that major below it is
        taken.

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
        try VPhoneSealTool.stage(version: version, into: output)
    }
}
