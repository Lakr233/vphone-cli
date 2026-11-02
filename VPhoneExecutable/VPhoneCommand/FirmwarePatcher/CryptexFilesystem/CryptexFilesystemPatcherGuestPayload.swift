// CryptexFilesystemPatcherGuestPayload.swift — Guest payload injection into the merged volume.
//
// Split out of CryptexFilesystemPatcher.swift. These are the steps that write files into the
// mounted target volume: dyld symlinks, GPU driver bundle, the mobileactivationd and
// launchd_cache_loader patches, vphoned, and its LaunchDaemon.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit
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
        // Apple's ad-hoc shape, as the stock binaries around them: the guest's
        // TXM is not patched here, and it takes an ad-hoc binary from the
        // static trust cache but rejects ldid's signature, which has no
        // ad-hoc flag and an empty CMS blob ("Bad executable").
        try VPhoneSignOptions(
            identifier: identifier,
            entitlements: entitlements.map { try Data(contentsOf: $0, options: .mappedIfSafe) },
            mergesExisting: true,
            style: .appleAdHoc,
        )
    }

    func patchLaunchdCacheLoader(targetMount: String) throws {
        try editGuestFile("usr/libexec/launchd_cache_loader", targetMount: targetMount, mode: 0o755) { file in
            try thinToArm64e(file)
            // Patched in place with no `.bak` to restore from, so this is the call
            // site that needs the port's idempotence. No re-attestation: the sign
            // below replaces the whole signature anyway.
            try CustomFirmwareCacheLoaderPatcher.patch(fileAt: file)
            try setMode(0o755, at: file)

            try VPhoneSigner.sign(
                fileAt: file,
                options: guestSigningOptions(
                    identifier: "com.apple.launchd_cache_loader",
                ),
            )
        }
    }

    /// The launchd change `cfw install` makes for
    /// `system-launchd-boot-jetsam_panic_guard_bypass` (``CustomFirmwareJetsamPatcher``),
    /// in the pre-reseal merge. Re-signed ad hoc over its own entitlements, so
    /// the new hash lands in the regenerated trust cache.
    func patchLaunchdJetsam(targetMount: String) throws {
        try editGuestFile("sbin/launchd", targetMount: targetMount, mode: 0o755) { file in
            try thinToArm64e(file)
            try CustomFirmwareJetsamPatcher.patch(fileAt: file, log: { print("  \($0)") })
            try setMode(0o755, at: file)

            try VPhoneSigner.sign(
                fileAt: file,
                options: guestSigningOptions(identifier: "com.apple.xpc.launchd"),
            )
        }
        print("  [+] Patched launchd's jetsam panic guard")
    }

    func injectLaunchDaemons(targetMount: String) throws {
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let source = resources.guestResources.appendingPathComponent("vphoned.plist")
        try target.replaceFile("System/Library/LaunchDaemons/vphoned.plist", fromFileAt: source, mode: 0o644, owner: (0, 0))
        try editGuestFile(CustomFirmwareDetachedSignature.launchdCachePath, targetMount: targetMount, mode: 0o644) { file in
            try CustomFirmwareDaemons.injectDaemon(into: file, name: "vphoned", from: source)
        }
        print("  [+] Injected vphoned")
        try resignLaunchdCache(targetMount: targetMount)
    }

    /// Sign the edited `launchd.plist` as Apple signs it, so the stock
    /// `launchd_cache_loader` takes it as the secure cache. `createTrustcache`
    /// adds the new cdhashes to the static trust cache, which is what the loader
    /// asks AMFI about. See `CustomFirmwareDetachedSignature`.
    ///
    /// The new cdhashes take the launch-constraint category of Apple's
    /// signature, as a re-signed binary does (`resignedCDHashes`): Apple's
    /// static trust cache gives both cdhashes of its `launchd.plist.sig`
    /// category 2 (iOS 18.6 22G86).
    func resignLaunchdCache(targetMount: String) throws {
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let original = try target.exists(CustomFirmwareDetachedSignature.launchdCacheSignaturePath)
            ? CustomFirmwareDetachedSignature.codeDirectoryHashes(
                in: target.readData(CustomFirmwareDetachedSignature.launchdCacheSignaturePath),
            ).map(\.cdhash)
            : []
        let cache = try target.readData(CustomFirmwareDetachedSignature.launchdCachePath)
        let signature = CustomFirmwareDetachedSignature.sign(cache, identifierStem: "launchd")
        let file = try createTmpDir().appending(path: "launchd.plist.sig")
        try signature.write(to: file)
        // root:admin 0644, as Apple installs it.
        try target.replaceFile(CustomFirmwareDetachedSignature.launchdCacheSignaturePath,
                               fromFileAt: file, mode: 0o644, owner: (0, 80))
        for cdHash in original {
            print("  [+] Apple's launchd.plist.sig: cdhash \(cdHash.map { String(format: "%02x", $0) }.joined())")
        }
        for hash in try CustomFirmwareDetachedSignature.codeDirectoryHashes(in: signature) {
            if !original.isEmpty, !original.contains(hash.cdhash) {
                resignedCDHashes[hash.cdhash] = original
            }
            print("  [+] Signed launchd.plist: cdhash \(hash.cdhash.map { String(format: "%02x", $0) }.joined()) (hash type \(hash.hashType))")
        }
    }

    func addVphoned(targetMount: String) throws {
        // The signed payload in the bundle is read-only, so stage it in a
        // writable temp directory before copying it into the mounted guest.
        let buildDir = try createTmpDir()
        let vphonedBin = buildDir.appendingPathComponent("vphoned")

        try stageVphoned(to: vphonedBin)
        defer { try? FileManager.default.removeItem(at: vphonedBin) }

        let confined = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        if guestFamily == .iPhone || guestFamily == .iPad {
            // Included in createTrustcache's scan of the finished filesystem.
            _ = try confined.directory("usr/lib/vphone", create: true)
            try confined.replaceFile("usr/lib/vphone/libswiftCompatibilitySpan.dylib",
                                     fromFileAt: VPhoneGuestBinaries.resolve("libswiftCompatibilitySpan.dylib"),
                                     mode: 0o755, owner: (0, 0))
        }
        try confined.replaceFile("usr/bin/vphoned", fromFileAt: vphonedBin, mode: 0o755, owner: (0, 0))
    }

    /// Copy in the prebuilt guest daemon.
    ///
    /// This used to be a `/usr/bin/xcrun -sdk iphoneos clang …` over the .m
    /// sources shipped inside the .app — which meant installing CFW onto a VM
    /// required Xcode and the iPhoneOS SDK on a machine whose only job is to run
    /// that VM. vphoned is cross-compiled at build time now
    /// by the Xcode guest target and staged into the bundle.
    func stageVphoned(to vphonedBin: URL) throws {
        let prebuilt = try VPhoneGuestBinaries.resolve(VPhoneResources.vphonedName(for: guestFamily))
        try FileManager.default.copyItem(at: prebuilt, to: vphonedBin)
    }

    func addGpuDriver(targetMount: String) throws {
        let target = URL(filePath: targetMount)
        let bundle = target.appending(path: "/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle")
        let staged = VPhonePCCGPUDriver.stagedBundle(in: restoreDir)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw VPhonePatchKit.PatcherError.patchVerificationFailed(
                "PCC GPU driver is missing: \(staged.path). Re-run fw prepare with the PCC IPSW.",
            )
        }
        let confined = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let relative = "System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
        try confined.removeItem(relative)
        let source = try VPhoneConfinedDirectory.pin(absolutePath: staged.path)
        try confined.copyTree(from: source, to: relative, owner: (0, 0))
        // Clean AppleDouble files if the host copy created any.
        try deleteAppleDoubleFiles(under: bundle)
        if guestFamily == .watch {
            try retargetGPUBundle(bundle, to: MachOBuildPlatform.watchOS)
        }
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
            throw VPhonePatchKit.PatcherError.patchVerificationFailed(
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

    /// Whether the merged system is iOS 18, whose paravirtual IOSurface driver
    /// takes no compressed surfaces.
    var isIOS18: Bool {
        (try? getProductVersion())?.hasPrefix("18.") ?? false
    }

    /// iOS 18's AppleParavirtIOSurface maps only address format 0 and rejects
    /// the compressed surfaces CoreAnimation asks for ("invalid address format
    /// (3)"): backboardd's framebuffer allocation fails at boot, it retries
    /// forever, and the screen stays black. Turning off IOSurface and
    /// framebuffer compression and the deep (10-bit) framebuffer in the
    /// any-user global domain fixes it, checked across a reboot (a backboardd
    /// restart also comes up without these keys, so it proves nothing).
    /// backboardd consults neither com.apple.coreanimation nor the managed
    /// any-user file. The restore copies the image's /private/var into the
    /// data volume, so the preferences are written there.
    func addCoreAnimationDefaults(targetMount: String) throws {
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let directory = try target.directory("private/var/preferences", create: true)
        let plist = ".GlobalPreferences.plist"
        var preferences: [String: Any] = [:]
        if let data = try? directory.readData(plist),
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            preferences = existing
        }
        for key in ["CAEnableIOSurfaceCompression", "CAEnableFramebufferCompression", "CAEnableDeepFramebuffer"] {
            preferences[key] = false
        }
        let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        try directory.writeFile(plist, contents: data, mode: 0o644, owner: (0, 0))
    }

    /// The driver and its compiler plugin are built for iOS, and dyld refuses a
    /// library of another platform than the process's: on a watch they say
    /// watchOS, are signed again and the bundle sealed again.
    func retargetGPUBundle(_ bundle: URL, to platform: UInt32) throws {
        for name in ["AppleParavirtGPUMetalIOGPUFamily", "libAppleParavirtCompilerPluginIOGPUFamily.dylib"] {
            let file = bundle.appending(path: name)
            var data = try Data(contentsOf: file)
            try MachOBuildPlatform.set(platform, in: &data)
            try data.write(to: file)
            try VPhoneSigner.sign(
                fileAt: file,
                options: .init(identifier: nil, entitlements: nil, mergesExisting: true, style: .appleAdHoc),
            )
        }
        // No --identifier: codesign keeps the one the bundle already carries.
        _ = try runProcess("/usr/bin/codesign", ["-f", "-s", "-", "--timestamp=none", bundle.path])
        print("  [+] GPU driver retargeted to \(platform == MachOBuildPlatform.watchOS ? "watchOS" : "platform \(platform)")")
    }

    /// A watch's binaries are universal (arm64_32 and arm64e); the VM runs the
    /// arm64e slice, which is the one the patchers read. Keeps a thin binary.
    func thinToArm64e(_ file: URL) throws {
        let data = try Data(contentsOf: file)
        guard MachOFatSlice.isFat(data) else { return }
        try MachOFatSlice.slice(data).write(to: file)
    }

    func patchMobileActivation(targetMount: String) throws {
        try editGuestFile("usr/libexec/mobileactivationd", targetMount: targetMount, mode: 0o755) { file in
            try thinToArm64e(file)
            // `resign: false` because the sign below replaces the signature, and
            // re-attesting would refuse an unsigned input the Python accepted.
            try CustomFirmwareMobileActivation.patch(fileAt: file, resign: false)
            try setMode(0o755, at: file)

            try VPhoneSigner.sign(
                fileAt: file,
                options: guestSigningOptions(),
            )
        }
    }

    func addDyldSymlinks(targetMount: String) throws {
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        try target.createSymlink(target: "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
                                 at: "System/Library/Caches/com.apple.dyld")
        try target.createSymlink(target: "../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld",
                                 at: "System/DriverKit/System/Library/dyld")
    }

    /// Re-sign the guest's debugserver so it can attach in the guest: the same
    /// entitlement change `cfw install` makes (``CustomFirmwareDebugserver``), but
    /// in the pre-reseal merge, so debugserver's new hash lands in the image's
    /// regenerated trust cache and the stock kernel admits it. A logged no-op when
    /// the merged system ships no debugserver (a stock userland carries it only in
    /// the Developer disk image). Running and attaching also need kernel and TXM
    /// patches; ``FirmwarePatchSetCatalog/userspaceDebugging`` groups them.
    func patchDebugserver(targetMount: String) throws {
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let relative = CustomFirmwareDebugserver.guestPath
        guard try target.isRegularFile(relative) else {
            print("  [!] debugserver absent in the merged image; re-sign skipped")
            return
        }
        try editGuestFile(relative, targetMount: targetMount, mode: 0o755) { file in
            // A watch's debugserver also carries an arm64_32 slice, which the
            // signer cannot rewrite; the guest runs the arm64e one.
            try thinToArm64e(file)
            guard let source = try VPhoneSigner.entitlements(ofFileAt: file).first(where: { !$0.isEmpty }) else {
                throw VPhonePatchKit.PatcherError.patchVerificationFailed(
                    "debugserver has no readable entitlements; cannot grant task_for_pid",
                )
            }
            let entitlements = try CustomFirmwareDebugserver.attachEntitlements(from: source)
            // Replacement, not merge — see CustomFirmwareDebugserver.attachEntitlements.
            try VPhoneSigner.sign(
                fileAt: file,
                options: VPhoneSignOptions(entitlements: entitlements, style: .appleAdHoc),
            )
        }
        print("  [+] Re-signed debugserver with task_for_pid-allow")
    }

    /// Path-based patchers only see this private copy. Guest symlinks cannot
    /// redirect their reads or writes into the host filesystem.
    func editGuestFile(_ relative: String, targetMount: String, mode: mode_t, edit: (URL) throws -> Void) throws {
        let target = try VPhoneConfinedDirectory.pin(absolutePath: targetMount)
        let data = try target.readData(relative)
        let file = try createTmpDir().appending(path: "payload")
        try data.write(to: file)
        try edit(file)
        let original = TrustCache.cdHashes(ofMachO: data)
        for cdHash in try TrustCache.cdHashes(ofMachO: Data(contentsOf: file)) where !original.contains(cdHash) {
            resignedCDHashes[cdHash] = original
        }
        try target.replaceFile(relative, fromFileAt: file, mode: mode, owner: (0, 0))
    }

}
