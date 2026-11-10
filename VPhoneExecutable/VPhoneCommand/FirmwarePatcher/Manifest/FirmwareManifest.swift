// FirmwareManifest.swift — BuildManifest/Restore.plist generation.
//
// Translated from: scripts/fw_manifest.py
//
// Merges cloudOS boot-chain (vresearch101ap) with vphone600 runtime components
// (device tree, SEP, kernel) and iPhone OS images into a single DFU erase-install
// Build Identity.

import CryptoKit
import Foundation
import VPhoneCoreKit

// MARK: - Plist type aliases

/// Convenience alias for untyped plist dictionaries.
public typealias PlistDict = [String: Any]

// MARK: - FirmwareManifest

/// Generates hybrid BuildManifest and Restore plists for VM firmware.
///
/// The VM hardware identifies as vresearch101ap (BDID 0x90) in DFU mode, so the
/// identity fields must match for TSS/SHSH signing.  Runtime components use the
/// vphone600 variant because its device tree sets MKB dt=1 (keybag-less boot).
public enum FirmwareManifest {
    // MARK: - Errors

    public enum ManifestError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case invalidPlist(String)
        case identityNotFound(String)
        case missingKey(String)

        public var description: String {
            switch self {
            case let .fileNotFound(path):
                "File not found: \(path)"
            case let .invalidPlist(path):
                "Invalid plist: \(path)"
            case let .identityNotFound(msg):
                "Unable to find the \(msg)."
            case let .missingKey(key):
                "Missing required key: \(key)"
            }
        }
    }

    // MARK: - Public API

    /// Generate hybrid BuildManifest.plist and Restore.plist.
    ///
    /// - Parameters:
    ///   - iPhoneDir: Path to the extracted iPhone IPSW directory.
    ///   - cloudOSDir: Path to the extracted cloudOS IPSW directory.
    ///   - verbose: Print progress messages.
    public static func generate(
        iPhoneDir: URL,
        cloudOSDir: URL,
        device chosen: VPhoneGuestDevice? = nil,
        verbose: Bool = true,
    ) throws {
        // Load source plists.
        let cloudOSBM = try loadPlist(cloudOSDir.appendingPathComponent("BuildManifest.plist"))
        let iPhoneBM = try loadPlist(iPhoneDir.appendingPathComponent("BuildManifest.plist"))
        let cloudOSRP = try loadPlist(cloudOSDir.appendingPathComponent("Restore.plist"))
        let iPhoneRP = try loadPlist(iPhoneDir.appendingPathComponent("Restore.plist"))

        guard let cloudIdentities = cloudOSBM["BuildIdentities"] as? [PlistDict] else {
            throw ManifestError.missingKey("BuildIdentities in cloudOS BuildManifest")
        }
        guard let iPhoneIdentities = iPhoneBM["BuildIdentities"] as? [PlistDict] else {
            throw ManifestError.missingKey("BuildIdentities in iPhone BuildManifest")
        }

        // Discover source identities. An iPad IPSW carries one erase identity
        // per board it covers, so the userland one is picked by board.
        let device = chosen ?? VPhoneGuestDevice.detect(buildManifest: iPhoneBM) ?? .default
        let (prod, res) = try findCloudOS(cloudIdentities, deviceClass: "vresearch101ap")
        let (vp, vpr) = findRuntime(cloudIdentities, researchBoard: (prod, res))
        let iErase = try findIPhoneErase(iPhoneIdentities, deviceClass: device.deviceClass)

        if verbose {
            print("  cloudOS vresearch101ap: release=#\(prod), research=#\(res)")
            if (vp, vpr) == (prod, res) {
                print("  cloudOS vphone600ap:    none, the research board stands in")
            } else {
                print("  cloudOS vphone600ap:    release=#\(vp), research=#\(vpr)")
            }
            print("  \(device.productType) erase: #\(iErase)")
        }

        // Build the single DFU erase identity.
        let sourceIdentity = try buildEraseIdentity(
            cloudIdentities: cloudIdentities,
            iPhoneIdentities: iPhoneIdentities,
            prod: prod,
            res: res,
            vp: vp,
            vpr: vpr,
            iErase: iErase,
        )
        let buildIdentity = try normalizeGuestComponentDigests(
            sourceIdentity, device: device, restoreDir: iPhoneDir,
        )
        let guestIdentity = try separateGuestDeviceTree(
            for: device,
            identity: buildIdentity,
            restoreDir: iPhoneDir,
            verbose: verbose,
        )

        // Assemble BuildManifest.
        let buildManifest: PlistDict = [
            "BuildIdentities": [guestIdentity],
            "ManifestVersion": cloudOSBM["ManifestVersion"] as Any,
            "ProductBuildVersion": cloudOSBM["ProductBuildVersion"] as Any,
            "ProductVersion": cloudOSBM["ProductVersion"] as Any,
            "SupportedProductTypes": ["iPhone99,11"],
        ]

        // Assemble Restore.plist.
        let restore = try buildRestorePlist(
            cloudOSRP: cloudOSRP,
            iPhoneRP: iPhoneRP,
            boardConfig: device.deviceClass,
        )

        // Write output.
        try writePlist(buildManifest, to: iPhoneDir.appendingPathComponent("BuildManifest.plist"))
        if verbose {
            print("  wrote BuildManifest.plist")
        }

        try writePlist(restore, to: iPhoneDir.appendingPathComponent("Restore.plist"))
        if verbose {
            print("  wrote Restore.plist")
        }
    }

    // MARK: - Identity Discovery

    /// Determine whether a build identity is a research variant.
    static func isResearch(_ bi: PlistDict) -> Bool {
        for comp in ["LLB", "iBSS", "iBEC"] {
            let path = (bi["Manifest"] as? PlistDict)?[comp]
                .flatMap { $0 as? PlistDict }?["Info"]
                .flatMap { $0 as? PlistDict }?["Path"] as? String ?? ""
            guard !path.isEmpty else { continue }
            let parts = (path as NSString).lastPathComponent.split(separator: ".")
            if parts.count == 4 {
                return parts[2].contains("RESEARCH")
            }
        }
        let variant = (bi["Info"] as? PlistDict)?["Variant"] as? String ?? ""
        return variant.lowercased().contains("research")
    }

    /// Find release and research identity indices for the given DeviceClass.
    static func findCloudOS(
        _ identities: [PlistDict],
        deviceClass: String,
    ) throws -> (release: Int, research: Int) {
        var release: Int?
        var research: Int?
        for (i, bi) in identities.enumerated() {
            let dc = (bi["Info"] as? PlistDict)?["DeviceClass"] as? String ?? ""
            guard dc == deviceClass else { continue }
            if isResearch(bi) {
                if research == nil {
                    research = i
                }
            } else {
                if release == nil {
                    release = i
                }
            }
        }
        guard let rel = release else {
            throw ManifestError.identityNotFound("release identity for \(deviceClass) in the cloudOS BuildManifest")
        }
        guard let res = research else {
            throw ManifestError.identityNotFound("research identity for \(deviceClass) in the cloudOS BuildManifest")
        }
        return (rel, res)
    }

    /// The identities the guest's device tree, SEP and kernel come from:
    /// vphone600ap's, which only the 26.1–26.4 beta cloudOS releases carry, or
    /// else the research board's, which `fw patch` converts
    /// (FirmwareResearchBoardPatchSet).
    static func findRuntime(
        _ identities: [PlistDict],
        researchBoard: (release: Int, research: Int),
    ) -> (release: Int, research: Int) {
        (try? findCloudOS(identities, deviceClass: "vphone600ap")) ?? researchBoard
    }

    /// Return the index of the first iPhone erase identity.
    ///
    /// With `deviceClass`, an erase identity for that board wins; the first
    /// erase identity of any board is the fallback, which is all a single-board
    /// iPhone manifest has.
    static func findIPhoneErase(_ identities: [PlistDict], deviceClass: String? = nil) throws -> Int {
        var first: Int?
        for (i, bi) in identities.enumerated() {
            let info = bi["Info"] as? PlistDict
            let variant = (info?["Variant"] as? String ?? "").lowercased()
            guard !variant.contains("research"),
                  !variant.contains("upgrade"),
                  !variant.contains("recovery")
            else { continue }
            let board = (info?["DeviceClass"] as? String ?? "").lowercased()
            if let deviceClass, board == deviceClass.lowercased() {
                return i
            }
            first = first ?? i
        }
        guard let first else {
            throw ManifestError.identityNotFound("erase identity in the iPhone BuildManifest")
        }
        return first
    }

    // MARK: - Guest Device Tree

    /// Where a board-presenting guest's installed device tree is kept, beside
    /// the vphone600 one that restore boots with.
    public static let guestDeviceTreePath = "Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p"

    /// Points the installed `DeviceTree` of a guest that presents its board
    /// (an iPad, or an iPhone other than the XS Max) at a copy of the
    /// vphone600 tree, so `fw patch` can give that copy the board's identity.
    ///
    /// The DFU device restores with `RestoreDeviceTree`, and `restored_external`
    /// checks its root `model` and `target-type` against the manifest — the
    /// reason the iPhone identity is only rewritten after restore. The
    /// installed `DeviceTree` is a separate manifest entry that restore only
    /// personalizes and writes to Preboot, so giving it its own file lets the
    /// board identity ride through restore without a root-only rewrite on the
    /// host. An XS Max identity is returned unchanged.
    static func separateGuestDeviceTree(
        for device: VPhoneGuestDevice,
        identity: PlistDict,
        restoreDir: URL,
        verbose: Bool,
    ) throws -> PlistDict {
        guard device.presentsBoard else { return identity }
        guard var manifest = identity["Manifest"] as? PlistDict,
              var deviceTree = manifest["DeviceTree"] as? PlistDict,
              var info = deviceTree["Info"] as? PlistDict,
              let path = info["Path"] as? String
        else {
            throw ManifestError.missingKey("DeviceTree in the hybrid build identity")
        }
        let fm = FileManager.default
        let source = restoreDir.appending(path: path)
        let destination = restoreDir.appending(path: guestDeviceTreePath)
        guard fm.fileExists(atPath: source.path) else {
            throw ManifestError.fileNotFound(source.path)
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        info["Path"] = guestDeviceTreePath
        deviceTree["Info"] = info
        manifest["DeviceTree"] = deviceTree
        var separated = identity
        separated["Manifest"] = manifest
        if verbose {
            print("  \(device.productType): installed DeviceTree -> \(guestDeviceTreePath)")
        }
        return separated
    }

    // MARK: - Build Identity Construction

    /// J42d uses SHA-1 digests, but the PCC restore environment authenticates
    /// Image4 payloads with SHA-384. Keeping the donor digest makes canonical
    /// metadata execution fail with ENOEXEC before sealing. Hash the unchanged
    /// guest components for the hybrid ticket; other guest families retain
    /// their existing manifest entries and signature-bypass behavior.
    static func normalizeGuestComponentDigests(
        _ identity: PlistDict,
        device: VPhoneGuestDevice,
        restoreDir: URL,
    ) throws -> PlistDict {
        guard device.usesTVOS else { return identity }
        guard var manifest = identity["Manifest"] as? PlistDict else {
            throw ManifestError.missingKey("Manifest in the hybrid build identity")
        }
        for name in ["Ap,SystemVolumeCanonicalMetadata", "OS", "StaticTrustCache", "SystemVolume"] {
            guard var component = manifest[name] as? PlistDict,
                  let info = component["Info"] as? PlistDict,
                  let path = info["Path"] as? String,
                  CustomFirmwareDaemons.isPlainRelativePath(path)
            else { throw ManifestError.missingKey("Safe Path for \(name) in the hybrid build identity") }
            let data = try Data(contentsOf: restoreDir.appending(path: path), options: .mappedIfSafe)
            component["Digest"] = Data(SHA384.hash(data: data))
            manifest[name] = component
        }
        var normalized = identity
        normalized["Manifest"] = manifest
        return normalized
    }

    /// Deep-copy a single Manifest entry from a build identity.
    static func entry(
        _ identities: [PlistDict],
        _ idx: Int,
        _ key: String,
    ) throws -> PlistDict {
        guard let manifest = identities[idx]["Manifest"] as? PlistDict,
              let value = manifest[key] as? PlistDict
        else {
            throw ManifestError.missingKey("\(key) in identity #\(idx)")
        }
        return deepCopyPlistDict(value)
    }

    /// The build identity key iBoot's environment comes from: the restore sends
    /// it to TSS, iBoot reads it from the ticket and applies the matching
    /// `/osenvironments` overlay of the device tree.
    public static let osEnvironmentKey = "Ap,OSEnvironment"

    /// Build the single DFU erase identity by merging components from multiple sources.
    static func buildEraseIdentity(
        cloudIdentities C: [PlistDict],
        iPhoneIdentities I: [PlistDict],
        prod: Int,
        res: Int,
        vp: Int,
        vpr: Int,
        iErase: Int,
    ) throws -> PlistDict {
        // Identity base from vresearch101ap PROD.
        var bi = deepCopyPlistDict(C[prod])
        bi["Manifest"] = PlistDict()
        bi["Ap,ProductType"] = "ComputeModule14,2"
        bi["Ap,Target"] = "VRESEARCH101AP"
        bi["Ap,TargetType"] = "vresearch101"
        bi["ApBoardID"] = "0x90"
        bi["ApChipID"] = "0xFE01"
        bi["ApSecurityDomain"] = "0x01"

        // The cloudOS identity asks for trusted darwinOS. An iOS userland does
        // not boot in it unless its trust cache allows it, so the environment
        // is left out here and only `filesystem-exp-trusted_darwinos` puts it
        // back (CryptexFilesystemPatcher.setUpdatedComponentsInManifest). The
        // restore sends whatever the identity carries.
        bi.removeValue(forKey: osEnvironmentKey)

        // Remove NeRDEpoch and RestoreAttestationMode from top-level and Info.
        for key in ["NeRDEpoch", "RestoreAttestationMode"] {
            bi.removeValue(forKey: key)
            if var info = bi["Info"] as? PlistDict {
                info.removeValue(forKey: key)
                bi["Info"] = info
            }
        }

        // Set Info fields.
        if var info = bi["Info"] as? PlistDict {
            info["FDRSupport"] = false
            info["Variant"] = "Darwin Cloud Customer Erase Install (IPSW)"
            info["VariantContents"] = [
                "BasebandFirmware": "Release",
                "DCP": "DarwinProduction",
                "DFU": "DarwinProduction",
                "Firmware": "DarwinProduction",
                "InitiumBaseband": "Production",
                "InstalledKernelCache": "Production",
                "InstalledSPTM": "Production",
                "OS": "Production",
                "RestoreKernelCache": "Production",
                "RestoreRamDisk": "Production",
                "RestoreSEP": "DarwinProduction",
                "RestoreSPTM": "Production",
                "SEP": "DarwinProduction",
                "VinylFirmware": "Release",
            ] as PlistDict
            bi["Info"] = info
        }

        var m = PlistDict()

        // Boot chain (vresearch101 -- matches DFU hardware).
        m["LLB"] = try entry(C, prod, "LLB")
        m["iBSS"] = try entry(C, prod, "iBSS")
        m["iBEC"] = try entry(C, prod, "iBEC")
        m["iBoot"] = try entry(C, res, "iBoot") // research iBoot

        // Security monitors (shared across board configs).
        m["Ap,RestoreSecurePageTableMonitor"] = try entry(C, prod, "Ap,RestoreSecurePageTableMonitor")
        m["Ap,RestoreTrustedExecutionMonitor"] = try entry(C, prod, "Ap,RestoreTrustedExecutionMonitor")
        m["Ap,SecurePageTableMonitor"] = try entry(C, prod, "Ap,SecurePageTableMonitor")
        m["Ap,TrustedExecutionMonitor"] = try entry(C, res, "Ap,TrustedExecutionMonitor")

        // Device tree (vphone600ap -- sets MKB dt=1 for keybag-less boot).
        m["DeviceTree"] = try entry(C, vp, "DeviceTree")
        m["RestoreDeviceTree"] = try entry(C, vp, "RestoreDeviceTree")

        // SEP (vphone600 -- matches device tree).
        m["SEP"] = try entry(C, vp, "SEP")
        m["RestoreSEP"] = try entry(C, vp, "RestoreSEP")

        // Kernel (vphone600, patched by fw_patch).
        m["KernelCache"] = try entry(C, vpr, "KernelCache") // research
        m["RestoreKernelCache"] = try entry(C, vp, "RestoreKernelCache") // release

        // Recovery mode, which vphone600ap carries and the research board may not.
        if let recoveryMode = try? entry(C, vp, "RecoveryMode") {
            m["RecoveryMode"] = recoveryMode
        }

        // CloudOS erase ramdisk.
        m["RestoreRamDisk"] = try entry(C, prod, "RestoreRamDisk")
        m["RestoreTrustCache"] = try entry(C, prod, "RestoreTrustCache")

        // iPhone OS image.
        m["Ap,SystemVolumeCanonicalMetadata"] = try entry(I, iErase, "Ap,SystemVolumeCanonicalMetadata")
        m["OS"] = try entry(I, iErase, "OS")
        m["StaticTrustCache"] = try entry(I, iErase, "StaticTrustCache")
        m["SystemVolume"] = try entry(I, iErase, "SystemVolume")

        bi["Manifest"] = m
        return bi
    }

    // MARK: - Restore.plist

    /// Build the merged Restore.plist from cloudOS and iPhone sources.
    static func buildRestorePlist(
        cloudOSRP: PlistDict,
        iPhoneRP: PlistDict,
        boardConfig: String? = nil,
    ) throws -> PlistDict {
        // DeviceMap: iPhone first entry + cloudOS vphone600ap/vresearch101ap entries.
        guard let iPhoneDeviceMap = iPhoneRP["DeviceMap"] as? [PlistDict],
              !iPhoneDeviceMap.isEmpty
        else {
            throw ManifestError.missingKey("DeviceMap in iPhone Restore.plist")
        }
        guard let cloudDeviceMap = cloudOSRP["DeviceMap"] as? [PlistDict] else {
            throw ManifestError.missingKey("DeviceMap in cloudOS Restore.plist")
        }

        // A multi-board iPad IPSW lists one entry per board; keep the guest's.
        let guestEntry = iPhoneDeviceMap.first {
            ($0["BoardConfig"] as? String)?.lowercased() == boardConfig?.lowercased()
        } ?? iPhoneDeviceMap[0]
        var deviceMap: [PlistDict] = [guestEntry]
        for d in cloudDeviceMap {
            if let bc = d["BoardConfig"] as? String,
               bc == "vphone600ap" || bc == "vresearch101ap"
            {
                deviceMap.append(d)
            }
        }

        // SupportedProductTypeIDs: merge DFU and Recovery from both sources.
        guard let iPhoneTypeIDs = iPhoneRP["SupportedProductTypeIDs"] as? PlistDict,
              let cloudTypeIDs = cloudOSRP["SupportedProductTypeIDs"] as? PlistDict
        else {
            throw ManifestError.missingKey("SupportedProductTypeIDs")
        }

        var mergedTypeIDs = PlistDict()
        for cat in ["DFU", "Recovery"] {
            let iList = iPhoneTypeIDs[cat] as? [Any] ?? []
            let cList = cloudTypeIDs[cat] as? [Any] ?? []
            mergedTypeIDs[cat] = iList + cList
        }

        // SupportedProductTypes: merge from both sources.
        let iPhoneProductTypes = iPhoneRP["SupportedProductTypes"] as? [String] ?? []
        let cloudProductTypes = cloudOSRP["SupportedProductTypes"] as? [String] ?? []

        // SystemRestoreImageFileSystems: deep copy from iPhone.
        guard let sysRestoreFS = iPhoneRP["SystemRestoreImageFileSystems"] else {
            throw ManifestError.missingKey("SystemRestoreImageFileSystems in iPhone Restore.plist")
        }

        return [
            "ProductBuildVersion": cloudOSRP["ProductBuildVersion"] as Any,
            "ProductVersion": cloudOSRP["ProductVersion"] as Any,
            "DeviceMap": deviceMap,
            "SupportedProductTypeIDs": mergedTypeIDs,
            "SupportedProductTypes": iPhoneProductTypes + cloudProductTypes,
            "SystemRestoreImageFileSystems": deepCopyAny(sysRestoreFS),
        ]
    }

    // MARK: - Plist I/O

    /// Load a plist file and return its top-level dictionary.
    static func loadPlist(_ url: URL) throws -> PlistDict {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ManifestError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let dict = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil,
        ) as? PlistDict else {
            throw ManifestError.invalidPlist(path)
        }
        return dict
    }

    /// Write a plist dictionary to a file in XML format.
    static func writePlist(_ dict: PlistDict, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0,
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Deep Copy

    /// Deep-copy a plist dictionary (all nested containers are copied).
    static func deepCopyPlistDict(_ dict: PlistDict) -> PlistDict {
        var result = PlistDict()
        for (key, value) in dict {
            result[key] = deepCopyAny(value)
        }
        return result
    }

    /// Deep-copy any plist value, recursing into dicts and arrays.
    static func deepCopyAny(_ value: Any) -> Any {
        if let dict = value as? PlistDict {
            deepCopyPlistDict(dict)
        } else if let array = value as? [Any] {
            array.map { deepCopyAny($0) }
        } else {
            // Scalar types (String, Int, Bool, Data, Date) are value types or immutable.
            value
        }
    }
}
