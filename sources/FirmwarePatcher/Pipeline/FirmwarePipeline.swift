// FirmwarePipeline.swift — Orchestrates full boot-chain firmware patching.
//
// Historical note: this file replaces the old Python firmware patcher implementation.
//
// Pipeline order: AVPBooter → iBSS → iBEC → LLB → TXM → Kernel → DeviceTree
//
// Variant selection (mirrors Makefile targets):
//   .regular — base patchers only
//   .dev     — TXMDevPatcher instead of TXMPatcher
//   .jb      — TXMDevPatcher + IBootJBPatcher (iBSS) + KernelJBPatcher
//   .exp     — JB + experimental: KernelEXPPatcher (hv_vmm rename) +
//              DeviceTreePatcher identity properties (D47AP/iPhone17,3).
//              Other variants are NOT affected by experimental patches.
//
// The component catalogue lives in FirmwarePipelineComponents.swift and the
// Restore-directory/firmware-file lookup in FirmwarePipelineDiscovery.swift.

import Darwin
import Foundation

/// Orchestrates firmware patching for all boot-chain components.
///
/// The pipeline discovers firmware files inside the VM directory (mirroring
/// `find_restore_dir` + `find_file` in the Python source), loads each file,
/// delegates to the appropriate ``Patcher``, and writes the patched data back.
///
/// The default loader mirrors the Python flow: it loads IM4P containers when
/// present, patches the extracted payload, and re-packages them on save.
public final class FirmwarePipeline {
    // MARK: - Variant

    public enum Variant: String, Sendable {
        case less
        case regular
        case dev
        case jb
        case exp
    }

    // MARK: - Firmware Loader (pluggable IM4P support)

    /// Abstraction over IM4P vs raw firmware loading.
    ///
    /// Provide a conforming type to override the default IM4P/raw handling.
    public protocol FirmwareLoader {
        /// Load firmware from `url`, returning the mutable payload data.
        func load(from url: URL) throws -> Data
        /// Save patched `data` back to `url`, repackaging as needed.
        func save(_ data: Data, to url: URL) throws
    }

    /// Default loader: transparently handles IM4P containers and raw payloads.
    public struct ContainerFirmwareLoader: FirmwareLoader {
        public init() {}
        public func load(from url: URL) throws -> Data {
            try IM4PHandler.load(contentsOf: url).payload
        }

        public func save(_ data: Data, to url: URL) throws {
            let original = try IM4PHandler.load(contentsOf: url).im4p
            try IM4PHandler.save(patchedData: data, originalIM4P: original, to: url)
        }
    }

    // MARK: - Component Descriptor

    /// Describes a single firmware component in the pipeline.
    struct ComponentDescriptor {
        let name: String
        /// If true, search paths are relative to the Restore directory.
        /// If false, relative to the VM directory root.
        let inRestoreDir: Bool
        /// Glob patterns used to locate the file (tried in order).
        let searchPatterns: [String]
        /// Factories that create patchers to run in sequence for the loaded data.
        let patcherFactories: [(Data, Bool) -> any Patcher]
    }

    // MARK: - Properties

    let vmDirectory: URL
    let variant: Variant
    let verbose: Bool
    let noBinpack: Bool
    let forceExcGuard: Bool
    let enableFrida: Bool
    let loader: any FirmwareLoader

    // MARK: - Init

    public init(
        vmDirectory: URL,
        variant: Variant = .regular,
        verbose: Bool = true,
        noBinpack: Bool = false,
        forceExcGuard: Bool = false,
        enableFrida: Bool = false,
        loader: (any FirmwareLoader)? = nil,
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.noBinpack = noBinpack
        self.forceExcGuard = forceExcGuard
        self.enableFrida = enableFrida
        self.loader = loader ?? ContainerFirmwareLoader()
    }

    // MARK: - Pipeline Execution

