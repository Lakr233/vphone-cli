// KernelCollectionToolchain.swift — The kmutil a kernelcache was linked with, runnable on this Mac without root.
//
// A kernel collection is laid out by the kernel collection builder of the
// macOS whose kmutil links it (`libKernelCollectionBuilder.dylib`, dyld's
// AppCacheBuilder, in the dyld shared cache): macOS 15 and 26.0–26.3 put the
// kernel first, 26.4 and later last, 27 keeps the auth stubs. Apple records its
// builder in every kernelcache (`_PrelinkKCID`, `KernelManagement_host-<version>`),
// and a mix links like the base only with that version.
//
// The toolchain of a version is that macOS's `/usr/bin/kmutil`, signed ad hoc,
// beside its builder library lifted out of the shared cache
// (`DyldCacheDylibExtractor`) and its KernelManagement configuration. Both come
// from this Mac when its kmutil is that version, else from the recoveryOS
// (BaseSystem) image of the macOS IPSW that ships it: about a gigabyte, read
// out of the IPSW by range requests, decrypted, mounted read-only, and
// deleted again; the toolchain itself is a few megabytes in
// `~/.vphone/kernelcache/kmutil/<version>`.
//
// It runs as the user. dyld loads the builder from `DYLD_LIBRARY_PATH` in
// place of the cached one, and `libvphone-kmutil-shim.dylib` (inserted, from
// the bundle) shows kmutil the user's files as root's, since kmutil ignores
// kexts root does not own, and gives it its own release's configuration file,
// whose format changed in macOS 26.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

struct KernelCollectionToolchain {
    /// A macOS release whose kmutil links like the build host of some base.
    struct Release {
        /// `KernelManagement_executables-<version>`, which the base records as
        /// `KernelManagement_host-<version>`.
        let kernelManagement: String
        let macOS: String
        let build: String
        let ipsw: String

        var layout: KernelCacheBase.BuilderLayout {
            KernelCollectionBuilder.layout(forMacOS: macOS)
        }
    }

    /// The releases whose kmutil was checked against the version the bases
    /// record. A base whose version is missing here (and on this Mac) is refused
    /// before anything is extracted.
    static let releases: [Release] = [
        // iOS 18.1–18.3.1.
        Release(
            kernelManagement: "463.40.2", macOS: "15.1", build: "24B83",
            ipsw: "https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-12340/78D28AC4-CCFC-45D2-BD27-1E5D915E43F9/UniversalMac_15.1_24B83_Restore.ipsw",
        ),
        // iOS 18.5–18.7.2.
        Release(
            kernelManagement: "463.100.7", macOS: "15.6.1", build: "24G90",
            ipsw: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw",
        ),
        // iOS 26.4–26.7, watchOS 26.4, HomePod 26.5.
        Release(
            kernelManagement: "487.100.11", macOS: "26.5", build: "25F71",
            ipsw: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-58869/DFB1CEEF-5619-4591-9924-E20DB2C8FED0/UniversalMac_26.5_25F71_Restore.ipsw",
        ),
        // iOS 27.2.
        Release(
            kernelManagement: "514.40.8", macOS: "27.2.1", build: "26B131",
            ipsw: "https://updates.cdn-apple.com/2026FallFCS/c202a724-db7e-4d56-917b-110aa0226507/UniversalMac_27.2.1_26B131_Restore.ipsw",
        ),
    ]

    static let builderPath = "/usr/lib/libKernelCollectionBuilder.dylib"
    static let configurationPath = "/System/Library/Frameworks/KernelManagement.framework/Resources/com.apple.kernelmanagement.plist"
    static let configurationName = "com.apple.kernelmanagement.plist"
    static let shimName = "libvphone-kmutil-shim.dylib"
    static let manifestName = "toolchain.json"

    struct Manifest: Codable, Equatable {
        var kernelManagement: String
        var macOS: String
        var build: String
        /// `host`, or the IPSW it came from.
        var source: String
        /// Bump when the extraction changes, so cached toolchains are rebuilt.
        var revision: Int
    }

    static let revision = 1

    let directory: URL
    let manifest: Manifest

