import Foundation

// MARK: - Layout

/// The root-owned store that holds installed VPhone.bundle versions. Only the
/// helper writes here; the app and every child it starts only read. That is
/// what lets the helper run `vphone-cli` from the store as root: nobody but
/// root can swap the binary between verification and execution.
nonisolated enum VPhoneLaunchpadBundleStore {
    static let root = URL(
        fileURLWithPath: "/Library/Application Support/vphone-launchpad/Bundles",
        isDirectory: true,
    )

    static func directory(version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true)
    }

    static func bundle(version: String) -> URL {
        directory(version: version).appendingPathComponent("VPhone.bundle", isDirectory: true)
    }

    static func executable(version: String, named name: String) -> URL {
        bundle(version: version).appendingPathComponent("Contents/MacOS/\(name)")
    }

    static func receipt(version: String) -> URL {
        directory(version: version).appendingPathComponent("receipt.json")
    }

    /// The Mach-O files whose cdhash the receipt records at install time and
    /// the helper checks again before running anything as root.
    static let pinnedExecutables = ["vphone-cli", "vphone-vm"]
}

// MARK: - Receipt

/// Written by the helper next to each installed bundle.
nonisolated struct VPhoneLaunchpadBundleReceipt: Codable, Equatable, Sendable {
    let version: String
    let sha256: String
    let installedAt: Date
    /// Executable name to hex cdhash.
    let cdhashes: [String: String]

    static func load(version: String) -> VPhoneLaunchpadBundleReceipt? {
        guard let data = try? Data(contentsOf: VPhoneLaunchpadBundleStore.receipt(version: version)) else {
            return nil
        }
        return try? decoder.decode(Self.self, from: data)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

// MARK: - Argument validation

/// Shapes both sides accept for names that end up in paths or argv. The app
/// checks them to give an early message; the helper checks them because it
/// must not trust the app.
nonisolated enum VPhoneLaunchpadNames {
    /// Minimum bundle version for Launchpad's CLI and receipt contract.
    /// Series 2.14: `--preset` takes the path of a preset plist.
    private static let minimumBundleComponents = (2, 15, 0)
    static let minimumBundleVersion =
        "\(minimumBundleComponents.0).\(minimumBundleComponents.1).\(minimumBundleComponents.2)"

    static func isValidVersion(_ value: String) -> Bool {
        matches(value, "^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$") && !value.contains("..")
    }

    /// The bundle's own version inside a store name. Builds that are not
    /// releases carry a suffix: `-local.<build>` for one made on this Mac
    /// (`-local` alone before builds were told apart), and `-ci.<commit>`
    /// for a GitHub Actions artifact.
    static func bundleVersion(of value: String) -> String {
        for pattern in [localSuffixPattern, "-ci\\.[0-9a-f]{7,40}$"] {
            if let suffix = value.range(of: pattern, options: .regularExpression) {
                return String(value[..<suffix.lowerBound])
            }
        }
        return value
    }

    /// `-local` followed by an optional build identifier. Each local build is
    /// stored under its own name, so two builds of one version can be
    /// installed side by side and machines can stay on either.
    private static let localSuffixPattern = "-local(\\.[0-9a-f]{8,64})?$"

    static func isLocalBuild(_ value: String) -> Bool {
        value.range(of: localSuffixPattern, options: .regularExpression) != nil
    }

    static func isCompatibleBundleVersion(_ value: String) -> Bool {
        guard isValidVersion(value) else { return false }
        let parts = bundleVersion(of: value).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return false }
        return (major, minor, patch) >= minimumBundleComponents
    }

    static func isValidMachineName(_ value: String) -> Bool {
        matches(value, "^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$") && !value.contains("..")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