    /// Run the full patching pipeline.
    ///
    /// Returns combined ``PatchRecord`` arrays from every component, in order.
    /// Throws on the first component that fails to patch.
    public func patchAll() throws -> [PatchRecord] {
        let restoreDir = try findRestoreDirectory()

        log("[*] VM directory:      \(vmDirectory.path)")
        log("[*] Restore directory: \(restoreDir.path)")

        // Detect the iPhone base iOS version (from the pre-hybrid manifest that
        // fw_prepare preserves — the live BuildManifest.plist reads the cloudOS
        // version, not the base). iOS 18 bases need the skywalk-netagent boot-arg.
        let baseVersion = Self.readBaseProductVersion(restoreDir)
        let iosBaseIs18 = baseVersion?.hasPrefix("18.") ?? false
        let iosBaseIs27 = baseVersion?.hasPrefix("27.") ?? false
        let baseGateNote = iosBaseIs18 ? "  (enabling iOS-18 netagent boot-arg)"
            : iosBaseIs27 ? "  (enabling iOS-27 JB kernel patches)" : ""
        log("[*] iPhone base iOS:   \(baseVersion ?? "unknown")\(baseGateNote)")

        // Frida Stalker kernel patches only apply on cloudOS 26.4+ (where the shapes
        // were validated); older kernels are left untouched. The Frida deb install is
        // separate and version-independent.
        let cloudOSVersion = Self.readCloudOSProductVersion(restoreDir)
        let cloudOSIsFridaCapable = Self.productVersionAtLeast(cloudOSVersion, 26, 4)
        if enableFrida {
            log("[*] cloudOS kernel:    \(cloudOSVersion ?? "unknown")"
                + (cloudOSIsFridaCapable ? "  (Frida kernel patches enabled)"
                    : "  (< 26.4 — Frida kernel patches skipped)"))
        }

        let components = buildComponentList(
            restoreDir: restoreDir,
            iosBaseIs18: iosBaseIs18,
            iosBaseIs27: iosBaseIs27,
            cloudOSIsFridaCapable: cloudOSIsFridaCapable,
        )
        log("[*] Patching \(components.count) boot-chain components ...")

        var allRecords: [PatchRecord] = []

        for component in components {
            let baseDir = component.inRestoreDir ? restoreDir : vmDirectory
            let fileURL = try findFile(in: baseDir, patterns: component.searchPatterns, label: component.name)

            log("\n\(String(repeating: "=", count: 60))")
            log("  \(component.name): \(fileURL.path)")
            log(String(repeating: "=", count: 60))

            // Load
            let rawData = try loader.load(from: fileURL)
            log("  format: \(rawData.count) bytes")

            let (currentData, componentRecords) = try patchData(
                rawData,
                componentName: component.name,
                patcherFactories: component.patcherFactories,
            )

            try loader.save(currentData, to: fileURL)
            log("  [+] saved")

            allRecords.append(contentsOf: componentRecords)
        }

        log("\n\(String(repeating: "=", count: 60))")
        log("  All \(components.count) components patched successfully! (\(allRecords.count) total patches)")
        log(String(repeating: "=", count: 60))

        return allRecords
    }

    func patchData(
        _ rawData: Data,
        componentName: String,
        patcherFactories: [(Data, Bool) -> any Patcher],
    ) throws -> (Data, [PatchRecord]) {
        var currentData = rawData
        var componentRecords: [PatchRecord] = []

        for makePatcher in patcherFactories {
            let patcher = makePatcher(currentData, verbose)
            let records = try patcher.findAll()

            guard !records.isEmpty else {
                throw PatcherError.patchSiteNotFound("\(componentName): no patches found")
            }

            let count = try patcher.apply()
            log("  [+] \(count) \(componentName) patches applied")

            componentRecords.append(contentsOf: records)
            currentData = extractPatchedData(from: patcher, fallback: currentData, records: records)
        }

        return (currentData, componentRecords)
    }

    // MARK: - Data Extraction

    /// Extract the patched data from a patcher's internal buffer.
    ///
    /// All current patchers own a ``BinaryBuffer`` whose `.data` property
    /// holds the mutated bytes after `apply()`. We use protocol-based
    /// access where possible and fall back to manual patch application.
    func extractPatchedData(from patcher: any Patcher, fallback: Data, records: [PatchRecord]) -> Data {
        // Try known patcher types that expose their buffer.
        if let avp = patcher as? AVPBooterPatcher {
            return avp.buffer.data
        }
        if let iboot = patcher as? IBootPatcher {
            return iboot.buffer.data
        }
        if let txm = patcher as? TXMPatcher {
            return txm.buffer.data
        }
        if let kp = patcher as? KernelPatcher {
            return kp.buffer.data
        }
        if let kjb = patcher as? KernelJBPatcher {
            return kjb.buffer.data
        }
        if let kexp = patcher as? KernelEXPPatcher {
            return kexp.buffer.data
        }
        if let dt = patcher as? DeviceTreePatcher {
            return dt.patchedData
        }
        if let fs = patcher as? CryptexFilesystemPatcher {
            return fs.patchedData
        }
        if let mh = patcher as? ManifestHashPatcher {
            return mh.patchedData
        }

        // Fallback: apply records manually to a copy of the original data.
        var data = fallback
        for record in records {
            let range = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
            data.replaceSubrange(range, with: record.patchedBytes)
        }
        return data
    }

    // MARK: - Logging

    func log(_ message: String) {
        if verbose {
            print(message)
        }
    }
}
