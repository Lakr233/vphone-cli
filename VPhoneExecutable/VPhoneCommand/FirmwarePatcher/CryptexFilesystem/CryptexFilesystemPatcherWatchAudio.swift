// CryptexFilesystemPatcherWatchAudio.swift — The watch speaker payload, written before the seal.
//
// The virtio sound HAL plugin is retargeted to watchOS, the speaker tuning graphs are
// rebuilt through the generic DSP chain, and three VirtualAudio routing gates are
// addressed.
//
// Selected by `filesystem-exp-watch_audio`, which `applies(_:)` in CryptexFilesystemPatcher.swift
// gates to a watch guest. See Research/Guest/watch_audio.md.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit
import VPhoneSign

extension CryptexFilesystemPatcher {

    func addWatchAudio(targetMount: String) throws {
        // Routing uses the native watch product. See Research/Guest/watch_audio.md

        let name = "VPhoneVirtIOSound.driver"
        let relative = "System/Library/Audio/Plug-Ins/HAL/\(name)"

        let confined = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let source = try VPhoneConfinedDirectory.pin(absolutePath: VPhoneGuestBinaries.resolve(name).path)

        try confined.removeItem(relative)
        try confined.copyTree(from: source, to: relative, owner: (0, 0))

        let bundle = URL(filePath: targetMount).appending(path: relative)
        try deleteAppleDoubleFiles(under: bundle)

        let executable = bundle.appending(path: "VPhoneVirtIOSound")
        var data = try Data(contentsOf: executable)

        try MachOBuildPlatform.set(MachOBuildPlatform.watchOS, in: &data)
        try data.write(to: executable)
        try VPhoneSigner.sign(
            fileAt: executable,
            options: .init(identifier: nil, entitlements: nil, mergesExisting: true, style: .appleAdHoc),
        )

        let infoURL = bundle.appending(path: "Info.plist")
        guard var info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil,
        ) as? [String: Any] else {
            throw VPhonePatchKit.PatcherError.patchVerificationFailed(
                "The virtio sound driver has no valid bundle metadata.",
            )
        }

        info["CFBundleSupportedPlatforms"] = ["WatchOS"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)

        _ = try runProcess("/usr/bin/codesign", ["-f", "-s", "-", "--timestamp=none", bundle.path])
        try chownRecursively(uid: 0, gid: 0, at: bundle)

        for path in [bundle, bundle.appending(path: "/VPhoneVirtIOSound"), bundle.appending(path: "/_CodeSignature")] {
            try setMode(0o755, at: path)
        }

        for path in [bundle.appending(path: "/Info.plist"), bundle.appending(path: "/_CodeSignature/CodeResources")] {
            try setMode(0o644, at: path)
        }

        print("  [+] /\(relative)")

        try patchWatchAudioGraphs(targetMount: targetMount)
        try patchWatchAudioRoutingGates(targetMount: targetMount)
    }

    func patchWatchAudioRoutingGates(targetMount: String) throws {
        let relative = "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin"
        try editGuestFile("\(relative)/VirtualAudio", targetMount: targetMount, mode: 0o755) { file in
            try thinToArm64e(file)
            try CustomFirmwareVirtualAudio.patchSpeakerProtectionGate(
                fileAt: file, handler: .playback, reattest: false,
            )

            try CustomFirmwareVirtualAudio.patchVolumeModePrecondition(
                fileAt: file, reattest: false,
            )

            try CustomFirmwareVirtualAudio.patchInactiveSpeakerProtection(
                fileAt: file, reattest: false,
            )

            try VPhoneSigner.sign(fileAt: file, options: guestSigningOptions())
        }

        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let bundle = try target.directory(relative)
        _ = try runProcess("/usr/bin/codesign", [
            "-f", "-s", "-", "--timestamp=none", "--preserve-metadata=entitlements", bundle.path,
        ])
    }

    func patchWatchAudioGraphs(targetMount: String) throws {
        // The HAL speaker-protection chain requires a physical Speaker device
        // Keep the watch's DSP tunings, but construct them through the generic chain
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let tunings = try target.directory("Library/Audio/Tunings")

        var patched = 0
        for name in try tunings.entries().sorted() where name.hasPrefix("AID") {
            let relative = "Library/Audio/Tunings/\(name)/VAD/graph_configurations_halspp.plist"
            guard try target.exists(relative) else {
                continue
            }

            try editGuestFile(relative, targetMount: targetMount, mode: 0o644) { file in
                try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: file)
            }

            patched += 1
        }

        guard patched > 0 else {
            throw VPhonePatchKit.PatcherError.patchVerificationFailed(
                "Watch audio requires a HALSPP graph configuration in the image",
            )
        }
    }

    func patchWatchAudioBudget(targetMount: String) throws {
        let version = try getProductVersion()
        guard CustomFirmwareWatchAudioBudget.supports(VPhoneVersion(version)) else {
            print("  [!] Watch audio budget: Playback audio class fix not verified on \(version), so not applied")
            print("      Local-speaker Playback sessions will fail the MediaExperience power budget")
            return
        }
        
        let cache = try DyldSharedCacheChunkSet(
            directory: URL(filePath: targetMount).appending(path: "System/Library/Caches/com.apple.dyld"),
            architecture: "arm64e",
        )
        try CustomFirmwareWatchAudioBudget.patchCache(in: cache)
    }
}
