import Darwin
import Foundation

public enum VPhoneBundleOperations {
    public struct NewBundleConfiguration: Sendable {
        public let name: String
        public let cpuCount: UInt
        public let memoryMB: UInt64
        public let diskSizeGB: UInt64
        public let romSource: URL
        public let sepromSource: URL

        public init(
            name: String,
            cpuCount: UInt,
            memoryMB: UInt64,
            diskSizeGB: UInt64,
            romSource: URL,
            sepromSource: URL,
        ) {
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

    /// Public because `vm import` validates the name it is about to place into
    /// the library, and that lives in `VPhoneArchiveKit` now.
    public static func requireValidName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw VPhoneLibraryError.invalidName(name)
        }
    }

    public static func create(_ spec: NewBundleConfiguration, in library: VPhoneLibrary) throws -> VPhoneBundle {
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

            // SEP storage: 512 KB of initialized zero bytes.
            try Data(count: 512 * 1024).write(to: dir.appendingPathComponent("SEPStorage"))

            // ROMs.
            try fm.copyItem(at: spec.romSource, to: dir.appendingPathComponent("AVPBooter.vresearch1.bin"))
            try fm.copyItem(at: spec.sepromSource, to: dir.appendingPathComponent("AVPSEPBooter.vresearch1.bin"))

            // Manifest.
            let manifest = VPhoneVirtualMachineManifest(
                cpuCount: spec.cpuCount,
                memorySize: spec.memoryMB * 1024 * 1024,
                romImages: .init(avpBooter: "AVPBooter.vresearch1.bin",
                                 avpSEPBooter: "AVPSEPBooter.vresearch1.bin"),
            )
            try manifest.write(to: dir.appendingPathComponent("config.plist"))

            try VPhoneHostFilePermissions.makeAccessible(at: dir)
            try VPhoneHostFilePermissions.makeDirectoryAccessible(at: library.root)
            try VPhoneHostFilePermissions.makeDirectoryAccessible(at: VPhoneResources.userDataRoot())
            return VPhoneBundle(url: dir, manifest: manifest)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - Config editing

    public static func updateConfig(
        bundleNamed name: String,
        in library: VPhoneLibrary,
        cpuCount: UInt?,
        memoryMB: UInt64?,
        networkMode: VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode? = nil,
        bridgeInterface: String? = nil,
    ) throws -> VPhoneBundle {
        let bundle = try library.bundle(named: name)
        let editsNetwork = networkMode != nil || bridgeInterface != nil
        let network = editsNetwork
            ? try VPhoneNetworking.merge(
                into: bundle.manifest.networkConfig,
                mode: networkMode,
                bridgeInterface: bridgeInterface,
            )
            : nil
        let updated = bundle.manifest.updating(
            cpuCount: cpuCount,
            memorySize: memoryMB.map { $0 * 1024 * 1024 },
            networkConfig: network,
        )
        try updated.write(to: bundle.configURL)
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.configURL)
        return VPhoneBundle(url: bundle.url, manifest: updated)
    }

    // MARK: - Rename / delete

    public static func rename(
        bundleNamed name: String,
        to newName: String,
        in library: VPhoneLibrary,
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
        bundleNamed name: String,
        to newName: String,
        in library: VPhoneLibrary,
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = try library.bundle(named: name).url
        let dst = library.url(forName: newName)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            throw VPhoneLibraryError.alreadyExists(name: newName)
        }

        // APFS CoW clone; fall back to a plain recursive copy off-APFS.
        if clonefile(src.path, dst.path, 0) != 0 {
            try? fm.removeItem(at: dst) // clear any partial clonefile output first
            try fm.copyItem(at: src, to: dst)
        }
        try resetIdentity(inBundleAt: dst)
        try VPhoneHostFilePermissions.makeAccessible(at: dst)
        return try VPhoneBundle.load(at: dst)
    }

    private static func resetIdentity(inBundleAt dir: URL) throws {
        let fm = FileManager.default
        for name in ["nvram.bin", "udid-prediction.txt"] {
            let u = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) {
                try fm.removeItem(at: u)
            }
        }
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for u in entries where u.pathExtension == "shsh" {
            try fm.removeItem(at: u)
        }
        let configURL = dir.appendingPathComponent("config.plist")
        let manifest = try VPhoneVirtualMachineManifest.load(from: configURL)
        try manifest.updating(machineIdentifier: Data()).write(to: configURL)
    }

    // MARK: - Export

    /// Regenerable staging artifacts that never need to travel in an export:
    /// `.vphoned.signed` is re-staged on the next launch, and the CFW install
    /// inputs/temp are consumed at install time (the result already lives in
    /// `Disk.img`). Always excluded.
    ///
    /// Export itself is `VPhoneBundleTransfer` in `VPhoneArchiveKit` — it needs
    /// libarchive, and this does not. The list stays here because it describes
    /// what a bundle is, and `VPhoneRestoreInfo` is checked against it.
    public static let exportExcludePatterns =
        ["*.vphoned.signed", "*cfw_input*", "*cfw_jb_input*", "*.cfw_temp*"]
}
