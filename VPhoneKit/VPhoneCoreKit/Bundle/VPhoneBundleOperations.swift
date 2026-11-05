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
        public let networkConfig: VPhoneVirtualMachineManifest.NetworkConfig

        public init(
            name: String,
            cpuCount: UInt,
            memoryMB: UInt64,
            diskSizeGB: UInt64,
            romSource: URL,
            sepromSource: URL,
            networkConfig: VPhoneVirtualMachineManifest.NetworkConfig = .default,
        ) {
            self.name = name; self.cpuCount = cpuCount; self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB; self.romSource = romSource; self.sepromSource = sepromSource
            self.networkConfig = networkConfig
        }
    }

    /// The boot ROM new machines get: this bundle's OpenAVB.
    public static func defaultROMSource() -> URL {
        VPhoneBootROM.openAVBSource()
    }

    /// The SEP ROM new machines get: this bundle's OpenSEP.
    public static func defaultSEPROMSource() -> URL {
        VPhoneSEPROM.openSEPSource()
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
        // The bundle folder itself is created exclusively (mkdir, no
        // intermediates): a folder or link another account planted after the
        // check above makes this fail instead of being written into as root.
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        // Roll back the partial bundle on any failure after the dir is created,
        // so a retry with the same name isn't permanently blocked by the
        // alreadyExists check.
        do {
            // Sparse disk image: create then truncate to size (no bytes written).
            // Decimal GB, the unit iOS reports, so "128 GB" shows as 128 GB
            // in the guest rather than 137.
            let disk = dir.appendingPathComponent("Disk.img")
            fm.createFile(atPath: disk.path, contents: nil)
            let handle = try FileHandle(forWritingTo: disk)
            do {
                try handle.truncate(atOffset: spec.diskSizeGB * 1_000_000_000)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            // SEP storage: 512 KB of initialized zero bytes.
            try Data(count: 512 * 1024).write(to: dir.appendingPathComponent("SEPStorage"))

            // ROMs. Each keeps the name of its kind, so `fw patch` finds an
            // Apple boot ROM to patch and leaves OpenAVB alone.
            let romName = try bootROMKind(of: spec.romSource).fileName
            let sepromName = try sepROMKind(of: spec.sepromSource).fileName
            try fm.copyItem(at: spec.romSource, to: dir.appendingPathComponent(romName))
            try fm.copyItem(at: spec.sepromSource, to: dir.appendingPathComponent(sepromName))

            // Manifest.
            let manifest = VPhoneVirtualMachineManifest(
                cpuCount: spec.cpuCount,
                memorySize: spec.memoryMB * 1024 * 1024,
                networkConfig: spec.networkConfig,
                romImages: .init(avpBooter: romName, avpSEPBooter: sepromName),
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

    // MARK: - Boot ROM

    /// The kind of the ROM at `url`, refusing a file that cannot be read.
    static func bootROMKind(of url: URL) throws -> VPhoneBootROM {
        guard let kind = VPhoneBootROM.kind(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return kind
    }

    /// Makes `source` the machine's boot ROM: copies it into the folder under
    /// the name of its kind, unless it is already that file, and points
    /// `romImages.avpBooter` at it. vphone-vm reads the ROM when the machine
    /// starts, so a running machine takes it from its next start.
    ///
    /// The ROM it replaces stays in the folder. An Apple ROM there carries the
    /// digest patch `fw patch` applied, which a fresh copy from the framework
    /// would not, so going back to it needs only this call again.
    ///
    /// Only normal boot reads the ROM after a restore, and both ROMs load the
    /// same patched LLB, so a restored machine can change ROM without another
    /// restore. A restore through OpenAVB needs a bundle that uploads the iBSS
    /// identity, which bundles from before OpenAVB do not.
    @discardableResult
    public static func installBootROM(from source: URL, in bundle: VPhoneBundle) throws -> VPhoneBundle {
        let name = try bootROMKind(of: source).fileName
        try placeROM(from: source, named: name, in: bundle)
        let images = VPhoneVirtualMachineManifest.ROMImages(
            avpBooter: name,
            avpSEPBooter: bundle.manifest.romImages?.avpSEPBooter
                ?? VPhoneVirtualMachineManifest.ROMImages.default.avpSEPBooter,
        )
        return try write(romImages: images, to: bundle)
    }

    // MARK: - SEP ROM

    /// The kind of the SEP ROM at `url`, refusing a file that cannot be read.
    static func sepROMKind(of url: URL) throws -> VPhoneSEPROM {
        guard let kind = VPhoneSEPROM.kind(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return kind
    }

    /// Makes `source` the machine's SEP ROM, as ``installBootROM(from:in:)``
    /// does for the boot ROM: copied in under the name of its kind and named by
    /// `romImages.avpSEPBooter`, from the next start. The ROM it replaces
    /// stays in the folder.
    ///
    /// Neither SEP ROM is patched, and both boot the SEP firmware the restore
    /// installed, so a restored machine can change SEP ROM without another
    /// restore.
    @discardableResult
    public static func installSEPROM(from source: URL, in bundle: VPhoneBundle) throws -> VPhoneBundle {
        let name = try sepROMKind(of: source).fileName
        try placeROM(from: source, named: name, in: bundle)
        let images = VPhoneVirtualMachineManifest.ROMImages(
            avpBooter: bundle.manifest.romImages?.avpBooter
                ?? VPhoneVirtualMachineManifest.ROMImages.default.avpBooter,
            avpSEPBooter: name,
        )
        return try write(romImages: images, to: bundle)
    }

    /// Copies `source` into the folder as `name`, unless it is already that
    /// file, replacing an earlier copy in one step.
    private static func placeROM(from source: URL, named name: String, in bundle: VPhoneBundle) throws {
        let fm = FileManager.default
        let destination = bundle.url.appendingPathComponent(name)
        if source.standardizedFileURL.path != destination.standardizedFileURL.path {
            let staged = bundle.url.appendingPathComponent(".\(name).\(UUID().uuidString)")
            try fm.copyItem(at: source, to: staged)
            do {
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: destination)
                }
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
        }
        try VPhoneHostFilePermissions.makeAccessible(at: destination)
    }

    private static func write(romImages: VPhoneVirtualMachineManifest.ROMImages, to bundle: VPhoneBundle) throws -> VPhoneBundle {
        let updated = bundle.manifest.updating(romImages: romImages)
        try updated.write(to: bundle.configURL)
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.configURL)
        return VPhoneBundle(url: bundle.url, manifest: updated)
    }

    // MARK: - Config editing

    public static func updateConfig(
        bundleNamed name: String,
        in library: VPhoneLibrary,
        cpuCount: UInt?,
        memoryMB: UInt64?,
        networkMode: VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode? = nil,
        bridgeInterface: String? = nil,
        networkEdit: VPhoneNetworkEdit = VPhoneNetworkEdit(),
        unlocksAtStartup: Bool? = nil,
        syncsHostLocation: Bool? = nil,
        holdsDeveloperTunnel: Bool? = nil,
    ) throws -> VPhoneBundle {
        let bundle = try library.bundle(named: name)
        var edit = networkEdit
        edit.mode = networkMode ?? edit.mode
        edit.bridgeInterface = bridgeInterface ?? edit.bridgeInterface
        let network = edit.isEmpty
            ? nil
            : try VPhoneNetworking.merge(into: bundle.manifest.networkConfig, edit: edit)
        let updated = bundle.manifest.updating(
            cpuCount: cpuCount,
            memorySize: memoryMB.map { $0 * 1024 * 1024 },
            networkConfig: network,
            unlocksAtStartup: unlocksAtStartup,
            syncsHostLocation: syncsHostLocation,
            holdsDeveloperTunnel: holdsDeveloperTunnel,
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
        let renamed = try VPhoneBundle.load(at: dst)
        // A derived mDNS name follows the machine; one chosen by hand stays.
        let network = renamed.manifest.networkConfig
        guard let followed = localHostName(following: network.localHostName, from: name, to: newName) else {
            return renamed
        }
        let updated = renamed.manifest.updating(networkConfig: network.with(localHostName: .some(followed)))
        try updated.write(to: renamed.configURL)
        try VPhoneHostFilePermissions.makeAccessible(at: renamed.configURL)
        return VPhoneBundle(url: renamed.url, manifest: updated)
    }

    /// The mDNS name for a machine renamed or cloned from `oldName` to
    /// `newName`, when `name` is the one `--mdns on` derived from `oldName`.
    /// Nil for a name chosen by hand, or none.
    static func localHostName(following name: String?, from oldName: String, to newName: String) -> String? {
        name == VPhoneNetworking.localHostName(forVMName: oldName)
            ? VPhoneNetworking.localHostName(forVMName: newName)
            : nil
    }

    public static func delete(bundleNamed name: String, in library: VPhoneLibrary) throws {
        let url = try library.bundle(named: name).url
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Clone

    /// Copy the whole bundle, using APFS copy-on-write when available. The
    /// source must be stopped, so its disk image, `SEPStorage` and `nvram.bin`
    /// are copied from one moment.
    ///
    /// Without `newIdentity` the copy keeps the machine identifier, MAC address
    /// and every other setting, so it cannot run beside its source: it is a
    /// backup. With `newIdentity` the copy gets a new identity on its first
    /// start (see `resetIdentity`) and drops the network settings that would
    /// collide with the source's, listed by `networkSettingsClearedByNewIdentity`.
    @discardableResult
    public static func clone(
        bundleNamed name: String,
        to newName: String,
        in library: VPhoneLibrary,
        newIdentity: Bool = false,
    ) throws -> VPhoneBundle {
        try clone(bundleNamed: name, to: newName, in: library, newIdentity: newIdentity, afterCopy: {})
    }

    /// `afterCopy` runs between the copy and the second running check, so
    /// tests can start the source while it is being copied. `readerWait` is
    /// how long each check waits out holders that do not run the source.
    static func clone(
        bundleNamed name: String,
        to newName: String,
        in library: VPhoneLibrary,
        newIdentity: Bool,
        readerWait: TimeInterval = VPhoneBundleActivity.readerWait,
        afterCopy: () throws -> Void,
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let source = try library.bundle(named: name)
        return try clone(
            source, sourceName: name, to: newName, in: library, newIdentity: newIdentity,
            readerWait: readerWait, afterCopy: afterCopy,
        )
    }

    /// Clones a machine folder that need not be in `library`, such as a
    /// template in `.templates`, into `library` as `newName`. `sourceName` is
    /// the name a derived mDNS name follows from.
    public static func clone(
        _ source: VPhoneBundle,
        sourceName name: String,
        to newName: String,
        in library: VPhoneLibrary,
        newIdentity: Bool,
    ) throws -> VPhoneBundle {
        try clone(source, sourceName: name, to: newName, in: library, newIdentity: newIdentity, afterCopy: {})
    }

    static func clone(
        _ source: VPhoneBundle,
        sourceName name: String,
        to newName: String,
        in library: VPhoneLibrary,
        newIdentity: Bool,
        readerWait: TimeInterval = VPhoneBundleActivity.readerWait,
        afterCopy: () throws -> Void,
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = source.url
        let dst = library.url(forName: newName)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            throw VPhoneLibraryError.alreadyExists(name: newName)
        }
        // Checked before the copy, so a running source is refused without
        // copying anything, and again after it: the source may have started
        // while it was copied (off APFS that takes minutes), and the copy may
        // then hold state files from different moments.
        //
        // A clone only reads the source, so a holder that runs no machine
        // (Launchpad's disk meter mapping a template that just appeared) is
        // waited out for up to `readerWait` instead of failing the clone. A
        // VM process holding the source, or its live socket, refuses at once.
        try VPhoneBundleActivity.requireStopped(source, waitingForReaders: readerWait)

        // Roll back a half-made copy, so a retry with the same name is not
        // blocked by the alreadyExists check.
        do {
            // APFS CoW clone of the whole folder, then the entries a clone
            // drops are removed. Off APFS every byte is copied, so those are
            // never copied in the first place.
            if clonefile(src.path, dst.path, 0) == 0 {
                for entry in droppedFromClone {
                    try removeIfPresent(dst.appendingPathComponent(entry))
                }
            } else {
                try? fm.removeItem(at: dst) // clear any partial clonefile output first
                try fm.createDirectory(at: dst, withIntermediateDirectories: false)
                for entry in try fm.contentsOfDirectory(atPath: src.path) where !droppedFromClone.contains(entry) {
                    try fm.copyItem(at: src.appendingPathComponent(entry), to: dst.appendingPathComponent(entry))
                }
            }
            try afterCopy()
            try VPhoneBundleActivity.requireStopped(source, waitingForReaders: readerWait)
            var clone = try VPhoneBundle.load(at: dst)
            if newIdentity {
                clone = try resetIdentity(of: clone, clonedFrom: name)
            }
            try VPhoneHostFilePermissions.makeAccessible(at: dst)
            return clone
        } catch {
            try? fm.removeItem(at: dst)
            throw error
        }
    }

    /// Left out of every clone: snapshots record the source's history, not
    /// the copy's, the control socket is the stopped source's, and a
    /// template's record would make its clone a template that never boots.
    private static let droppedFromClone: Set<String> = [
        VPhoneMachineSnapshots.directoryName,
        "vphone.sock",
        VPhoneMachineTemplates.recordFileName,
    ]

    /// The network settings a new-identity clone drops, described for display.
    /// Each would collide with the source's when both run: a fixed address,
    /// host ports, and a `.local` name chosen by hand. A name `--mdns on`
    /// derived from the source's name is not cleared: it follows the new name,
    /// as it does on rename. The MAC address is not listed; it is always
    /// regenerated along with the machine identifier.
    public static func networkSettingsClearedByNewIdentity(
        _ network: VPhoneVirtualMachineManifest.NetworkConfig,
        sourceName: String,
    ) -> [String] {
        newIdentityNetwork(network, from: sourceName, to: sourceName).cleared
    }

    /// The network settings of a new-identity clone named `newName`, and a
    /// description of each one dropped. One rule for both, so what the CLI
    /// reports is what was written.
    private static func newIdentityNetwork(
        _ network: VPhoneVirtualMachineManifest.NetworkConfig,
        from sourceName: String,
        to newName: String,
    ) -> (network: VPhoneVirtualMachineManifest.NetworkConfig, cleared: [String]) {
        var cleared: [String] = []
        if let ipv4 = network.ipv4 {
            cleared.append("fixed IPv4 address \(ipv4.address)/\(ipv4.prefixLength)")
        }
        if let forwards = network.portForwards, !forwards.isEmpty {
            cleared.append("port forwards \(forwards.map(\.description).joined(separator: ", "))")
        }
        let followed = localHostName(following: network.localHostName, from: sourceName, to: newName)
        if followed == nil, let name = network.localHostName, !name.isEmpty {
            cleared.append("mDNS name \(name)")
        }
        let updated = network.with(
            macAddress: "",
            ipv4: .some(nil),
            portForwards: .some(nil),
            localHostName: .some(followed),
        )
        return (updated, cleared)
    }

    /// Give a copied bundle a new identity on its next start.
    ///
    /// The identity is the ECID, kept in `config.plist` as `machineIdentifier`.
    /// `vphone-vm` creates a new one, and a new MAC address, when either is
    /// empty, and the guest derives its UDID, Wi-Fi/Bluetooth MACs and USB
    /// serial from that ECID at boot. `udid-prediction.txt` only records the
    /// old one and is rewritten on every start.
    ///
    /// `nvram.bin`, `SEPStorage` and the disk image stay exactly as copied.
    /// The SEP's root secret lives in `SEPStorage`, and the xART gigalocker
    /// and the Data and User volume keys on the disk were all made from it by
    /// one restore: a fresh `SEPStorage` panics the SEP in AESS on the next
    /// boot, and only an erasing restore can make a new matching set.
    /// `nvram.bin` holds the boot firmware that restore wrote. Neither needs
    /// the new ECID: the boot chain's patched image4 property callback already
    /// ignores the ECID in the old tickets, and the SEP ROM accepts them too,
    /// so no re-personalization is needed. See
    /// `Research/Host/machine_identity_and_clone.md`.
    static func resetIdentity(of bundle: VPhoneBundle, clonedFrom sourceName: String) throws -> VPhoneBundle {
        let network = newIdentityNetwork(bundle.manifest.networkConfig, from: sourceName, to: bundle.name).network
        let updated = bundle.manifest.updating(machineIdentifier: Data(), networkConfig: network)
        try updated.write(to: bundle.configURL)
        try removeIfPresent(bundle.url.appendingPathComponent("udid-prediction.txt"))
        return VPhoneBundle(url: bundle.url, manifest: updated)
    }

    /// Remove a file, directory or link without following it; a missing one
    /// is fine.
    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    // MARK: - Export

    /// `.vphoned.signed` is re-staged on the next launch and need not be exported.
    /// `.ipsw-cache` holds the downloaded IPSWs of machines prepared before the
    /// cache moved to `VPhoneResources.ipswCacheDirectory()`; it is a cache,
    /// not part of the machine. The staging directories are left behind only
    /// when a disk image could not be detached, and one can hold a whole
    /// temporary cloudOS VM. None of these is `--include-ipsw`'s restore tree.
    /// Snapshots stay with the machine they were taken on: in an archive each
    /// one would be another full copy of the disk. A revert's staging folder
    /// is left behind only by a revert that was killed, and a rebase's staging
    /// folder only by a rebase that was killed.
    ///
    /// Export itself is `VPhoneBundleTransfer` in `VPhoneArchiveKit` — it needs
    /// libarchive, and this does not. The list stays here because it describes
    /// what a bundle is, and `VPhoneRestoreInfo` is checked against it.
    public static let exportExcludePatterns = [
        "*.vphoned.signed",
        ".ipsw-cache",
        ".firmware-prepare-*",
        ".pcc-restoration-*",
        ".pcc-system-*",
        VPhoneMachineSnapshots.directoryName,
        ".snapshot-revert-*",
        VPhoneDiskRebase.stagingPrefix + "*",
        // An imported machine is a full copy that shares no block with the
        // template its source was cloned from.
        VPhoneMachineTemplates.sourceFileName,
    ]

    /// The directory holding each boot-chain file exactly as the restore tree laid
    /// it down, so `fw patch` patches those bytes rather than its own output and
    /// can be run again. `FirmwarePipeline` fills it; the name lives here because
    /// three other things in the bundle have to agree about it: `fw prepare`
    /// deletes it with the restore tree it describes, and export both excludes it
    /// from a slim archive and leaves it out of the progress total.
    ///
    /// Deliberately outside the restore tree: `findRestoreDirectory` picks the
    /// newest direct child whose name contains "Restore", so an originals
    /// directory that matched would become a candidate restore tree.
    public static let firmwareOriginalsDirectoryName = "FirmwareOriginals"
}
