// KernelCacheKDK.swift — Combine extracted KDKs and stage them as a kmutil volume.
//
// A KDK here is what `ipsw kernel extract --kdk` writes: the kernel and every
// kext of a kernel collection as standalone Mach-Os with their Info.plists, under
// `KDK_<version>_<build>.kdk/System/Library`.

import Foundation
import VPhonePatchKit

enum KernelCacheKDK {
    // MARK: - Bundles

    /// A bundle below System/Library/Extensions; paths are relative to that directory
    /// (absolute paths from the enumerator may resolve symlinks, e.g. /tmp → /private/tmp).
    struct Bundle {
        let path: String
        let infoPath: String
        let plist: [String: Any]
    }

    /// Every .kext below `extensions` with its Info.plist, sorted by path.
    static func kexts(in extensions: URL) throws -> [Bundle] {
        guard let enumerator = FileManager.default.enumerator(atPath: extensions.path) else {
            throw PatcherError.fileNotFound(extensions.path)
        }
        var found: [Bundle] = []
        while let relative = enumerator.nextObject() as? String {
            guard (relative as NSString).lastPathComponent == "Info.plist" else { continue }
            let parent = (relative as NSString).deletingLastPathComponent
            let bundle = (parent as NSString).lastPathComponent == "Contents" ? (parent as NSString).deletingLastPathComponent : parent
            guard (bundle as NSString).pathExtension == "kext",
                  let plist = try? plist(at: extensions.appending(path: relative))
            else { continue }
            found.append(Bundle(path: bundle, infoPath: relative, plist: plist))
        }
        return found.sorted { $0.infoPath < $1.infoPath }
    }

    /// Bundle identifier → path relative to System/Library/Extensions.
    static func bundles(in kdk: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for bundle in try kexts(in: kdk.appending(path: "System/Library/Extensions")) {
            if let id = bundle.plist["CFBundleIdentifier"] as? String {
                result[id] = bundle.path
            }
        }
        return result
    }

