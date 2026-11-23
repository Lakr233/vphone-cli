import Foundation
import Testing
@testable import VPhoneCoreKit

struct ManifestTests {
    private func sampleManifest() -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin", avpSEPBooter: "AVPSEPBooter.vresearch1.bin"),
        )
    }

    @Test func `round trips through plist`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.cpuCount == 8)
        #expect(loaded.memorySize == 8 * 1024 * 1024 * 1024)
        #expect(loaded.romImages?.avpBooter == "AVPBooter.vresearch1.bin")
    }

    @Test func `updating replaces only given fields`() {
        let updated = sampleManifest().updating(cpuCount: 4, memorySize: nil)
        #expect(updated.cpuCount == 4)
        #expect(updated.memorySize == 8 * 1024 * 1024 * 1024)
        // networkConfig is preserved when not passed.
        #expect(updated.networkConfig.mode == .nat)
    }

    @Test func `old manifests keep the hardware keyboard enabled`() throws {
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(sampleManifest())
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["hardwareKeyboardEnabled"] == nil)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(loaded.usesHardwareKeyboard)
    }

    @Test(arguments: [true, false])
    func `keyboard setting survives plist and unrelated edits`(enabled: Bool) throws {
        let original = sampleManifest().updating(hardwareKeyboardEnabled: enabled)
        let data = try PropertyListEncoder().encode(original)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(loaded.usesHardwareKeyboard == enabled)
        #expect(loaded.hardwareKeyboardEnabled == enabled)
        let edited = loaded.updating(cpuCount: 4, machineIdentifier: Data([1, 2, 3]))
        #expect(edited.usesHardwareKeyboard == enabled)
        #expect(edited.cpuCount == 4)
        #expect(edited.machineIdentifier == Data([1, 2, 3]))
        #expect(edited.diskImage == original.diskImage)
        #expect(edited.networkConfig == original.networkConfig)
        #expect(edited.updating(guestDevice: .default).usesHardwareKeyboard == enabled)
        #expect(edited.updating(hardwareKeyboardEnabled: !enabled).usesHardwareKeyboard == !enabled)
    }

    @Test func `old manifests do not unlock at startup`() throws {
        let data = try PropertyListEncoder().encode(sampleManifest())
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["unlocksAtStartup"] == nil)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(!loaded.unlocksScreenAtStartup)
    }

    @Test(arguments: [true, false])
    func `unlock setting survives plist and unrelated edits`(enabled: Bool) throws {
        let original = sampleManifest().updating(unlocksAtStartup: enabled)
        let data = try PropertyListEncoder().encode(original)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(loaded.unlocksAtStartup == enabled)
        let edited = loaded.updating(cpuCount: 4, hardwareKeyboardEnabled: !enabled)
        #expect(edited.unlocksScreenAtStartup == enabled)
        #expect(edited.updating(guestDevice: .default).unlocksScreenAtStartup == enabled)
        #expect(edited.updating(unlocksAtStartup: !enabled).unlocksScreenAtStartup == !enabled)
    }

    @Test func `old manifests do not share the host location`() throws {
        let data = try PropertyListEncoder().encode(sampleManifest())
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["syncsHostLocation"] == nil)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(!loaded.sharesHostLocation)
    }

    @Test(arguments: [true, false])
    func `host location setting survives plist and unrelated edits`(enabled: Bool) throws {
        let original = sampleManifest().updating(syncsHostLocation: enabled)
        let data = try PropertyListEncoder().encode(original)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(loaded.syncsHostLocation == enabled)
        let edited = loaded.updating(cpuCount: 4, unlocksAtStartup: !enabled)
        #expect(edited.sharesHostLocation == enabled)
        #expect(edited.updating(guestDevice: .default).sharesHostLocation == enabled)
        #expect(edited.updating(syncsHostLocation: !enabled).sharesHostLocation == !enabled)
    }

    @Test func `old manifests do not hold the developer tunnel`() throws {
        let data = try PropertyListEncoder().encode(sampleManifest())
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["holdsDeveloperTunnel"] == nil)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(!loaded.keepsDeveloperTunnelOpen)
    }

    @Test(arguments: [true, false])
    func `developer tunnel setting survives plist and unrelated edits`(enabled: Bool) throws {
        let original = sampleManifest().updating(holdsDeveloperTunnel: enabled)
        let data = try PropertyListEncoder().encode(original)
        let loaded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(loaded.holdsDeveloperTunnel == enabled)
        let edited = loaded.updating(cpuCount: 4, syncsHostLocation: !enabled)
        #expect(edited.keepsDeveloperTunnelOpen == enabled)
        #expect(edited.updating(guestDevice: .default).keepsDeveloperTunnelOpen == enabled)
        #expect(edited.updating(romImages: .default).keepsDeveloperTunnelOpen == enabled)
        #expect(edited.updating(holdsDeveloperTunnel: !enabled).keepsDeveloperTunnelOpen == !enabled)
    }

    @Test func `network config round trips through plist`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let net = VPhoneVirtualMachineManifest.NetworkConfig(mode: .bridged, macAddress: "", bridgeInterface: "en0")
        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().updating(networkConfig: net).write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.networkConfig.mode == .bridged)
        #expect(loaded.networkConfig.bridgeInterface == "en0")
    }

    /// Manifests written before bridgeInterface existed omit that key; they must
    /// still decode, with bridgeInterface defaulting to nil.
    @Test func `decodes manifest without bridge interface key`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url) // default network → bridgeInterface nil
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("bridgeInterface")) // nil optional is omitted from the plist

        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.networkConfig.bridgeInterface == nil)
    }

    // MARK: - File names

    /// Writes the sample manifest, then sets one file-name field (a top-level
    /// key, or `romImages.<key>`) to `value` in the raw plist.
    private func writeManifest(setting field: String, to value: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)
        var plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil,
        ) as? [String: Any])
        if field.hasPrefix("romImages.") {
            var roms = try #require(plist["romImages"] as? [String: Any])
            roms[String(field.dropFirst("romImages.".count))] = value
            plist["romImages"] = roms
        } else {
            plist[field] = value
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    /// An imported config.plist is untrusted: vphone-vm opens the NVRAM
    /// file and attaches the disk read-write, so every file name must stay
    /// directly inside the VM folder.
    @Test(arguments: ["diskImage", "nvramStorage", "sepStorage", "romImages.avpBooter", "romImages.avpSEPBooter"])
    func `file names that leave the bundle fail to load`(field: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for value in ["../x", "/abs", "a/b", "..", ".", ""] {
            let url = try writeManifest(setting: field, to: value, in: dir)
            do {
                _ = try VPhoneVirtualMachineManifest.load(from: url)
                Issue.record("\(field) = \"\(value)\" was accepted")
            } catch let error as VPhoneManifestError {
                guard case let .invalidPath(_, reported) = error else {
                    Issue.record("Expected an invalid path error for \(field), got \(error)")
                    continue
                }
                #expect(reported == field)
            }
        }
    }

    @Test func `default file names load`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try VPhoneVirtualMachineManifest.newVM().write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.diskImage == "Disk.img")
        #expect(try loaded.resolve(path: loaded.nvramStorage, in: dir) == dir.appendingPathComponent("nvram.bin"))
        #expect(throws: VPhoneManifestError.self) {
            _ = try loaded.resolve(path: "../nvram.bin", in: dir)
        }
    }

    @Test func `plain file name rule`() {
        #expect(VPhoneVirtualMachineManifest.isPlainFileName("Disk.img"))
        #expect(VPhoneVirtualMachineManifest.isPlainFileName("..hidden"))
        #expect(!VPhoneVirtualMachineManifest.isPlainFileName("a\u{0}b"))
        #expect(!VPhoneVirtualMachineManifest.isPlainFileName(String(repeating: "x", count: 256)))
    }

    /// write(to:) is atomic, so a config.plist that is a symbolic link is
    /// replaced rather than written through.
    @Test func `write replaces a symbolic link`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = dir.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let url = dir.appendingPathComponent("config.plist")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)

        try sampleManifest().write(to: url)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        #expect(VPhoneVirtualMachineManifest.fileKind(at: url) == .regularFile)
    }

    // MARK: - TASK-001: intercept / interceptBlockQUIC (REQ-001)

    /// Encode `sampleManifest()`, overlay the given `networkConfig` entries,
    /// and return the plist data so a decode can be asserted.
    private func manifestData(networkConfig overrides: [String: Any]) throws -> Data {
        let data = try PropertyListEncoder().encode(sampleManifest())
        var plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var net = (plist["networkConfig"] as? [String: Any]) ?? [:]
        for (key, value) in overrides { net[key] = value }
        plist["networkConfig"] = net
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
    }

    private func decodeManifest(networkConfig overrides: [String: Any]) throws
        -> VPhoneVirtualMachineManifest {
        try PropertyListDecoder().decode(
            VPhoneVirtualMachineManifest.self, from: manifestData(networkConfig: overrides))
    }

    private typealias Cfg = VPhoneVirtualMachineManifest.NetworkConfig

    @Test func `intercept endpoint parses and round-trips`() throws {
        let loaded = try decodeManifest(networkConfig: ["intercept": "127.0.0.1:1080"])
        #expect(loaded.networkConfig.intercept == "127.0.0.1:1080")
        let parsed = try Cfg.parseInterceptEndpoint("127.0.0.1:1080")
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 1080)
        #expect(parsed.user == nil)
        #expect(parsed.password == nil)

        // Round-trips through encode/decode.
        let data = try PropertyListEncoder().encode(loaded)
        let again = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(again.networkConfig.intercept == "127.0.0.1:1080")
    }

    /// Decode keeps the raw string verbatim; grammar validation is at
    /// config/plan time, not manifest decode (REQ-001).
    @Test func `intercept decodes verbatim without grammar validation`() throws {
        let loaded = try decodeManifest(networkConfig: ["intercept": "not a valid endpoint"])
        #expect(loaded.networkConfig.intercept == "not a valid endpoint")
    }

    @Test func `bracketed IPv6 intercept parses with brackets stripped`() throws {
        let parsed = try Cfg.parseInterceptEndpoint("[::1]:1080")
        #expect(parsed.host == "::1")
        #expect(parsed.port == 1080)
    }

    @Test func `socks5 URL parses credentials`() throws {
        let userOnly = try Cfg.parseInterceptEndpoint("socks5://u@127.0.0.1:1080")
        #expect(userOnly.host == "127.0.0.1")
        #expect(userOnly.port == 1080)
        #expect(userOnly.user == "u")
        #expect(userOnly.password == nil)

        let userPass = try Cfg.parseInterceptEndpoint("socks5://u:p@127.0.0.1:1080")
        #expect(userPass.user == "u")
        #expect(userPass.password == "p")
    }

    /// The three recognised tokens are preserved verbatim for later
    /// substitution: `${vm.name}`/`${vm.id}` as the username, `${env:NAME}`
    /// as the password (its colon would otherwise split the userinfo).
    @Test func `valid intercept tokens are accepted`() throws {
        #expect(try Cfg.parseInterceptEndpoint("socks5://${vm.name}@h:1080").user == "${vm.name}")
        #expect(try Cfg.parseInterceptEndpoint("socks5://${vm.id}@h:1080").user == "${vm.id}")
        #expect(try Cfg.parseInterceptEndpoint("socks5://u:${env:PW}@h:1080").password == "${env:PW}")
    }

    @Test(arguments: [
        "127.0.0.1",        // missing port
        "127.0.0.1:0",      // port out of range
        "127.0.0.1:65536",  // port out of range
        ":1080",            // empty host
        "http://h:1",       // wrong scheme
        "socks5://h:abc",   // non-numeric port
        "socks5://${bogus}@h:1", // unrecognised token
    ])
    func `malformed intercept is rejected by the parser`(value: String) {
        #expect(throws: (any Error).self) { try Cfg.parseInterceptEndpoint(value) }
    }

    /// A literal password never leaks: the reject message redacts it to `***`,
    /// whether or not `URLComponents` parses the value.
    @Test(arguments: ["socks5://u:s3cret@h:abc", "socks5://u:s3cret@:1080"])
    func `a literal password is redacted in the reject message`(value: String) {
        do {
            _ = try Cfg.parseInterceptEndpoint(value)
            Issue.record("expected \(value) to be rejected")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("***"))
            #expect(!message.contains("s3cret"))
        }
    }

    @Test func `non-boolean interceptBlockQUIC is rejected`() throws {
        for bad: Any in ["yes", 1] {
            #expect(throws: DecodingError.self) {
                _ = try decodeManifest(networkConfig: ["interceptBlockQUIC": bad])
            }
        }
    }

    @Test func `interceptBlockQUIC defaults false and round-trips true`() throws {
        #expect(!(try decodeManifest(networkConfig: [:]).networkConfig.blockQUIC))
        let on = try decodeManifest(networkConfig: ["interceptBlockQUIC": true])
        #expect(on.networkConfig.blockQUIC)
        let data = try PropertyListEncoder().encode(on)
        let again = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: data)
        #expect(again.networkConfig.blockQUIC)
    }
}
