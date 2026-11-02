import Darwin
import MachO

// MARK: - Bootstrap platform

/// Which Irisin package a guest takes.
///
/// Irisin publishes three: RootHide and rootless for iOS, and RootHide alone
/// for Apple TV, whose daemon and helper are tvOS binaries that refuse any
/// other bootstrap (Irisin's Documentation/AppleTV.md). A TV guest runs
/// `vphoned-tvos`, built against the AppleTVOS SDK. Its platform decides
/// whether Irisin's tvOS binaries load, so it is what this reads rather than
/// the product type: the Apple TV HD and the 4K take the same package.
enum GuestBootstrapPlatform {
    /// The package for a layout, or nil when this system has none for it.
    static func packageArchitecture(layout: String, tvOS: Bool) -> String? {
        switch (layout, tvOS) {
        case ("roothide", false): "iphoneos-arm64e"
        case ("rootless", false): "iphoneos-arm64"
        case ("roothide", true): "appletvos-arm64e"
        default: nil
        }
    }

    /// The iOS packages carry the Irisin app. The Apple TV package has none
    /// yet: its postinst loads the daemon and registers nothing. An app a
    /// later one carries is checked and registered as iOS's is.
    static func packageRequiresApp(architecture: String) -> Bool {
        !architecture.hasPrefix("appletvos-")
    }

    /// The repositories Irisin's onboarding offers, as its
    /// `RecommendedRepositories` picks them from the app's bundle: the
    /// managed list when it has entries, else the one for the app's
    /// bootstrap, each entry kept when `majorVersion` is within its bounds.
    static func recommendedSources(managed: [[String: Any]]?, packaged: [[String: Any]]?, majorVersion: Int) -> [String] {
        let list = [managed, packaged].lazy.compactMap(\.self).first { !$0.isEmpty } ?? []
        return list.compactMap { entry in
            guard let source = entry["source"] as? String else { return nil }
            if let minimum = entry["minimumSystemVersion"] as? Int, majorVersion < minimum { return nil }
            if let maximum = entry["maximumSystemVersion"] as? Int, majorVersion > maximum { return nil }
            return source
        }
    }

    /// Whether dyld runs this process as tvOS.
    static let isTVOS = mainExecutablePlatform() == UInt32(PLATFORM_TVOS)

    /// The platform the main executable's `LC_BUILD_VERSION` names.
    static func mainExecutablePlatform() -> UInt32? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        return buildPlatform(UnsafeRawPointer(header))
    }

    static func buildPlatform(_ image: UnsafeRawPointer) -> UInt32? {
        let header = image.load(as: mach_header_64.self)
        guard header.magic == UInt32(MH_MAGIC_64) else { return nil }
        var command = image + MemoryLayout<mach_header_64>.size
        for _ in 0 ..< header.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_BUILD_VERSION) {
                return command.load(as: build_version_command.self).platform
            }
            command += Int(load.cmdsize)
        }
        return nil
    }
}
