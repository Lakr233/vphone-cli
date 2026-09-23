// CryptexFilesystemPatcherGuestPayload.swift — Guest payload injection into the merged volume.
//
// Split out of CryptexFilesystemPatcher.swift. These are the steps that write files into the
// mounted target volume: dyld symlinks, GPU driver bundle, the mobileactivationd and
// launchd_cache_loader patches, vphoned, the binpack, and the LaunchDaemons that start them.

import Foundation
import VPhoneArchive
import VPhoneCore
import VPhoneSign

extension CryptexFilesystemPatcher {
    // MARK: - Signing

    /// What the `ldid -S -M -K<cfw_input/signcert.p12>` these steps used to
    /// shell out for now asks VPhoneSign for.
    ///
    /// The `.p12` is opened here because VPhoneSign signs with an already-read
    /// identity. There is no longer a second path that opens it elsewhere: the
    /// external-ldid escape hatch is gone, so this parse either succeeds or the
    /// step fails, and a missing identity can no longer become a silent ad-hoc
    /// downgrade.
    func guestSigningOptions(
        cfwInput: URL,
        identifier: String? = nil,
        entitlements: URL? = nil
    ) throws -> VPhoneSignOptions {
        let signingCertificatePath = cfwInput.appending(path: "cfw_input/signcert.p12")
        return VPhoneSignOptions(
            identifier: identifier,
            entitlements: try entitlements.map { try Data(contentsOf: $0) },
            mergesExisting: true,
            identity: try VPhoneSignIdentity(
                pkcs12: Data(contentsOf: signingCertificatePath), password: ""
            )
        )
    }

    func patchLaunchdCacheLoader(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let launchdCacheLoaderPath = target.appending(path: "/usr/libexec/launchd_cache_loader")
        // Patched in place with no `.bak` to restore from, so this is the call
        // site that needs the port's idempotence. No re-attestation: the sign
        // below replaces the whole signature anyway.
        try CFWCacheLoaderPatcher.patch(fileAt: launchdCacheLoaderPath)
        try setMode(0o755, at: launchdCacheLoaderPath)

        try VPhoneSigner.sign(
            fileAt: launchdCacheLoaderPath,
            options: try guestSigningOptions(
                cfwInput: cfwInput, identifier: "com.apple.launchd_cache_loader"
            )
        )
    }

    func injectLaunchDaemons(targetMount: String, cfwInput: URL, vphoned: Bool = true, cfw: Bool = true) throws {
        let target = URL.init(filePath: targetMount)
        let scriptDir = resources.scriptsDir

        let tmpDir = try createTmpDir()
        let launchdPath = tmpDir.appending(path: "launchd.plist")
        let launchDaemonsPath = tmpDir.appending(path: "launchDaemons")
        let launchdOgPath = target.appending(path: "/System/Library/xpc/launchd.plist")
        try FileManager.default.createDirectory(at: launchDaemonsPath, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: launchdOgPath, to: launchdPath)

        if vphoned {
            let vphonedSrc = scriptDir.appendingPathComponent("vphoned")
            let vphonedLaunchdPlist = vphonedSrc.appending(path: "vphoned.plist")
            try FileManager.default.copyItem(
                at: vphonedLaunchdPlist,
                to: target.appending(path: "System/Library/LaunchDaemons/vphoned.plist")
            )
            try FileManager.default.copyItem(
                at: vphonedLaunchdPlist,
                to: launchDaemonsPath.appending(path: vphonedLaunchdPlist.lastPathComponent)
            )
        }
        if cfw {
            let launchDaemonsDir = cfwInput.appending(path: "cfw_input/jb/LaunchDaemons")
            let launchDaemons = try FileManager.default.contentsOfDirectory(atPath: launchDaemonsDir.path)
            for filename in launchDaemons {
                let launchDaemonUrl = launchDaemonsDir.appending(component: filename)
                let filename = launchDaemonUrl.lastPathComponent
                let fsTarget = target.appending(path: "System/Library/LaunchDaemons/\(filename)")
                try FileManager.default.copyItem(at: launchDaemonUrl, to: fsTarget)
                try FileManager.default.copyItem(at: launchDaemonUrl, to: launchDaemonsPath.appending(path: filename))
            }
        }

        // The Python printed one line per daemon as it scanned and the install
        // log is read for those lines, so the scan comes back in scan order and
        // is logged here in the same words.
        let staged = try CFWDaemons.injectDaemons(
            into: launchdPath, fromDirectory: launchDaemonsPath
        )
        for daemon in staged {
            switch daemon {
            case let .present(daemon):
                print("  [+] Injected \(daemon.name)")
            case let .absent(source):
                print("  [!] Missing \(source), skipping")
            }
        }
        try FileManager.default.moveItem(at: launchdPath, to: launchdOgPath)
        try setMode(0o644, at: launchdOgPath)
    }

