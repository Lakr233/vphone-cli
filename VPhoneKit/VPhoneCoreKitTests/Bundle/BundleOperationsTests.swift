import Foundation
import Testing
@testable import VPhoneCoreKit

/// Creating, editing, renaming and cloning a bundle. Export and import moved to
/// `VPhoneArchiveTests/BundleTransferTests` with the implementation, which needs
/// libarchive; this half does not.
struct BundleOperationsTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fakeROM() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data([0xAA, 0xBB, 0xCC]).write(to: f)
        return f
    }

    @Test func `creates bundle with sparse disk and manifest`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }

        let spec = VPhoneBundleOperations.NewBundleConfiguration(
            name: "newvm",
            cpuCount: 8,
            memoryMB: 8192,
            diskSizeGB: 64,
            romSource: rom,
            sepromSource: seprom,
        )
        let bundle = try VPhoneBundleOperations.create(spec, in: VPhoneLibrary(root: root))

        #expect(bundle.manifest.cpuCount == 8)
        #expect(bundle.manifest.memorySize == 8192 * 1024 * 1024)
        let disk = bundle.url.appendingPathComponent("Disk.img")
        let size = try (FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? NSNumber)?.int64Value
        #expect(size == Int64(64 * 1_000_000_000))
        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("SEPStorage").path))
        #expect(
            FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("AVPBooter.vresearch1.bin").path),
        )
    }

    @Test func `creates bundle with the requested network`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)

        let offline = try VPhoneBundleOperations.create(
            .init(
                name: "offline",
                cpuCount: 2,
                memoryMB: 2048,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
                networkConfig: .init(mode: .off, macAddress: ""),
            ),
            in: lib,
        )
        #expect(offline.manifest.networkConfig.mode == .off)
        // Persisted, and realized as no NIC at all.
        let saved = try lib.bundle(named: "offline").manifest.networkConfig
        #expect(saved.mode == .off)
        #expect(try VPhoneNetworking.makeNetworkDevice(saved).device == nil)

        // Left out, it is the default.
        let plain = try VPhoneBundleOperations.create(
            .init(name: "plain", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: lib,
        )
        #expect(plain.manifest.networkConfig.mode == .nat)
    }

    @Test func `rejects duplicate name`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let spec = VPhoneBundleOperations.NewBundleConfiguration(
            name: "dup",
            cpuCount: 2,
            memoryMB: 2048,
            diskSizeGB: 1,
            romSource: rom,
            sepromSource: seprom,
        )
        _ = try VPhoneBundleOperations.create(spec, in: VPhoneLibrary(root: root))
        #expect(throws: VPhoneLibraryError.self) {
            _ = try VPhoneBundleOperations.create(spec, in: VPhoneLibrary(root: root))
        }
    }

    @Test func `rejects invalid names`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for bad in ["", "a/b", ".hidden"] {
            #expect(throws: VPhoneLibraryError.self) {
                _ = try VPhoneBundleOperations.create(
                    .init(
                        name: bad,
                        cpuCount: 2,
                        memoryMB: 2048,
                        diskSizeGB: 1,
                        romSource: rom,
                        sepromSource: seprom,
                    ),
                    in: lib,
                )
            }
        }
    }

    @Test func `rolls back partial bundle on failure`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        // A non-existent ROM source makes copyItem fail AFTER the dir is created.
        let missingRom = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        #expect(throws: (any Error).self) {
            _ = try VPhoneBundleOperations.create(
                .init(
                    name: "partial",
                    cpuCount: 2,
                    memoryMB: 2048,
                    diskSizeGB: 1,
                    romSource: missingRom,
                    sepromSource: missingRom,
                ),
                in: lib,
            )
        }
        // The half-built directory must be removed so the name is reusable.
        #expect(!FileManager.default.fileExists(atPath: lib.url(forName: "partial").path))
    }

    @Test func `update config persists fields`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(
                name: "cfg",
                cpuCount: 8,
                memoryMB: 8192,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        let updated = try VPhoneBundleOperations.updateConfig(bundleNamed: "cfg", in: lib, cpuCount: 4, memoryMB: nil)
        #expect(updated.manifest.cpuCount == 4)
        #expect(updated.manifest.memorySize == 8192 * 1024 * 1024)

        // Persisted: a fresh load sees the change.
        #expect(try lib.bundle(named: "cfg").manifest.cpuCount == 4)
        // Untouched network stays at the default.
        #expect(updated.manifest.networkConfig.mode == .nat)
    }

    @Test func `update config persists unlock at startup`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(name: "unlock", cpuCount: 8, memoryMB: 8192, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: lib,
        )
        #expect(try VPhoneBundleReport(bundle: lib.bundle(named: "unlock")).unlocksAtStartup == false)

        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "unlock", in: lib, cpuCount: nil, memoryMB: nil, unlocksAtStartup: true,
        )
        #expect(try VPhoneBundleReport(bundle: lib.bundle(named: "unlock")).unlocksAtStartup)

        // Another edit leaves it alone; off turns it off.
        _ = try VPhoneBundleOperations.updateConfig(bundleNamed: "unlock", in: lib, cpuCount: 4, memoryMB: nil)
        #expect(try lib.bundle(named: "unlock").manifest.unlocksScreenAtStartup)
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "unlock", in: lib, cpuCount: nil, memoryMB: nil, unlocksAtStartup: false,
        )
        #expect(try !lib.bundle(named: "unlock").manifest.unlocksScreenAtStartup)
    }

    @Test func `update config persists host location sync`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(name: "location", cpuCount: 8, memoryMB: 8192, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: lib,
        )
        #expect(try VPhoneBundleReport(bundle: lib.bundle(named: "location")).syncsHostLocation == false)

        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "location", in: lib, cpuCount: nil, memoryMB: nil, syncsHostLocation: true,
        )
        #expect(try VPhoneBundleReport(bundle: lib.bundle(named: "location")).syncsHostLocation)

        // Another edit leaves it alone; off turns it off.
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "location", in: lib, cpuCount: nil, memoryMB: nil, unlocksAtStartup: true,
        )
        #expect(try lib.bundle(named: "location").manifest.sharesHostLocation)
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "location", in: lib, cpuCount: nil, memoryMB: nil, syncsHostLocation: false,
        )
        #expect(try !lib.bundle(named: "location").manifest.sharesHostLocation)
    }

    @Test func `update config persists the developer tunnel`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(name: "tunnel", cpuCount: 8, memoryMB: 8192, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: lib,
        )
        #expect(try VPhoneBundleReport(bundle: lib.bundle(named: "tunnel")).holdsDeveloperTunnel == false)

        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "tunnel", in: lib, cpuCount: nil, memoryMB: nil, holdsDeveloperTunnel: true,
        )
        #expect(try VPhoneBundleReport(bundle: lib.bundle(named: "tunnel")).holdsDeveloperTunnel)

        // Another edit leaves it alone; off turns it off.
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "tunnel", in: lib, cpuCount: nil, memoryMB: nil, syncsHostLocation: true,
        )
        #expect(try lib.bundle(named: "tunnel").manifest.keepsDeveloperTunnelOpen)
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "tunnel", in: lib, cpuCount: nil, memoryMB: nil, holdsDeveloperTunnel: false,
        )
        #expect(try !lib.bundle(named: "tunnel").manifest.keepsDeveloperTunnelOpen)
    }

    @Test func `update config persists network`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(
                name: "net",
                cpuCount: 8,
                memoryMB: 8192,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        let updated = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "net",
            in: lib,
            cpuCount: nil,
            memoryMB: nil,
            networkMode: .off,
        )
        #expect(updated.manifest.networkConfig.mode == .off)
        // Persisted across a fresh load, and cpu/memory untouched.
        let reloaded = try lib.bundle(named: "net").manifest
        #expect(reloaded.networkConfig.mode == .off)
        #expect(reloaded.cpuCount == 8)
    }

    @Test func `update config rejects bad network`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(
                name: "bad",
                cpuCount: 2,
                memoryMB: 2048,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        #expect(throws: VPhoneNetworkingError.hostOnlyUnsupported) {
            _ = try VPhoneBundleOperations.updateConfig(
                bundleNamed: "bad",
                in: lib,
                cpuCount: nil,
                memoryMB: nil,
                networkMode: .hostOnly,
            )
        }
        // A rejected edit must not have mutated the on-disk manifest.
        #expect(try lib.bundle(named: "bad").manifest.networkConfig.mode == .nat)
    }

    /// A fixed address and forwards are written to config.plist and read back.
    @Test func `update config saves address and forwards`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(name: "fixed", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: lib,
        )

        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "fixed",
            in: lib,
            cpuCount: nil,
            memoryMB: nil,
            networkMode: .tunnel,
            networkEdit: VPhoneNetworkEdit(
                address: .fixed(address: "10.20.0.5", prefixLength: 16),
                addForwards: [.init(hostPort: 8022, guestPort: 22)],
            ),
        )
        let network = try lib.bundle(named: "fixed").manifest.networkConfig
        #expect(network.mode == .tunnel)
        #expect(network.ipv4 == .init(address: "10.20.0.5", prefixLength: 16))
        #expect(network.portForwards == [.init(hostPort: 8022, guestPort: 22)])
    }

    /// A name `--mdns on` derived follows a rename; a hand-picked one stays.
    @Test func `rename carries a derived mDNS name`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for name in ["lab_a", "lab_b"] {
            _ = try VPhoneBundleOperations.create(
                .init(name: name, cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
                in: lib,
            )
        }
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "lab_a", in: lib, cpuCount: nil, memoryMB: nil,
            networkEdit: VPhoneNetworkEdit(localHostName: .some(VPhoneNetworking.localHostName(forVMName: "lab_a"))),
        )
        _ = try VPhoneBundleOperations.updateConfig(
            bundleNamed: "lab_b", in: lib, cpuCount: nil, memoryMB: nil,
            networkEdit: VPhoneNetworkEdit(localHostName: .some("bench")),
        )
        #expect(try VPhoneBundleOperations.rename(bundleNamed: "lab_a", to: "phone_a", in: lib).manifest.networkConfig.localHostName == "phone-a")
        #expect(try VPhoneBundleOperations.rename(bundleNamed: "lab_b", to: "phone_b", in: lib).manifest.networkConfig.localHostName == "bench")
        #expect(try lib.bundle(named: "phone_a").manifest.networkConfig.localHostName == "phone-a")
    }

    @Test func `rename then delete`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOperations.create(
            .init(
                name: "old",
                cpuCount: 2,
                memoryMB: 2048,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )

        let renamed = try VPhoneBundleOperations.rename(bundleNamed: "old", to: "shiny", in: lib)
        #expect(renamed.name == "shiny")
        #expect(throws: VPhoneLibraryError.self) { _ = try lib.bundle(named: "old") }

        try VPhoneBundleOperations.delete(bundleNamed: "shiny", in: lib)
        #expect(try lib.bundles().isEmpty)
    }

    @Test func `rename rejects existing target`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for n in ["a", "b"] {
            _ = try VPhoneBundleOperations.create(
                .init(
                    name: n,
                    cpuCount: 2,
                    memoryMB: 2048,
                    diskSizeGB: 1,
                    romSource: rom,
                    sepromSource: seprom,
                ),
                in: lib,
            )
        }
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "b")) {
            _ = try VPhoneBundleOperations.rename(bundleNamed: "a", to: "b", in: lib)
        }
    }

    @Test func `clone preserves bundle contents and keeps copy independent`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        let src = try VPhoneBundleOperations.create(
            .init(
                name: "src",
                cpuCount: 8,
                memoryMB: 4096,
                diskSizeGB: 1,
                romSource: rom,
                sepromSource: seprom,
            ),
            in: lib,
        )
        // Simulate a booted/restored VM with identity artifacts.
        let fm = FileManager.default
        try Data([1, 2, 3]).write(to: src.url.appendingPathComponent("nvram.bin"))
        try Data([4]).write(to: src.url.appendingPathComponent("udid-prediction.txt"))
        try Data([5]).write(to: src.url.appendingPathComponent("ABC123.shsh"))
        let withID = src.manifest.updating(machineIdentifier: Data([9, 9]))
        try withID.write(to: src.configURL)

        let clone = try VPhoneBundleOperations.clone(bundleNamed: "src", to: "dst", in: lib)

        // Copy happened (disk + ROMs present in the clone).
        #expect(fm.fileExists(atPath: clone.url.appendingPathComponent("Disk.img").path))
        #expect(fm.fileExists(atPath: clone.url.appendingPathComponent("AVPBooter.vresearch1.bin").path))
        // A clone has the same boot identity and state as the source.
        #expect(try Data(contentsOf: clone.url.appendingPathComponent("nvram.bin")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: clone.url.appendingPathComponent("udid-prediction.txt")) == Data([4]))
        #expect(try Data(contentsOf: clone.url.appendingPathComponent("ABC123.shsh")) == Data([5]))
        #expect(try Data(contentsOf: clone.url.appendingPathComponent("SEPStorage")) == Data(contentsOf: src.url.appendingPathComponent("SEPStorage")))
        #expect(clone.manifest.machineIdentifier == Data([9, 9]))
        // Writing to the copy does not change the source, including with CoW.
        try Data([8]).write(to: clone.url.appendingPathComponent("nvram.bin"))
        #expect(try Data(contentsOf: src.url.appendingPathComponent("nvram.bin")) == Data([1, 2, 3]))
        #expect(try lib.bundle(named: "src").manifest.machineIdentifier == Data([9, 9]))
    }

    @Test func `clone rejects existing target`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let lib = VPhoneLibrary(root: root)
        for n in ["a", "b"] {
            _ = try VPhoneBundleOperations.create(
                .init(
                    name: n,
                    cpuCount: 2,
                    memoryMB: 2048,
                    diskSizeGB: 1,
                    romSource: rom,
                    sepromSource: seprom,
                ),
                in: lib,
            )
        }
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "b")) {
            _ = try VPhoneBundleOperations.clone(bundleNamed: "a", to: "b", in: lib)
        }
    }

    // MARK: - Clone state and identity

    /// A stopped machine with the files a booted one has: state files with
    /// distinct bytes, an identity, fixed network settings, a stale control
    /// socket and a snapshot.
    private func makeBootedSource(named name: String, in lib: VPhoneLibrary) throws -> VPhoneBundle {
        let rom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom) }
        let created = try VPhoneBundleOperations.create(
            .init(name: name, cpuCount: 8, memoryMB: 4096, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: lib,
        )
        let url = created.url
        // A small disk image keeps the byte comparisons cheap.
        try Data([0xD1, 0x5C, 0x00, 0x01]).write(to: url.appendingPathComponent("Disk.img"))
        try Data([0x5E, 0x90]).write(to: url.appendingPathComponent("SEPStorage"))
        try Data([1, 2, 3]).write(to: url.appendingPathComponent("nvram.bin"))
        try Data([4]).write(to: url.appendingPathComponent("udid-prediction.txt"))
        try Data([5]).write(to: url.appendingPathComponent("launchpad.json"))
        // A regular file stands in for the socket a stopped VM leaves behind;
        // nothing accepts a connection on it.
        try Data().write(to: url.appendingPathComponent("vphone.sock"))
        let snapshot = url.appendingPathComponent("Snapshots/before-update")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data([0xD1]).write(to: snapshot.appendingPathComponent("Disk.img"))

        typealias Network = VPhoneVirtualMachineManifest.NetworkConfig
        let network = Network(
            mode: .nat,
            macAddress: "aa:bb:cc:dd:ee:ff",
            ipv4: .init(address: "192.168.64.20", prefixLength: 24),
            portForwards: [.init(hostPort: 8022, guestPort: 22)],
            localHostName: "src-phone",
            resolvesMacName: false,
        )
        let manifest = created.manifest.updating(
            machineIdentifier: Data([9, 9]),
            networkConfig: network,
            unlocksAtStartup: true,
            syncsHostLocation: true,
            holdsDeveloperTunnel: true,
        )
        try manifest.write(to: created.configURL)
        return VPhoneBundle(url: url, manifest: manifest)
    }

    @Test func `clone with a new identity clears the identity and colliding network settings`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let src = try makeBootedSource(named: "src", in: lib)
        let sourceConfig = try Data(contentsOf: src.configURL)

        let clone = try VPhoneBundleOperations.clone(bundleNamed: "src", to: "dst", in: lib, newIdentity: true)

        // The identity and the settings that would collide with the source are gone.
        let manifest = try lib.bundle(named: "dst").manifest
        #expect(manifest.machineIdentifier.isEmpty)
        #expect(manifest.networkConfig.macAddress.isEmpty)
        #expect(manifest.networkConfig.ipv4 == nil)
        #expect(manifest.networkConfig.portForwards == nil)
        #expect(manifest.networkConfig.localHostName == nil)
        // Everything else is kept.
        #expect(manifest.networkConfig.mode == .nat)
        #expect(manifest.networkConfig.resolvesMacName == false)
        #expect(manifest.cpuCount == 8)
        #expect(manifest.memorySize == 4096 * 1024 * 1024)
        #expect(manifest.unlocksAtStartup == true)
        #expect(manifest.syncsHostLocation == true)
        #expect(manifest.holdsDeveloperTunnel == true)
        #expect(manifest.romImages?.avpBooter == src.manifest.romImages?.avpBooter)
        #expect(manifest.screenConfig == src.manifest.screenConfig)

        // The ECID's record goes; the state files made by one restore stay byte for byte.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("udid-prediction.txt").path))
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("vphone.sock").path))
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("Snapshots").path))
        for name in ["Disk.img", "SEPStorage", "nvram.bin", "launchpad.json", "AVPBooter.vresearch1.bin"] {
            #expect(try Data(contentsOf: clone.url.appendingPathComponent(name))
                == Data(contentsOf: src.url.appendingPathComponent(name)))
        }

        // The source is untouched.
        #expect(try Data(contentsOf: src.configURL) == sourceConfig)
        #expect(fm.fileExists(atPath: src.url.appendingPathComponent("udid-prediction.txt").path))
        #expect(fm.fileExists(atPath: src.url.appendingPathComponent("Snapshots/before-update/Disk.img").path))
    }

    @Test func `a plain clone keeps the identity but not snapshots or the control socket`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let src = try makeBootedSource(named: "src", in: lib)

        let clone = try VPhoneBundleOperations.clone(bundleNamed: "src", to: "dst", in: lib)

        #expect(clone.manifest.machineIdentifier == Data([9, 9]))
        #expect(clone.manifest.networkConfig == src.manifest.networkConfig)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: clone.url.appendingPathComponent("udid-prediction.txt").path))
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("vphone.sock").path))
        #expect(!fm.fileExists(atPath: clone.url.appendingPathComponent("Snapshots").path))
    }

    @Test func `clone refuses while the source holds a state file open`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let src = try makeBootedSource(named: "src", in: lib)

        let fd = open(src.url.appendingPathComponent("Disk.img").path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        for newIdentity in [false, true] {
            #expect(throws: VPhoneBundleActivityError.running(name: "src", pids: [getpid()])) {
                // This process runs no machine: the clone waits it out first.
                try VPhoneBundleOperations.clone(bundleNamed: "src", to: "dst", in: lib, newIdentity: newIdentity, readerWait: 0.3) {}
            }
            #expect(!FileManager.default.fileExists(atPath: lib.url(forName: "dst").path))
        }
    }

    @Test func `clone waits out a reader that closes the source soon`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let src = try makeBootedSource(named: "src", in: lib)
        let disk = src.url.appendingPathComponent("Disk.img")

        // Like Launchpad's disk meter mapping a template it has just seen
        // appear: New Machine of Launchpad 2.9.0 failed its clone step on it.
        let fd = open(disk.path, O_RDONLY | O_EVTONLY)
        try #require(fd >= 0)
        #expect(VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        let closer = Thread {
            Thread.sleep(forTimeInterval: 0.3)
            close(fd)
        }
        closer.start()
        let clone = try VPhoneBundleOperations.clone(bundleNamed: "src", to: "dst", in: lib)
        #expect(FileManager.default.fileExists(atPath: clone.url.appendingPathComponent("Disk.img").path))
        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
    }

    @Test func `clone refuses a source that starts while it is copied and leaves no copy`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let src = try makeBootedSource(named: "src", in: lib)

        for name in ["Disk.img", "SEPStorage", "nvram.bin"] {
            var fd: Int32 = -1
            defer {
                if fd >= 0 {
                    close(fd)
                }
            }
            #expect(throws: VPhoneBundleActivityError.running(name: "src", pids: [getpid()])) {
                try VPhoneBundleOperations.clone(bundleNamed: "src", to: "dst", in: lib, newIdentity: false, readerWait: 0.2) {
                    // The source starts after the first check passed.
                    fd = open(src.url.appendingPathComponent(name).path, O_RDONLY)
                }
            }
            #expect(fd >= 0)
            #expect(!FileManager.default.fileExists(atPath: lib.url(forName: "dst").path))
        }
    }

    @Test func `lists the network settings a new identity clears`() {
        typealias Network = VPhoneVirtualMachineManifest.NetworkConfig
        #expect(VPhoneBundleOperations.networkSettingsClearedByNewIdentity(.default, sourceName: "src").isEmpty)
        let network = Network(
            mode: .tunnel,
            macAddress: "aa:bb:cc:dd:ee:ff",
            ipv4: .init(address: "10.0.0.5", prefixLength: 24),
            portForwards: [.init(hostPort: 8022, guestPort: 22)],
            localHostName: "phone",
        )
        #expect(VPhoneBundleOperations.networkSettingsClearedByNewIdentity(network, sourceName: "src") == [
            "fixed IPv4 address 10.0.0.5/24",
            "port forwards tcp:127.0.0.1:8022:22",
            "mDNS name phone",
        ])
        // A name derived from the source's name is not listed: it follows the clone.
        let derived = network.with(localHostName: .some(VPhoneNetworking.localHostName(forVMName: "lab_a")))
        #expect(!VPhoneBundleOperations.networkSettingsClearedByNewIdentity(derived, sourceName: "lab_a")
            .contains { $0.hasPrefix("mDNS name") })
    }

    @Test func `clone with a new identity carries a derived mDNS name over to the new name`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = VPhoneLibrary(root: root)
        let src = try makeBootedSource(named: "lab_a", in: lib)
        let derived = src.manifest.networkConfig.with(localHostName: .some(VPhoneNetworking.localHostName(forVMName: "lab_a")))
        try src.manifest.updating(networkConfig: derived).write(to: src.configURL)

        let clone = try VPhoneBundleOperations.clone(bundleNamed: "lab_a", to: "lab_b", in: lib, newIdentity: true)

        #expect(clone.manifest.networkConfig.localHostName == "lab-b")
        #expect(try lib.bundle(named: "lab_a").manifest.networkConfig.localHostName == "lab-a")
    }
}
