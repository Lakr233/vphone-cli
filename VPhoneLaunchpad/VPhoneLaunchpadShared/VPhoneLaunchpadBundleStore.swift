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
    static func isValidVersion(_ value: String) -> Bool {
        matches(value, "^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$") && !value.contains("..")
    }

    static func isValidMachineName(_ value: String) -> Bool {
        matches(value, "^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$") && !value.contains("..")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