    func addExtraServices(targetMount: String, cfwInput: URL) throws {
        // `.ontoGuestVolume` is `tar --preserve-permissions --no-overwrite-dir`
        // with numeric ownership — the preset was written for this archive. The
        // `/usr/bin/tar` call it replaces passed only the first of those, so the
        // directories iosbinpack64 shares with the system volume had their mode
        // and owner taken from the archive; now, as in `cfw_install.sh`, the
        // volume keeps its own.
        try VPhoneArchiveExtractor.extract(
            cfwInput.appending(path: "cfw_input/jb/iosbinpack64.tar"),
            into: URL(filePath: targetMount),
            options: .ontoGuestVolume
        )
    }

    func addVphoned(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let scriptDir = resources.scriptsDir
        let vphonedSrc = scriptDir.appendingPathComponent("vphoned")
        // vphonedSrc (bundled source) is read-only inside a packaged .app, so the
        // compiled binary must land in a writable temp dir, not next to the source.
        let buildDir = try createTmpDir()
        let vphonedBin = buildDir.appendingPathComponent("vphoned")

        try stageVphoned(to: vphonedBin)
        defer { try? FileManager.default.removeItem(at: vphonedBin) }

        // Sign
        let targetBin = target.appending(path: "/usr/bin/vphoned")
        try FileManager.default.copyItem(at: vphonedBin, to: targetBin)
        try VPhoneSigner.sign(
            fileAt: targetBin,
            options: try guestSigningOptions(
                cfwInput: cfwInput,
                entitlements: vphonedSrc.appendingPathComponent("entitlements.plist")
            )
        )
        try setMode(0o755, at: targetBin)
    }

    /// Copy in the prebuilt guest daemon.
    ///
    /// This used to be a `/usr/bin/xcrun -sdk iphoneos clang …` over the .m
    /// sources shipped inside the .app — which meant installing CFW onto a VM
    /// required Xcode and the iPhoneOS SDK on a machine whose only job is to run
    /// that VM. vphoned is cross-compiled at build time now
    /// (`scripts/guest_binaries.mk`) and staged into the bundle beside the other
    /// four guest binaries; the caller still signs it here, because signing uses
    /// the target VM's own certificate.
    func stageVphoned(to vphonedBin: URL) throws {
        let prebuilt = try VPhoneGuestBinaries.resolve("vphoned")
        try FileManager.default.copyItem(at: prebuilt, to: vphonedBin)
    }

    func addGpuDriver(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)

        let gpuTarPath = cfwInput.appending(path: "cfw_input/custom/AppleParavirtGPUMetalIOGPUFamily.tar")
        try VPhoneArchiveExtractor.extract(
            gpuTarPath, into: target, options: .ontoGuestVolume
        )

        let bundle = target.appending(path: "/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle")
        // Clean macOS resource fork files (._* files from tar xattrs)
        try deleteAppleDoubleFiles(under: bundle)
        try chownRecursively(uid: 0, gid: 0, at: bundle)
        for path in [
            bundle,
            bundle.appending(path: "/libAppleParavirtCompilerPluginIOGPUFamily.dylib"),
            bundle.appending(path: "/AppleParavirtGPUMetalIOGPUFamily"),
            bundle.appending(path: "/_CodeSignature"),
        ] {
            try setMode(0o755, at: path)
        }
        for path in [
            bundle.appending(path: "/_CodeSignature/CodeResources"),
            bundle.appending(path: "/Info.plist")
        ] {
            try setMode(0o644, at: path)
        }
    }

    func patchMobileActivation(targetMount: String, cfwInput: URL) throws {
        let target = URL.init(filePath: targetMount)
        let mobileActivationdPath = target.appending(path: "/usr/libexec/mobileactivationd")
        // `resign: false` because the sign below replaces the signature, and
        // re-attesting would refuse an unsigned input the Python accepted.
        try CFWMobileactivationd.patch(fileAt: mobileActivationdPath, resign: false)
        try setMode(0o755, at: mobileActivationdPath)

        try VPhoneSigner.sign(
            fileAt: mobileActivationdPath,
            options: try guestSigningOptions(cfwInput: cfwInput)
        )
    }

    func addDyldSymlinks(targetMount: String) throws {
        let target = URL.init(filePath: targetMount)
        try createSymlink(
            at: target.appending(path: "/System/Library/Caches/com.apple.dyld"),
            to: "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
        )
        try createSymlink(
            at: target.appending(path: "/System/DriverKit/System/Library/dyld"),
            to: "../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld"
        )
    }
}