    var kmutil: URL { directory.appending(path: "kmutil") }
    var layout: KernelCacheBase.BuilderLayout { KernelCollectionBuilder.layout(forMacOS: manifest.macOS) }

    /// The environment kmutil runs in.
    func environment(shim: URL) -> [String: String] {
        [
            "DYLD_LIBRARY_PATH": directory.path,
            "DYLD_INSERT_LIBRARIES": shim.path,
            "VPHONE_KMUTIL_CONFIG_FROM": Self.configurationPath,
            "VPHONE_KMUTIL_CONFIG_TO": directory.appending(path: Self.configurationName).path,
        ]
    }

    /// The shim beside the running `vphone-cli`.
    static func shim() throws -> URL {
        let url = VPhoneResources.siblingExecutable(shimName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound("\(shimName) beside vphone-cli (\(url.path)); rebuild VPhone.bundle")
        }
        return url
    }

    // MARK: - Versions

    /// The builder version a kernelcache records: `KernelManagement_host-<version>`.
    static func builderVersion(of payload: Data) throws -> String {
        let marker = Data("KernelManagement_host-".utf8)
        guard let range = payload.range(of: marker) else {
            throw PatcherError.invalidFormat("the base kernelcache records no builder version (_PrelinkKCID)")
        }
        let digits = payload[range.upperBound...].prefix { $0 == UInt8(ascii: ".") || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
        guard !digits.isEmpty else {
            throw PatcherError.invalidFormat("the base kernelcache's builder version is empty")
        }
        return String(decoding: digits, as: UTF8.self)
    }

    /// The version of a kmutil binary: `KernelManagement_executables-<version>`.
    static func kmutilVersion(of binary: Data) -> String? {
        guard let range = binary.range(of: Data("KernelManagement_executables-".utf8)) else { return nil }
        let digits = binary[range.upperBound...].prefix { $0 == UInt8(ascii: ".") || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
        return digits.isEmpty ? nil : String(decoding: digits, as: UTF8.self)
    }

    static var hostKmutilVersion: String? {
        (try? Data(contentsOf: URL(fileURLWithPath: "/usr/bin/kmutil"), options: .alwaysMapped)).flatMap(kmutilVersion(of:))
    }

    static var hostMacOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }

    /// Where the toolchain of `version` comes from: this Mac or a release, or
    /// nil when neither has it.
    enum Source {
        case host
        case release(Release)
    }

    static func source(for version: String, hostVersion: String? = hostKmutilVersion) -> Source? {
        if hostVersion == version {
            return .host
        }
        return releases.first { $0.kernelManagement == version }.map(Source.release)
    }

    /// Checks before any extraction that `base`, whose kernelcache records
    /// `version`, has a toolchain, and that it links in the base's layout.
    static func check(version: String, base: KernelCacheBase) throws -> Source {
        guard let source = source(for: version) else {
            let known = releases.map { "\($0.kernelManagement) (macOS \($0.macOS))" }.joined(separator: ", ")
            throw PatcherError.invalidFormat(
                "the \(base.id) kernelcache was linked by KernelManagement \(version), and no macOS here ships that kmutil "
                    + "(this Mac: \(hostKmutilVersion ?? "none"); known: \(known)). Add its macOS release to KernelCollectionToolchain.releases.",
            )
        }
        let layout = switch source {
        case .host: KernelCollectionBuilder.layout(forMacOS: hostMacOS)
        case let .release(release): release.layout
        }
        guard layout == base.builderLayout else {
            throw PatcherError.invalidFormat("KernelManagement \(version) links \(layout.rawValue), and the \(base.id) recipe says \(base.builderLayout.rawValue)")
        }
        return source
    }

    // MARK: - Preparing

    /// The toolchain of `version` in `cache`, prepared on first use.
    static func prepare(version: String, base: KernelCacheBase, cache: URL, log: (String) -> Void) throws -> KernelCollectionToolchain {
        let source = try check(version: version, base: base)
        let directory = cache.appending(path: version)
        if let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appending(path: manifestName))),
           manifest.revision == revision, manifest.kernelManagement == version
        {
            return KernelCollectionToolchain(directory: directory, manifest: manifest)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let work = cache.appending(path: ".work-\(UUID().uuidString.prefix(8).lowercased())")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let staging = work.appending(path: "toolchain")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let manifest: Manifest
        switch source {
        case .host:
            log("  [kc] kmutil \(version): this Mac's (macOS \(hostMacOS))")
            try assemble(
                kmutil: URL(fileURLWithPath: "/usr/bin/kmutil"), cache: hostSharedCache(),
                configuration: URL(fileURLWithPath: configurationPath), into: staging, version: version,
            )
            manifest = Manifest(kernelManagement: version, macOS: hostMacOS, build: hostBuild, source: "host", revision: revision)
        case let .release(release):
            log("  [kc] kmutil \(version): from the recoveryOS of macOS \(release.macOS) (\(release.build))")
            try fromRelease(release, work: work, into: staging, log: log)
            manifest = Manifest(kernelManagement: version, macOS: release.macOS, build: release.build, source: release.ipsw, revision: revision)
        }
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: manifestName))
        let toolchain = KernelCollectionToolchain(directory: staging, manifest: manifest)
        try toolchain.selfTest()
        try? fm.removeItem(at: directory)
        try fm.moveItem(at: staging, to: directory)
        log("  [kc] kmutil \(version) ready in \(directory.path)")
        return KernelCollectionToolchain(directory: directory, manifest: manifest)
    }

    private static var hostBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The shared cache the running system loaded: the OS cryptex's since macOS 13.
    static func hostSharedCache() throws -> URL {
        for path in ["/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e", "/System/Library/dyld/dyld_shared_cache_arm64e"]
            where FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }
        throw PatcherError.fileNotFound("this Mac's arm64e dyld shared cache")
    }

    /// Puts the arm64e kmutil, the builder lifted out of `cache` and the
    /// configuration into `directory`, each signed ad hoc where it is code.
    static func assemble(kmutil: URL, cache: URL, configuration: URL, into directory: URL, version: String) throws {
        let binary = try Data(contentsOf: kmutil)
        guard kmutilVersion(of: binary) == version else {
            throw PatcherError.invalidFormat("\(kmutil.path) is KernelManagement \(kmutilVersion(of: binary) ?? "unknown"), not \(version)")
        }
        let tool = directory.appending(path: "kmutil")
        try arm64eSlice(of: binary).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: tool.path)
        let library = directory.appending(path: "libKernelCollectionBuilder.dylib")
        try DyldCacheDylibExtractor.extract(cache: cache, path: builderPath, to: library)
        try FileManager.default.copyItem(at: configuration, to: directory.appending(path: configurationName))
        for code in [tool, library] {
            try KernelCacheMixer.run(
                "/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.vphone.kmutil.\(version)", code.path],
                log: directory.deletingLastPathComponent().appending(path: "codesign.log"),
            )
        }
    }

    /// The plain arm64e slice of a Mach-O (macOS 27's kmutil also carries arm64e.x1).
    static func arm64eSlice(of binary: Data) throws -> Data {
        func be32(_ offset: Int) -> UInt32 { UInt32(bigEndian: binary.le32(offset)) }
        func be64(_ offset: Int) -> UInt64 { UInt64(bigEndian: binary.le64(offset)) }
        let magic = be32(0)
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else {
            guard binary.le32(0) == 0xFEED_FACF, binary.le32(4) == 0x0100_000C, binary.le32(8) & 0xFF == 2 else {
                throw PatcherError.invalidFormat("kmutil is not an arm64e Mach-O")
            }
            return binary
        }
        let wide = magic == 0xCAFE_BABF
        for index in 0 ..< Int(be32(4)) {
            let entry = 8 + index * (wide ? 32 : 20)
            let type = be32(entry)
            let subtype = be32(entry + 4)
            let offset = wide ? Int(be64(entry + 8)) : Int(be32(entry + 8))
            let size = wide ? Int(be64(entry + 16)) : Int(be32(entry + 12))
            if type == 0x0100_000C, subtype & 0x00FF_FFFF == 2 {
                return binary.subdata(in: binary.startIndex + offset ..< binary.startIndex + offset + size)
            }
        }
        throw PatcherError.invalidFormat("kmutil has no arm64e slice")
    }

    /// Reads the recoveryOS image out of `release`'s IPSW, and assembles the
    /// toolchain from it.
    private static func fromRelease(_ release: Release, work: URL, into directory: URL, log: (String) -> Void) throws {
        guard let url = URL(string: release.ipsw) else {
            throw PatcherError.invalidFormat("bad IPSW URL \(release.ipsw)")
        }
        let encrypted = work.appending(path: "BaseSystem.dmg.aea")
        try vphoneRunBlocking {
            let zip = try await VPhoneRemoteZip.open(url)
            let manifest = try await zip.read(zip.entry(endingWith: "BuildManifest.plist"))
            guard let plist = try PropertyListSerialization.propertyList(from: manifest, format: nil) as? [String: Any],
                  let identities = plist["BuildIdentities"] as? [[String: Any]],
                  let path = identities.lazy.compactMap({ identity in
                      ((identity["Manifest"] as? [String: Any])?["BaseSystem"] as? [String: Any])
                          .flatMap { ($0["Info"] as? [String: Any])?["Path"] as? String }
                  }).first
            else {
                throw PatcherError.invalidFormat("macOS \(release.macOS)'s BuildManifest names no BaseSystem image")
            }
            let entry = try zip.entry(endingWith: path)
            let megabytes = entry.compressedSize >> 20
            print("  [kc] downloading \(path) (\(megabytes) MB) from macOS \(release.macOS)")
            let step = Progress(total: entry.compressedSize)
            try await zip.download(entry, to: encrypted) { done, total in
                if let percent = step.advance(to: done) {
                    print("  [kc] \(percent)% of \(total >> 20) MB")
                }
            }
        }
        log("  [kc] decrypting the recoveryOS image")
        let image = work.appending(path: "BaseSystem.dmg")
        let key = try VPhoneAEA.embeddedSymmetricKey(of: encrypted) ?? vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: encrypted) }
        let toolLog = work.appending(path: "tools.log")
        try KernelCacheMixer.run("/usr/bin/aea", ["decrypt", "-i", encrypted.path, "-o", image.path, "-key-value", key], log: toolLog)
        try? FileManager.default.removeItem(at: encrypted)

        let mount = work.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try KernelCacheMixer.run(
            "/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mount.path, image.path], log: toolLog,
        )
        defer { try? KernelCacheMixer.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], log: toolLog) }
        let dyld = mount.appending(path: "System/Library/dyld")
        let cache = dyld.appending(path: "dyld_shared_cache_arm64e")
        guard FileManager.default.fileExists(atPath: cache.path) else {
            throw PatcherError.fileNotFound("the arm64e dyld shared cache in macOS \(release.macOS)'s recoveryOS")
        }
        log("  [kc] extracting kmutil and \(builderPath)")
        try assemble(
            kmutil: mount.appending(path: "usr/bin/kmutil"), cache: cache,
            configuration: mount.appending(path: "System/Library/Frameworks/KernelManagement.framework/Versions/A/Resources/\(configurationName)"),
            into: directory, version: release.kernelManagement,
        )
    }

    /// Runs `kmutil create --help` with the toolchain, which loads the builder
    /// and reads the configuration, so a broken toolchain is never cached.
    func selfTest() throws {
        let log = directory.deletingLastPathComponent().appending(path: "selftest.log")
        try KernelCacheMixer.run(kmutil.path, ["create", "--help"], environment: environment(shim: Self.shim()), log: log)
    }

    /// A percentage, at most every 10%.
    private final class Progress: @unchecked Sendable {
        let total: UInt64
        private var reported = 0
        private let lock = NSLock()

        init(total: UInt64) {
            self.total = total
        }

        func advance(to done: UInt64) -> Int? {
            lock.withLock {
                let percent = total == 0 ? 100 : Int(done * 100 / total)
                guard percent >= reported + 10 else { return nil }
                reported = percent - percent % 10
                return reported
            }
        }
    }
}