    static func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
    }

    // MARK: - Mix

    /// Copy `base` to `output`, drop the bundles not listed in `wanted` and add the
    /// listed bundles that only `donor` has (at their bundle paths). Nested bundles
    /// keep their parents' directories.
    static func mix(base: URL, donor: URL, wanted: [String], output: URL) throws -> (removed: [String], added: [String]) {
        let (removed, added) = try mix(base: base, sources: [base, donor], wanted: wanted, output: output)
        return (removed, added[donor] ?? [])
    }

    /// Copy `base` to `output` and keep the bundles listed in `wanted`, each from
    /// the first of `sources` (which includes `base`) that has it, or from the
    /// source `pinned` names for it; the kernel's KPI bundles (System.kext)
    /// always stay the base's. Nested bundles keep their parents' directories.
    /// Returns the base bundles dropped and the bundles added from each other
    /// source.
    static func mix(
        base: URL, sources: [URL], wanted: [String], output: URL, pinned: [String: Int] = [:],
    ) throws -> (removed: [String], added: [URL: [String]]) {
        let fm = FileManager.default
        let wantedSet = Set(wanted)
        if let stray = pinned.keys.sorted().first(where: { !wantedSet.contains($0) }) {
            throw PatcherError.invalidFormat("\(stray) is pinned but not among the wanted bundles")
        }
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: base, to: output)

        let outExtensions = output.appending(path: "System/Library/Extensions")
        let have = try bundles(in: output)
        let available = try sources.map { $0 == base ? have : try bundles(in: $0) }
        func isKPI(_ relative: String) -> Bool {
            relative == "System.kext" || relative.hasPrefix("System.kext/")
        }
        var owner: [String: Int] = [:]
        for id in wantedSet {
            if let relative = have[id], isKPI(relative) {
                owner[id] = sources.firstIndex(of: base)
            } else if let index = pinned[id] {
                guard available.indices.contains(index), available[index][id] != nil else {
                    throw PatcherError.fileNotFound("\(id) is pinned to a source that does not have it")
                }
                owner[id] = index
            } else {
                owner[id] = available.indices.first { index in
                    available[index][id].map { sources[index] == base || !isKPI($0) } ?? false
                }
            }
        }
        let missing = wantedSet.filter { owner[$0] == nil }
        guard missing.isEmpty else {
            throw PatcherError.fileNotFound("kexts in none of the mix's KDKs: \(missing.sorted().joined(separator: ", "))")
        }
        let keptFromBase = Set(wantedSet.filter { sources[owner[$0]!] == base })

        var removed: [String] = []
        // Deepest bundles first, so plug-ins go before their parents.
        for (id, relative) in have.sorted(by: { $0.value.split(separator: "/").count > $1.value.split(separator: "/").count }) {
            let path = outExtensions.appending(path: relative)
            guard !keptFromBase.contains(id), fm.fileExists(atPath: path.path) else { continue }
            let keepsWantedPlugin = have.contains { other in
                keptFromBase.contains(other.key) && other.value != relative && other.value.hasPrefix(relative + "/")
            }
            if keepsWantedPlugin {
                // Keep the directory for its plug-ins, but not the bundle itself.
                for info in [path.appending(path: "Contents/Info.plist"), path.appending(path: "Info.plist")]
                    where fm.fileExists(atPath: info.path)
                {
                    try fm.removeItem(at: info)
                }
                continue
            }
            try fm.removeItem(at: path)
            if !wantedSet.contains(id) {
                removed.append(id)
            }
        }

        var added: [URL: [String]] = [:]
        for (index, source) in sources.enumerated() where source != base {
            let extensions = source.appending(path: "System/Library/Extensions")
            for id in wantedSet.filter({ owner[$0] == index }).sorted() {
                let relative = available[index][id]!
                // Nested plug-ins are copied for their own identifiers.
                try copyTree(from: extensions.appending(path: relative), to: outExtensions.appending(path: relative), skipping: "PlugIns")
                added[source, default: []].append(id)
            }
        }
        return (removed.sorted(), added)
    }

    /// Recursive copy that merges into existing directories and skips entries named `skipping`.
    static func copyTree(from source: URL, to destination: URL, skipping: String) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        let attributes = try fm.attributesOfItem(atPath: source.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try fm.destinationOfSymbolicLink(atPath: source.path)
            try? fm.removeItem(at: destination)
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } else if isDirectory.boolValue {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source.path) where name != skipping {
                try copyTree(from: source.appending(path: name), to: destination.appending(path: name), skipping: skipping)
            }
        } else {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
    }

    // MARK: - Volume

    /// Create a minimal volume root for `kmutil create -R <volume>` holding the listed
    /// bundles, System.kext (KPI pseudo bundles) and a KDK with the kernel. kmutil only loads kexts owned by root:wheel (otherwise it silently
    /// falls back to the host's /System/Library/Extensions); the caller chowns.
    /// Returns the kernel path inside the volume.
    @discardableResult
    static func makeVolume(kdk: URL, identifiers: [String], output: URL) throws -> URL {
        let fm = FileManager.default
        let extensions = kdk.appending(path: "System/Library/Extensions")
        let wanted = Set(identifiers)
        var found: [String: Bundle] = [:]
        for bundle in try kexts(in: extensions) {
            guard let id = bundle.plist["CFBundleIdentifier"] as? String, wanted.contains(id), found[id] == nil else { continue }
            found[id] = bundle
        }
        let missing = identifiers.filter { found[$0] == nil }
        guard missing.isEmpty else {
            throw PatcherError.fileNotFound("bundles missing from \(kdk.lastPathComponent): \(missing.joined(separator: ", "))")
        }

        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        let outExtensions = output.appending(path: "System/Library/Extensions")
        for (_, entry) in found {
            try copyFile(extensions.appending(path: entry.infoPath), to: outExtensions.appending(path: entry.infoPath))
            if let executable = entry.plist["CFBundleExecutable"] as? String {
                let infoDir = (entry.infoPath as NSString).deletingLastPathComponent
                for candidate in ["\(infoDir)/MacOS/\(executable)", "\(infoDir)/\(executable)"] {
                    var isDirectory: ObjCBool = false
                    let source = extensions.appending(path: candidate)
                    if fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                        try copyFile(source, to: outExtensions.appending(path: candidate))
                        break
                    }
                }
            }
        }

        // KPI pseudo-bundles (com.apple.kpi.*) resolve the kexts' dependencies.
        let systemKext = outExtensions.appending(path: "System.kext")
        let sourceSystemKext = extensions.appending(path: "System.kext")
        if !fm.fileExists(atPath: systemKext.appending(path: "Info.plist").path),
           fm.fileExists(atPath: sourceSystemKext.appending(path: "Info.plist").path)
        {
            try? fm.removeItem(at: systemKext)
            try fm.copyItem(at: sourceSystemKext, to: systemKext)
        }

        let systemVersion = kdk.appending(path: "System/Library/CoreServices/SystemVersion.plist")
        try copyFile(systemVersion, to: output.appending(path: "System/Library/CoreServices/SystemVersion.plist"))
        let version = try plist(at: systemVersion)
        let kdkName = "KDK_\(version["ProductVersion"] as? String ?? "")_\(version["ProductBuildVersion"] as? String ?? "").kdk"
        let volumeKDK = output.appending(path: "Library/Developer/KDKs/\(kdkName)")
        try copyFile(systemVersion, to: volumeKDK.appending(path: "System/Library/CoreServices/SystemVersion.plist"))
        let kernel = volumeKDK.appending(path: "System/Library/Kernels/kernel")
        try copyFile(kdk.appending(path: "System/Library/Kernels/kernel"), to: kernel)
        // kmutil requires the KDK to have an Extensions directory; share the volume's.
        try fm.createSymbolicLink(
            atPath: volumeKDK.appending(path: "System/Library/Extensions").path,
            withDestinationPath: "../../../../../../System/Library/Extensions"
        )
        return kernel
    }

    static func copyFile(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
