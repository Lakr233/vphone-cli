// CryptexFilesystemPatcherGuestPayload.swift — Guest payload injection into the merged volume.
//
// Split out of CryptexFilesystemPatcher.swift. These are the steps that write files into the
// mounted target volume: dyld symlinks, GPU driver bundle, the mobileactivationd and
// launchd_cache_loader patches, vphoned, and its LaunchDaemon.

import Foundation
import VPhoneCoreKit
import VPhoneSign

extension CryptexFilesystemPatcher {
    // MARK: - Signing

    /// Preserve a binary's existing entitlements while re-signing without an
    /// embedded certificate. The guest's JB firmware does not need a CMS
    /// identity for these binaries.
    func guestSigningOptions(
        identifier: String? = nil,
        entitlements: URL? = nil,
    ) throws -> VPhoneSignOptions {
        try VPhoneSignOptions(
            identifier: identifier,
            entitlements: entitlements.map { try Data(contentsOf: $0, options: .mappedIfSafe) },
            mergesExisting: true,
        )
    }

    func patchLaunchdCacheLoader(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        let launchdCacheLoaderPath = target.appending(path: "/usr/libexec/launchd_cache_loader")
        // Patched in place with no `.bak` to restore from, so this is the call
        // site that needs the port's idempotence. No re-attestation: the sign
        // below replaces the whole signature anyway.
        try CustomFirmwareCacheLoaderPatcher.patch(fileAt: launchdCacheLoaderPath)
        try setMode(0o755, at: launchdCacheLoaderPath)

        try VPhoneSigner.sign(
            fileAt: launchdCacheLoaderPath,
            options: guestSigningOptions(
                identifier: "com.apple.launchd_cache_loader",
            ),
        )
    }

    func injectLaunchDaemons(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        let tmpDir = try createTmpDir()
        let launchdPath = tmpDir.appending(path: "launchd.plist")
        let launchdOgPath = target.appending(path: "/System/Library/xpc/launchd.plist")
        try FileManager.default.moveItem(at: launchdOgPath, to: launchdPath)

        let vphonedLaunchdPlist = resources.guestResources.appendingPathComponent("vphoned.plist")
        try FileManager.default.copyItem(
            at: vphonedLaunchdPlist,
            to: target.appending(path: "System/Library/LaunchDaemons/vphoned.plist"),
        )
        try CustomFirmwareDaemons.injectDaemon(into: launchdPath, name: "vphoned", from: vphonedLaunchdPlist)
        print("  [+] Injected vphoned")
        try FileManager.default.moveItem(at: launchdPath, to: launchdOgPath)
        try setMode(0o644, at: launchdOgPath)
    }

    func addVphoned(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        // The signed payload in the bundle is read-only, so stage it in a
        // writable temp directory before copying it into the mounted guest.
        let buildDir = try createTmpDir()
        let vphonedBin = buildDir.appendingPathComponent("vphoned")

        try stageVphoned(to: vphonedBin)
        defer { try? FileManager.default.removeItem(at: vphonedBin) }

        let targetBin = target.appending(path: "/usr/bin/vphoned")
        try FileManager.default.copyItem(at: vphonedBin, to: targetBin)
        try setMode(0o755, at: targetBin)
    }

    /// Copy in the prebuilt guest daemon.
    ///
    /// This used to be a `/usr/bin/xcrun -sdk iphoneos clang …` over the .m
    /// sources shipped inside the .app — which meant installing CFW onto a VM
    /// required Xcode and the iPhoneOS SDK on a machine whose only job is to run
    /// that VM. vphoned is cross-compiled at build time now
    /// by the Xcode guest target and staged into the bundle.
    func stageVphoned(to vphonedBin: URL) throws {
        let prebuilt = try VPhoneGuestBinaries.resolve("vphoned")
        try FileManager.default.copyItem(at: prebuilt, to: vphonedBin)
    }

    func addGpuDriver(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        let bundle = target.appending(path: "/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle")
        let staged = VPhonePCCGPUDriver.stagedBundle(in: restoreDir)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw FirmwarePatcher.PatcherError.patchVerificationFailed(
                "PCC GPU driver is missing: \(staged.path). Re-run fw prepare with the PCC IPSW.",
            )
        }
        if FileManager.default.fileExists(atPath: bundle.path) {
            try FileManager.default.removeItem(at: bundle)
        }
        try FileManager.default.copyItem(at: staged, to: bundle)
        // Clean AppleDouble files if the host copy created any.
        try deleteAppleDoubleFiles(under: bundle)
        try chownRecursively(uid: 0, gid: 0, at: bundle)
        for path in [
            bundle,
            bundle.appending(path: "/AppleParavirtGPUMetalIOGPUFamily"),
            bundle.appending(path: "/_CodeSignature"),
        ] {
            try setMode(0o755, at: path)
        }
        let compilerPlugin = bundle.appending(path: "libAppleParavirtCompilerPluginIOGPUFamily.dylib")
        guard FileManager.default.fileExists(atPath: compilerPlugin.path) else {
            throw FirmwarePatcher.PatcherError.patchVerificationFailed(
                "PCC GPU compiler plugin is missing: \(compilerPlugin.path). Re-run fw prepare with a complete vphone-cli.app.",
            )
        }
        try setMode(0o755, at: compilerPlugin)
        for path in [
            bundle.appending(path: "/_CodeSignature/CodeResources"),
            bundle.appending(path: "/Info.plist"),
        ] {
            try setMode(0o644, at: path)
        }
    }

    func patchMobileActivation(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        let mobileActivationdPath = target.appending(path: "/usr/libexec/mobileactivationd")
        // `resign: false` because the sign below replaces the signature, and
        // re-attesting would refuse an unsigned input the Python accepted.
        try CustomFirmwareMobileActivation.patch(fileAt: mobileActivationdPath, resign: false)
        try setMode(0o755, at: mobileActivationdPath)

        try VPhoneSigner.sign(
            fileAt: mobileActivationdPath,
            options: guestSigningOptions(),
        )
    }

    func addDyldSymlinks(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        try createSymlink(
            at: target.appending(path: "/System/Library/Caches/com.apple.dyld"),
            to: "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
        )
        try createSymlink(
            at: target.appending(path: "/System/DriverKit/System/Library/dyld"),
            to: "../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld",
        )
    }
}
