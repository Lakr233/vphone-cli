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
    let loader: any FirmwareLoader

    // MARK: - Init

    public init(
        vmDirectory: URL,
        variant: Variant = .regular,
        verbose: Bool = true,
        noBinpack: Bool = false,
        loader: (any FirmwareLoader)? = nil
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.noBinpack = noBinpack
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

        let components = buildComponentList()
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

            // Patch
            var currentData = rawData
            var componentRecords: [PatchRecord] = []

            for makePatcher in component.patcherFactories {
                let patcher = makePatcher(rawData, verbose)
                let records = try patcher.findAll()

                guard !records.isEmpty else {
                    throw PatcherError.patchSiteNotFound("\(component.name): no patches found")
                }

                let count = try patcher.apply()
                log("  [+] \(count) \(component.name) patches applied")

                componentRecords.append(contentsOf: records)
                if let deviceTreePatcher = patcher as? DeviceTreePatcher {
                    currentData = deviceTreePatcher.patchedData
                } else if let filesystemPatcher = patcher as? CryptexFilesystemPatcher {
                    currentData = filesystemPatcher.patchedData
                } else if let manifestPatcher = patcher as? ManifestHashPatcher {
                    currentData = manifestPatcher.patchedData
                } else {
                    for record in records {
                        let range = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
                        currentData.replaceSubrange(range, with: record.patchedBytes)
                    }
                }
            }

            try loader.save(currentData, to: fileURL)
            log("  [+] saved")

            allRecords.append(contentsOf: componentRecords)
        }

        log("\n\(String(repeating: "=", count: 60))")
        log("  All \(components.count) components patched successfully! (\(allRecords.count) total patches)")
        log(String(repeating: "=", count: 60))

        return allRecords
    }

    // MARK: - Component List Builder

    /// Build the ordered component list based on the variant.
    func buildComponentList() -> [ComponentDescriptor] {
        var components: [ComponentDescriptor] = []

        // 1. AVPBooter — always present, lives in VM root
        components.append(ComponentDescriptor(
            name: "AVPBooter",
            inRestoreDir: false,
            searchPatterns: ["AVPBooter*.bin"],
            patcherFactories: {
                if variant != .less {
                    return [
                        { data, verbose in
                            AVPBooterPatcher(data: data, verbose: verbose)
                        },
                    ]
                }
                return []
            }()
        ))

        // 2. iBSS — JB variant runs the base iBSS patcher, then the nonce-skip extension.
        components.append(ComponentDescriptor(
            name: "iBSS",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular, .dev:
                    [{ data, verbose in
                        IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                    }]
                case .jb:
                    [
                        { data, verbose in
                            IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                        },
                        { data, verbose in
                            IBootJBPatcher(data: data, mode: .ibss, verbose: verbose)
                        },
                    ]
                }
            }()
        ))

        // 3. iBEC - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "iBEC",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"],
            patcherFactories: [{ data, verbose in
                IBootPatcher(data: data, mode: .ibec, verbose: verbose)
            }]
        ))

        // 4. LLB - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "LLB",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
            patcherFactories: [{ data, verbose in
                IBootPatcher(data: data, mode: .llb, verbose: verbose)
            }]
        ))

        // 5. TXM — dev/jb variants use TXMDevPatcher (adds entitlements, debugger, dev-mode)
        components.append(ComponentDescriptor(
            name: "TXM",
            inRestoreDir: true,
            searchPatterns: ["Firmware/txm.iphoneos.research.im4p"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular:
                    [{ data, verbose in
                        TXMPatcher(data: data, verbose: verbose)
                    }]
                case .dev, .jb:
                    [{ data, verbose in
                        TXMDevPatcher(data: data, verbose: verbose)
                    }]
                }
            }()
        ))

        // 6. Kernel — JB variant runs base kernel patches first, then JB extensions.
        components.append(ComponentDescriptor(
            name: "kernelcache",
            inRestoreDir: true,
            searchPatterns: ["kernelcache.research.vphone600"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular:
                    [{ data, verbose in
                        KernelPatcher(data: data, verbose: verbose, isDev: false)
                    }]
                case .dev:
                    [{ data, verbose in
                        KernelPatcher(data: data, verbose: verbose, isDev: true)
                    }]
                case .jb:
                    [
                        { data, verbose in
                            KernelPatcher(data: data, verbose: verbose, isDev: false)
                        },
                        { data, verbose in
                            KernelJBPatcher(data: data, verbose: verbose)
                        },
                    ]
                }
            }()
        ))

        // 7. DeviceTree — same for all variants
        components.append(ComponentDescriptor(
            name: "DeviceTree",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/DeviceTree.vphone600ap.im4p"],
            patcherFactories: [{ data, verbose in
                DeviceTreePatcher(data: data, verbose: verbose)
            }]
        ))
        
        // 8. Filesystem
        components.append(ComponentDescriptor(
            name: "Filesystem",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                return switch variant {
                case .less:
                    [{ data, verbose in
                        CryptexFilesystemPatcher(buildManiest: data, restoreDir: try! self.findRestoreDirectory(), verbose: verbose, noBinpack: self.noBinpack)
                    }]
                case .regular, .dev, .jb:
                    []
                }
            }()
        ))

        // 9. Firmware Manifest - Only required when excluding the img4 signature patches.
        components.append(ComponentDescriptor(
            name: "Manifest",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                return switch variant {
                case .less:
                    [{ data, verbose in
                        ManifestHashPatcher(data: data, restoreDir: try? self.findRestoreDirectory(), verbose: verbose)
                    }]
                case .regular, .dev, .jb:
                    []
                }
            }()
        ))

        return components
    }

    // MARK: - File Discovery

    /// Find the `*Restore*` subdirectory inside the VM directory.
    /// Mirrors Python `find_restore_dir`.
    func findRestoreDirectory() throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: vmDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { $0.lastPathComponent.contains("Restore") }
        .sorted(by: compareRestoreDirectories)

        guard let restoreDir = contents.first else {
            throw PatcherError.fileNotFound("No *Restore* directory found in \(vmDirectory.path). Run prepare_firmware first.")
        }
        return restoreDir
    }

    private func compareRestoreDirectories(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftName = lhs.lastPathComponent
        let rightName = rhs.lastPathComponent

        if let left = parseRestoreDirectoryName(leftName),
           let right = parseRestoreDirectoryName(rightName)
        {
            if left.version != right.version {
                return left.version.lexicographicallyPrecedes(right.version, by: >)
            }
            if left.build != right.build {
                return left.build.compare(right.build, options: .numeric) == .orderedDescending
            }
        }

        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return leftName > rightName
    }

    private func parseRestoreDirectoryName(_ name: String) -> (version: [Int], build: String)? {
        let pattern = #"_([0-9]+(?:\.[0-9]+)*)_([0-9A-Za-z]+)_Restore$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              match.numberOfRanges == 3,
              let versionRange = Range(match.range(at: 1), in: name),
              let buildRange = Range(match.range(at: 2), in: name)
        else { return nil }

        let version = name[versionRange]
            .split(separator: ".")
            .compactMap { Int($0) }
        let build = String(name[buildRange])
        guard !version.isEmpty else { return nil }
        return (version, build)
    }

    /// Find a firmware file by trying glob-style patterns under `baseDir`.
    /// Mirrors Python `find_file`.
    func findFile(in baseDir: URL, patterns: [String], label: String) throws -> URL {
        let fm = FileManager.default
        for pattern in patterns {
            if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
                var matches: [URL] = []
                if !pattern.contains("/") {
                    let urls = try fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isRegularFileKey])
                    for url in urls where fnmatch(pattern, url.lastPathComponent, 0) == 0 {
                        matches.append(url)
                    }
                } else {
                    let enumerator = fm.enumerator(at: baseDir, includingPropertiesForKeys: [.isRegularFileKey])
                    while let url = enumerator?.nextObject() as? URL {
                        guard url.path.hasPrefix(baseDir.path + "/") else { continue }
                        let rel = String(url.path.dropFirst(baseDir.path.count + 1))
                        if fnmatch(pattern, rel, 0) == 0 {
                            matches.append(url)
                        }
                    }
                }
                if let first = matches.sorted(by: { $0.path < $1.path }).first {
                    return first
                }
            } else {
                let candidate = baseDir.appendingPathComponent(pattern)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let searched = patterns.map { baseDir.appendingPathComponent($0).path }.joined(separator: "\n    ")
        throw PatcherError.fileNotFound("\(label) not found. Searched:\n    \(searched)")
    }

    // MARK: - Data Extraction

    /// Extract the patched data from a patcher's internal buffer.
    ///
    /// All current patchers own a ``BinaryBuffer`` whose `.data` property
    /// holds the mutated bytes after `apply()`. We use protocol-based
    /// access where possible and fall back to manual patch application.
    func extractPatchedData(from patcher: any Patcher, fallback: Data, records: [PatchRecord]) -> Data {
        // Try known patcher types that expose their buffer.
        if let avp = patcher as? AVPBooterPatcher { return avp.buffer.data }
        if let iboot = patcher as? IBootPatcher { return iboot.buffer.data }
        if let txm = patcher as? TXMPatcher { return txm.buffer.data }
        if let kp = patcher as? KernelPatcher { return kp.buffer.data }
        if let kjb = patcher as? KernelJBPatcher { return kjb.buffer.data }
        if let dt = patcher as? DeviceTreePatcher { return dt.patchedData }

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
