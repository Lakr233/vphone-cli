@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
import VPhoneCoreKit

/// The shipped kernelcache recipes, and the steps of the mix that need no
/// root, kmutil or ipsw.
@Suite("Kernelcache mix")
struct KernelCacheMixerTests {
    @Test("SSH drains large stderr while preserving binary stdout and stdin")
    func largeSSHStreams() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/dd if=/dev/zero bs=65536 count=32 >&2 2>/dev/null; /bin/cat"]
        let input = Data((0 ..< 262144).map { UInt8($0 % 256) })
        let (output, errors) = try RemoteKernelCollectionBuilder.capture(process, input: .data(input))
        #expect(process.terminationStatus == 0)
        #expect(output == input)
        #expect(errors.count == 2 * 1024 * 1024)
    }

    @Test("SSH upload leaves the caller's input file intact")
    func sshInputFile() throws {
        let input = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        let data = Data("archive input".utf8)
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let (output, _) = try RemoteKernelCollectionBuilder.capture(process, input: .file(input))
        #expect(output == data)
        #expect(try Data(contentsOf: input) == data)
    }

    @Test("Root refuses an external patch set before loading its code")
    func externalSetPrivilege() throws {
        let preset = VPhonePatchPreset(identifier: "external", title: "External", patchSets: [
            .external(identifier: "test", path: "/does-not-exist.vphonepatchset"),
        ])
        #expect(throws: PatcherError.self) {
            try FirmwarePipeline.validateExecutionPrivilege(preset: preset, effectiveUID: 0)
        }
        try FirmwarePipeline.validateExecutionPrivilege(preset: preset, effectiveUID: 501)
    }

    @Test("Firmware snapshot excludes disks and untrusted tools, and publication replaces links")
    func confinedFirmwareSnapshot() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let path = realpath(temporary.path, nil) else { throw POSIXError(.ENOENT) }
        let base = URL(fileURLWithPath: String(cString: path))
        free(path)
        defer { try? FileManager.default.removeItem(at: base) }
        let vm = base.appending(path: "vm")
        let restore = vm.appending(path: "Test_Restore")
        try FileManager.default.createDirectory(at: restore.appending(path: ".tools"), withIntermediateDirectories: true)
        try Data("untrusted".utf8).write(to: restore.appending(path: ".tools/tool"))
        try Data("disk".utf8).write(to: vm.appending(path: "Disk.img"))
        let component = restore.appending(path: "component")
        try Data("original".utf8).write(to: component)
        let work = try FirmwarePatchWorkspace(machine: vm, workParent: base.path)
        defer { try? work.remove() }
        #expect(!FileManager.default.fileExists(atPath: work.machine.appending(path: "Disk.img").path))
        #expect(!FileManager.default.fileExists(atPath: work.machine.appending(path: "Test_Restore/.tools").path))
        let outside = base.appending(path: "outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: component)
        try FileManager.default.createSymbolicLink(at: component, withDestinationURL: outside)
        try Data("patched".utf8).write(to: work.machine.appending(path: "Test_Restore/component"))
        try work.publish()
        #expect(try String(contentsOf: component, encoding: .utf8) == "patched")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
        let mixer = KernelCacheMixer(recipes: Self.recipes, cacheDirectory: base)
        let cached = base.appending(path: "cached.im4p")
        try Data("cache".utf8).write(to: cached)
        #expect(try mixer.cachedMix(at: cached) == Data("cache".utf8))
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createSymbolicLink(at: cached, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try mixer.cachedMix(at: cached) }
        try FileManager.default.removeItem(at: component)
        try FileManager.default.createSymbolicLink(at: component, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try FirmwarePatchWorkspace(machine: vm, workParent: base.path) }
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let recipes = KernelCacheRecipes(
        root: repoRoot.appending(path: "VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes"),
    )

    // MARK: - Recipes

    @Test("Every recipe has its map, its bundle list and its donor")
    func recipesAreComplete() throws {
        let bases = try Self.recipes.bases()
        #expect(bases.map(\.id) == [
            "18.1_22B83", "18.2.1_22C161", "18.3.1_22D72", "18.5_22F76", "18.6_22G86", "18.7.2_22H124", "18.7_22H20",
            "26.4_23E246", "26.5_23F77", "26.6_23G71", "26.7_23H20", "homepod_26.5_23L471", "watch_26.4_23T240",
        ])
        for base in bases {
            #expect(FileManager.default.fileExists(atPath: base.symbolsURL.path), "\(base.id)")
            let identifiers = try base.kextIdentifiers()
            #expect(identifiers.count > 100, "\(base.id)")
            #expect(Set(identifiers).count == identifiers.count, "\(base.id)")
            #expect(base.builderLayout == (base.productVersion.hasPrefix("18.") ? .kernelFirst : .kernelLast), "\(base.id)")
            #expect(base.kextSources.contains("base"), "\(base.id)")
            for id in base.donors {
                let donor = try Self.recipes.donor(id: id)
                #expect(donor.symbolsURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
                #expect(donor.cloudOSSource.map { URL(string: $0)?.scheme == "https" } ?? true)
            }
        }
    }

    @Test("A watch links its own kext set against the kernel the iPhone recipe uses")
    func recipeFollowsGuest() throws {
        let watch = try #require(try Self.recipes.bases().first { $0.guest == "watch" })
        let shared = try Self.recipes.bases().filter { $0.kernel.matches(sha: watch.kernel.sha256) }
        #expect(Set(shared.map(\.id)) == ["26.4_23E246", "watch_26.4_23T240"])
        #expect(watch.kextSources == ["watch7c_26.4_23T240", "base", "vphone600_26.4_23E5207q"])
        #expect(try Self.recipes.donor(id: "watch7c_26.4_23T240").cloudOSSource == nil)
    }

    @Test("A HomePod links its own kexts against the 26.5 research kernel, with the security-monitor kexts of the base and the virtual machine's gPTP")
    func homePodRecipe() throws {
        let homePod = try #require(try Self.recipes.bases().first { $0.guest == "homePod" })
        let shared = try Self.recipes.bases().filter { $0.kernel.matches(sha: homePod.kernel.sha256) }
        #expect(Set(shared.map(\.id)) == ["26.5_23F77", "homepod_26.5_23L471"])
        #expect(homePod.kextSources == ["b520_26.5_23L471", "base", "vphone600_26.4_23E5207q"])
        #expect(try homePod.pinnedSources() == [
            "com.apple.driver.AppleMobileFileIntegrity": 1, "com.apple.kec.corecrypto": 1, "com.apple.security.AppleImage4": 1,
            "com.apple.iokit.IOTimeSyncFamily": 1, "com.apple.plugin.IOgPTPPlugin": 2,
        ])
        #expect(try Self.recipes.donor(id: "b520_26.5_23L471").cloudOSSource == nil)
        #expect(try Self.recipes.donor(id: "b520_26.5_23L471").kernel.file == "kernelcache.release.b520")
        for base in try Self.recipes.bases() {
            // A pin outside the bundle list would be ignored, so mix refuses it.
            #expect(try Set(base.pinnedSources().keys).isSubset(of: base.kextIdentifiers()), "\(base.id)")
        }
    }

    @Test("iOS 18 bases link kernel-first against the kexts of the cloudOS 26.1 vphone600 kernelcache")
    func iOS18Recipes() throws {
        let bases = try Self.recipes.bases().filter { $0.productVersion.hasPrefix("18.") }
        #expect(bases.count == 7)
        for base in bases {
            #expect(base.donors == ["vphone600_26.1_23B78"], "\(base.id)")
            #expect(base.guest == nil, "\(base.id)")
        }
        let donor = try Self.recipes.donor(id: "vphone600_26.1_23B78")
        #expect(donor.cloudOSSource?.hasPrefix("https://updates.cdn-apple.com/private-cloud-compute/") == true)
    }

    @Test("A kernel-first base on a kernel-last Mac needs an ssh builder, and says how to name one")
    func remoteBuilderSelection() throws {
        let host = ProcessInfo.processInfo.operatingSystemVersion
        let hostLayout = KernelCollectionBuilder.layout(forMacOS: host)
        func base(_ layout: KernelCacheBase.BuilderLayout) throws -> KernelCacheBase {
            let json = """
            {"id": "t", "productVersion": "18.7", "symbols": "s", "kexts": "k", "builderLayout": "\(layout.rawValue)",
             "kernel": {"file": "f", "sha256": "a", "decompressedSHA256": "b", "kdk": "KDK_18.7_22H42.kdk"}}
            """
            return try JSONDecoder().decode(KernelCacheBase.self, from: Data(json.utf8))
        }
        let other = try base(hostLayout == .kernelLast ? .kernelFirst : .kernelLast)
        #expect {
            try KernelCollectionBuilder.location(for: other, environment: [:])
        } throws: { error in
            "\(error)".contains(KernelCollectionBuilder.sshEnvironmentVariable)
        }
        let same = try base(hostLayout)
        guard case .host = try KernelCollectionBuilder.location(for: same, environment: [:]) else {
            Issue.record("a base of the host's layout links on the host")
            return
        }
        #expect(KernelCollectionBuilder.layout(forMacOS: "15.6.1") == .kernelFirst)
        #expect(KernelCollectionBuilder.layout(forMacOS: "26.4") == .kernelLast)
    }

    @Test("kmutil writes the collection beside the volume")
    func kmutilArguments() {
        let arguments = KernelCollectionBuilder.kmutilArguments(volume: "/tmp/x/bbb", kernel: "/tmp/x/bbb/k", identifiers: ["a", "b"])
        #expect(arguments.suffix(2) == ["-B", "/../bbb.kc"])
        #expect(arguments.contains("-R") && arguments.filter { $0 == "-b" }.count == 2)
    }

    @Test("A kernelcache is matched by the SHA-256 of its container or of its payload, and nothing else")
    func matchesByHash() throws {
        let base = try #require(try Self.recipes.bases().first)
        let mixer = KernelCacheMixer(recipes: Self.recipes, verbose: false)
        let input = KernelCacheMixer.Input(kernelcache: Data("not a kernelcache".utf8), guest: "iPhone", restoreTree: URL(fileURLWithPath: "/"))
        #expect(throws: PatcherError.self) { try mixer.base(for: input) }
        #expect(base.kernel.matches(sha: base.kernel.sha256))
        #expect(base.kernel.matches(sha: base.kernel.decompressedSHA256))
        #expect(!base.kernel.matches(sha: String(repeating: "0", count: 64)))
    }

    @Test("A mix is keyed by its recipe alone, which the root link can compute without ipsw")
    func cacheKeyFollowsRecipe() throws {
        let bases = try Self.recipes.bases()
        let mixer = KernelCacheMixer(recipes: Self.recipes, verbose: false)
        let keys = try bases.map { try mixer.cacheKey(base: $0, donors: $0.donors.map { try Self.recipes.donor(id: $0) }) }
        #expect(Set(keys).count == bases.count)
        let first = try #require(bases.first)
        #expect(try mixer.cacheKey(base: first, donors: first.donors.map { try Self.recipes.donor(id: $0) }) == keys.first)
    }

    @Test("The volume path takes the length of the build root the base records")
    func buildRootLength() throws {
        let root = "/AppleInternal/Library/BuildRoots/4~X/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.6.Internal.sdk"
        let prelink = "<dict><key>_CodelessKextBundlePath</key><string>\(root)/System/Library/Extensions/A.kext</string></dict>"
        #expect(try KernelCacheMixer.buildRootLength(of: Data(repeating: 0, count: 64) + Data(prelink.utf8)) == root.count)
        #expect(throws: PatcherError.self) { try KernelCacheMixer.buildRootLength(of: Data("no prelink info".utf8)) }
    }

    @Test("macOS 26.4 is the first builder that links kernel-last")
    func builderLayout() {
        func layout(_ major: Int, _ minor: Int) -> KernelCacheBase.BuilderLayout {
            KernelCollectionBuilder.layout(forMacOS: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        #expect(layout(15, 6) == .kernelFirst)
        #expect(layout(26, 3) == .kernelFirst)
        #expect(layout(26, 4) == .kernelLast)
        #expect(layout(27, 0) == .kernelLast)
    }

    // MARK: - KDK

    /// A KDK with one kext per identifier, `<name>.kext/Info.plist` and an executable.
    static func kdk(at url: URL, kexts: [String: String]) throws {
        let extensions = url.appending(path: "System/Library/Extensions")
        for (identifier, path) in kexts {
            let bundle = extensions.appending(path: path)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".kext", with: "")
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": name]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appending(path: "Info.plist"))
            try Data(identifier.utf8).write(to: bundle.appending(path: name))
        }
        let coreServices = url.appending(path: "System/Library/CoreServices")
        try FileManager.default.createDirectory(at: coreServices, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["ProductVersion": "26.6", "ProductBuildVersion": "23G71"], format: .xml, options: 0,
        ).write(to: coreServices.appending(path: "SystemVersion.plist"))
        let kernels = url.appending(path: "System/Library/Kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try Data("kernel".utf8).write(to: kernels.appending(path: "kernel"))
    }

    @Test("The mix keeps the wanted base kexts, drops the others and adds the donor's")
    func mixesKDKs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appending(path: "base/KDK_26.6_23G71.kdk")
        let donor = root.appending(path: "donor/KDK_26.4_23E5207i.kdk")
        try Self.kdk(at: base, kexts: [
            "com.apple.kept": "Kept.kext",
            "com.apple.research.only": "ResearchOnly.kext",
            "com.apple.plugin": "ResearchOnly.kext/PlugIns/Plugin.kext",
        ])
        try Self.kdk(at: donor, kexts: [
            "com.apple.kept": "Kept.kext",
            "com.apple.driver.AppleParavirtGPU": "AppleParavirtGPU.kext",
        ])
        let wanted = ["com.apple.kept", "com.apple.plugin", "com.apple.driver.AppleParavirtGPU"]
        let output = root.appending(path: "mix/KDK_26.6_23G71.kdk")
        let (removed, added) = try KernelCacheKDK.mix(base: base, donor: donor, wanted: wanted, output: output)
        #expect(removed.isEmpty) // the research-only parent stays for its wanted plug-in, without its own Info.plist
        #expect(added == ["com.apple.driver.AppleParavirtGPU"])
        #expect(Set(try KernelCacheKDK.bundles(in: output).keys) == Set(wanted))

        let volume = root.appending(path: "volume")
        let kernel = try KernelCacheKDK.makeVolume(kdk: output, identifiers: wanted, output: volume)
        #expect(kernel.path.hasSuffix("Library/Developer/KDKs/KDK_26.6_23G71.kdk/System/Library/Kernels/kernel"))
        #expect(Set(try KernelCacheKDK.bundles(in: volume).keys) == Set(wanted))

        #expect(throws: PatcherError.self) {
            try KernelCacheKDK.mix(base: base, donor: donor, wanted: wanted + ["com.apple.nowhere"], output: output)
        }

        // A donor listed before the base supplies the kexts both have; the
        // kernel's KPI bundles stay the base's.
        let first = root.appending(path: "first/KDK_26.4_23T235.kdk")
        try Self.kdk(at: first, kexts: [
            "com.apple.kept": "Kept.kext",
            "com.apple.kpi.bsd": "System.kext/PlugIns/BSDKernel.kext",
        ])
        try Data("first".utf8).write(to: first.appending(path: "System/Library/Extensions/Kept.kext/Kept"))
        let ordered = root.appending(path: "ordered/KDK_26.6_23G71.kdk")
        let (_, addedBy) = try KernelCacheKDK.mix(
            base: base, sources: [first, base, donor], wanted: ["com.apple.kept", "com.apple.driver.AppleParavirtGPU"], output: ordered,
        )
        #expect(addedBy[first] == ["com.apple.kept"])
        #expect(addedBy[donor] == ["com.apple.driver.AppleParavirtGPU"])
        let kept = ordered.appending(path: "System/Library/Extensions/Kept.kext/Kept")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "first")
        #expect(throws: PatcherError.self) {
            try KernelCacheKDK.mix(base: base, sources: [first, base], wanted: ["com.apple.kpi.bsd"], output: ordered)
        }

        // A pinned kext comes from its source although an earlier one has it.
        let pinned = root.appending(path: "pinned/KDK_26.6_23G71.kdk")
        let (_, addedPinned) = try KernelCacheKDK.mix(
            base: base, sources: [first, base, donor], wanted: ["com.apple.kept"], output: pinned, pinned: ["com.apple.kept": 1],
        )
        #expect(addedPinned[first] == nil)
        let keptPinned = pinned.appending(path: "System/Library/Extensions/Kept.kext/Kept")
        #expect(try String(contentsOf: keptPinned, encoding: .utf8) == "com.apple.kept")
        #expect(throws: PatcherError.self) {
            try KernelCacheKDK.mix(
                base: base, sources: [first, base, donor], wanted: ["com.apple.research.only"], output: pinned,
                pinned: ["com.apple.research.only": 0],
            )
        }
        #expect(throws: PatcherError.self) {
            try KernelCacheKDK.mix(
                base: base, sources: [first, base, donor], wanted: ["com.apple.kept"], output: pinned, pinned: ["com.apple.unknown": 1],
            )
        }

        // The staged volume root links holds no link but the KDK's own.
        try KernelCacheVolumeCopy.checkLinks(in: volume, kdk: "KDK_26.6_23G71.kdk")
        try FileManager.default.createSymbolicLink(
            atPath: volume.appending(path: "System/Library/Extensions/Kept.kext/Kept2").path,
            withDestinationPath: "/etc/master.passwd",
        )
        #expect(throws: PatcherError.self) {
            try KernelCacheVolumeCopy.checkLinks(in: volume, kdk: "KDK_26.6_23G71.kdk")
        }
    }
}
