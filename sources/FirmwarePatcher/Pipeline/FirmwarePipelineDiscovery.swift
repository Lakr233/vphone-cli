// FirmwarePipelineDiscovery.swift — Locating the Restore directory, firmware files
// and manifest versions.
//
// Owns the filesystem half of the pipeline: picking the newest `*Restore*` directory,
// reading `ProductVersion` out of the base and cloudOS manifests, and resolving a
// component's glob patterns to a concrete file URL.
//
// Split out of FirmwarePipeline.swift. `compareRestoreDirectories` and
// `parseRestoreDirectoryName` stay `private` and live here with their only caller,
// so nothing was widened by the move.

import Darwin
import Foundation

extension FirmwarePipeline {
    // MARK: - File Discovery

    /// Find the `*Restore*` subdirectory inside the VM directory.
    /// Mirrors Python `find_restore_dir`.
    func findRestoreDirectory() throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: vmDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { $0.lastPathComponent.contains("Restore") }
        .sorted(by: compareRestoreDirectories)

        guard let restoreDir = contents.first else {
            throw PatcherError.fileNotFound("Restore directory in \(vmDirectory.path). Run vphone-cli fw prepare first.")
        }
        return restoreDir
    }

    /// `ProductVersion` from a manifest in `restoreDir`, or nil if absent/unreadable.
    static func readProductVersion(_ restoreDir: URL, manifest: String) -> String? {
        let url = restoreDir.appendingPathComponent(manifest)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let version = dict["ProductVersion"] as? String
        else { return nil }
        return version
    }

    /// iPhone base version (`iPhone-BuildManifest.plist`, preserved by fw_prepare).
    static func readBaseProductVersion(_ restoreDir: URL) -> String? {
        readProductVersion(restoreDir, manifest: "iPhone-BuildManifest.plist")
    }

    /// cloudOS/kernel version (the live `BuildManifest.plist`).
    static func readCloudOSProductVersion(_ restoreDir: URL) -> String? {
        readProductVersion(restoreDir, manifest: "BuildManifest.plist")
    }

    /// Dotted `ProductVersion` >= major.minor, compared numerically. nil is false.
    static func productVersionAtLeast(_ version: String?, _ major: Int, _ minor: Int) -> Bool {
        guard let parts = version?.split(separator: ".").compactMap({ Int($0) }),
              let vMajor = parts.first else { return false }
        return vMajor != major ? vMajor > major : (parts.count > 1 ? parts[1] : 0) >= minor
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

        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
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
        throw PatcherError.fileNotFound("\(label). Looked in:\n    \(searched)")
    }
}
