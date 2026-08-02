import Darwin
import Foundation

public enum VPhoneBundleOpsError: Error, Equatable {
    case tarFailed(String)
    case badArchive(String)
}

public enum VPhoneBundleOps {
    public struct NewBundleSpec: Sendable {
        public var name: String
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        public var romSource: URL
        public var sepromSource: URL

        public init(name: String, cpuCount: UInt, memoryMB: UInt64, diskSizeGB: UInt64,
                    romSource: URL, sepromSource: URL) {
            self.name = name; self.cpuCount = cpuCount; self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB; self.romSource = romSource; self.sepromSource = sepromSource
        }
    }

    private static let frameworkResources = URL(fileURLWithPath:
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources")

    public static func defaultROMSource() -> URL {
        frameworkResources.appendingPathComponent("AVPBooter.vresearch1.bin")
    }
    public static func defaultSEPROMSource() -> URL {
        frameworkResources.appendingPathComponent("AVPSEPBooter.vresearch1.bin")
    }

    private static func requireValidName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw VPhoneLibraryError.invalidName(name)
        }
    }

    public static func create(_ spec: NewBundleSpec, in library: VPhoneLibrary) throws -> VPhoneBundle {
        try requireValidName(spec.name)
        let fm = FileManager.default
        let dir = library.url(forName: spec.name)
        if fm.fileExists(atPath: dir.path) {
            throw VPhoneLibraryError.alreadyExists(name: spec.name)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Roll back the partial bundle on any failure after the dir is created,
        // so a retry with the same name isn't permanently blocked by the
        // alreadyExists check.
        do {
            // Sparse disk image: create then truncate to size (no bytes written).
            let disk = dir.appendingPathComponent("Disk.img")
            fm.createFile(atPath: disk.path, contents: nil)
            let handle = try FileHandle(forWritingTo: disk)
            do {
                try handle.truncate(atOffset: spec.diskSizeGB * 1024 * 1024 * 1024)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            // SEP storage: 512 KB of zeros (real bytes, matches vm_create.sh).
            try Data(count: 512 * 1024).write(to: dir.appendingPathComponent("SEPStorage"))

            // ROMs.
            try fm.copyItem(at: spec.romSource, to: dir.appendingPathComponent("AVPBooter.vresearch1.bin"))
            try fm.copyItem(at: spec.sepromSource, to: dir.appendingPathComponent("AVPSEPBooter.vresearch1.bin"))

            // Manifest.
            let manifest = VPhoneVirtualMachineManifest(
                cpuCount: spec.cpuCount,
                memorySize: spec.memoryMB * 1024 * 1024,
                romImages: .init(avpBooter: "AVPBooter.vresearch1.bin",
                                 avpSEPBooter: "AVPSEPBooter.vresearch1.bin"))
            try manifest.write(to: dir.appendingPathComponent("config.plist"))

            return VPhoneBundle(url: dir, manifest: manifest)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - Config editing

    public static func updateConfig(
        bundleNamed name: String, in library: VPhoneLibrary,
        cpuCount: UInt?, memoryMB: UInt64?,
        networkMode: VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode? = nil,
        bridgeInterface: String? = nil
    ) throws -> VPhoneBundle {
        let bundle = try library.bundle(named: name)
        let editsNetwork = networkMode != nil || bridgeInterface != nil
        let network = editsNetwork
            ? try VPhoneNetworking.merge(
                into: bundle.manifest.networkConfig,
                mode: networkMode, bridgeInterface: bridgeInterface)
            : nil
        let updated = bundle.manifest.updating(
            cpuCount: cpuCount,
            memorySize: memoryMB.map { $0 * 1024 * 1024 },
            screenConfig: nil,
            networkConfig: network)
        try updated.write(to: bundle.configURL)
        return VPhoneBundle(url: bundle.url, manifest: updated)
    }

    // MARK: - Rename / delete

    public static func rename(
        bundleNamed name: String, to newName: String, in library: VPhoneLibrary
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = try library.bundle(named: name).url
        let dst = library.url(forName: newName)
        if FileManager.default.fileExists(atPath: dst.path) {
            throw VPhoneLibraryError.alreadyExists(name: newName)
        }
        try FileManager.default.moveItem(at: src, to: dst)
        return try VPhoneBundle.load(at: dst)
    }

    public static func delete(bundleNamed name: String, in library: VPhoneLibrary) throws {
        let url = try library.bundle(named: name).url
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Clone

    /// Clone a bundle with a fast APFS copy-on-write clone (fallback: recursive
    /// copy), then reset the boot-identity artifacts so the clone comes up as a
    /// fresh device on next boot. NOTE: SEPStorage is copied as-is — cloning an
    /// already-restored VM may need a re-restore for a fully clean identity.
    public static func clone(
        bundleNamed name: String, to newName: String, in library: VPhoneLibrary
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = try library.bundle(named: name).url
        let dst = library.url(forName: newName)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { throw VPhoneLibraryError.alreadyExists(name: newName) }

        // APFS CoW clone; fall back to a plain recursive copy off-APFS.
        if clonefile(src.path, dst.path, 0) != 0 {
            try? fm.removeItem(at: dst)  // clear any partial clonefile output first
            try fm.copyItem(at: src, to: dst)
        }
        try resetIdentity(inBundleAt: dst)
        return try VPhoneBundle.load(at: dst)
    }

    private static func resetIdentity(inBundleAt dir: URL) throws {
        let fm = FileManager.default
        for name in ["nvram.bin", "udid-prediction.txt"] {
            let u = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for u in entries where u.pathExtension == "shsh" { try fm.removeItem(at: u) }
        let configURL = dir.appendingPathComponent("config.plist")
        let manifest = try VPhoneVirtualMachineManifest.load(from: configURL)
        try manifest.updating(machineIdentifier: Data()).write(to: configURL)
    }

    // MARK: - Export / Import

    /// Regenerable staging artifacts that never need to travel in an export:
    /// `.vphoned.signed` is re-staged on the next launch, and the CFW install
    /// inputs/temp are consumed at install time (the result already lives in
    /// `Disk.img`). Always excluded.
    static let exportExcludePatterns = ["*.vphoned.signed", "*cfw_input*", "*cfw_jb_input*", "*.cfw_temp*"]

    public static func export(
        bundleNamed name: String, to outFile: URL, includeIPSW: Bool, in library: VPhoneLibrary
    ) throws {
        _ = try library.bundle(named: name)  // validate it exists
        // xz at max level, multithreaded (threads=0 → all cores) — the densest
        // compressor libarchive offers, for a multi-GB Disk.img.
        var args = ["-cf", outFile.path, "-J", "--options", "xz:compression-level=9,xz:threads=0"]
        if !includeIPSW { args += ["--exclude", "*_Restore*"] }
        for pattern in exportExcludePatterns { args += ["--exclude", pattern] }
        args += ["-C", library.root.path, name]
        let r = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/tar"), args)
        guard r.succeeded else { throw VPhoneBundleOpsError.tarFailed(r.stderr) }
    }

    public static func importArchive(
        from inFile: URL, name: String?, in library: VPhoneLibrary
    ) throws -> VPhoneBundle {
        let fm = FileManager.default
        // Auto-detect the compression (-tf, not -tzf) so both legacy gzip and
        // current xz archives import.
        let listing = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", inFile.path])
        guard listing.succeeded else { throw VPhoneBundleOpsError.tarFailed(listing.stderr) }
        let topDirs = Set(listing.stdout.split(whereSeparator: \.isNewline).compactMap {
            $0.split(separator: "/").first.map(String.init)
        })
        guard topDirs.count == 1, let archived = topDirs.first else {
            throw VPhoneBundleOpsError.badArchive(
                "expected a single top-level bundle directory, found \(topDirs.sorted())")
        }
        let finalName = name ?? archived
        try requireValidName(finalName)
        let dst = library.url(forName: finalName)
        if fm.fileExists(atPath: dst.path) { throw VPhoneLibraryError.alreadyExists(name: finalName) }

        // Extract into a private staging dir so the archive's OWN top-level name
        // can never clobber/merge into an existing bundle of that name; only the
        // validated destination name is ever placed into the library.
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        let staging = library.root.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let extract = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", inFile.path, "-C", staging.path])
        guard extract.succeeded else { throw VPhoneBundleOpsError.tarFailed(extract.stderr) }
        let extracted = staging.appendingPathComponent(archived)
        guard fm.fileExists(atPath: extracted.appendingPathComponent("config.plist").path) else {
            throw VPhoneBundleOpsError.badArchive(
                "archive did not contain a valid bundle (\(archived)/config.plist)")
        }
        try fm.moveItem(at: extracted, to: dst)
        return try VPhoneBundle.load(at: dst)
    }
}
