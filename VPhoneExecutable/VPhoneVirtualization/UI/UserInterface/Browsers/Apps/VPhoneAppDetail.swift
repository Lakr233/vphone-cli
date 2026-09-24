import Foundation

// MARK: - App Detail

/// What the App Info inspector shows for one app, filled in as each guest
/// call returns: `apps.info`, `apps.binary`, `apps.url_schemes` and
/// `apps.network_policy`.
struct VPhoneAppDetail {
    let bundleID: String

    // apps.info
    var name = ""
    var version = ""
    var build = ""
    var type = ""
    var signer = ""
    var minimumOS = ""
    var sdk = ""
    var bundlePath = ""
    var dataPath = ""
    var groupContainers: [VPhoneAppContainer] = []
    var claimedSchemes: [String] = []
    var hasInfo = false
    var infoError: String?

    // apps.binary
    var executable = ""
    var encrypted: Bool?
    var entitlements: [VPhoneAppEntitlement] = []
    var entitlementsPlist = ""
    var signingError: String?
    var hasBinary = false
    var binaryError: String?

    /// apps.url_schemes
    var declaredSchemes: [String] = []

    // apps.network_policy
    var networkPolicy: VPhoneAppNetworkPolicy?
    var networkPolicyError: String?

    init(bundleID: String, record: VPhoneAppRecord? = nil) {
        self.bundleID = bundleID
        guard let record else { return }
        name = record.name
        version = record.version
        build = record.build
        bundlePath = record.bundlePath
        dataPath = record.dataPath
    }

    var displayName: String {
        name.isEmpty ? bundleID : name
    }

    /// Schemes from the bundle's Info.plist first, then any LaunchServices
    /// also records as claimed.
    var urlSchemes: [String] {
        var seen = Set<String>()
        return (declaredSchemes + claimedSchemes).filter { seen.insert($0).inserted }
    }

    mutating func apply(info: [String: Any]) {
        name = info.string("name") ?? name
        version = info.string("version") ?? version
        build = info.string("build") ?? build
        type = info.string("type") ?? ""
        signer = info.string("signer") ?? ""
        minimumOS = info.string("minimum_os") ?? ""
        sdk = info.string("sdk") ?? ""
        bundlePath = info.string("bundle_path") ?? bundlePath
        dataPath = info.string("data_path") ?? ""
        executable = info.string("executable") ?? executable
        groupContainers = (info.object("group_containers") ?? [:])
            .compactMap { key, value in
                (value as? String).map { VPhoneAppContainer(identifier: key, path: $0) }
            }
            .sorted { $0.identifier < $1.identifier }
        claimedSchemes = info["schemes"] as? [String] ?? []
        if !hasBinary {
            applySigning(info)
        }
        hasInfo = true
        infoError = nil
    }

    mutating func apply(binary: [String: Any]) {
        executable = binary.string("executable") ?? executable
        applySigning(binary)
        hasBinary = true
        binaryError = nil
    }

    private mutating func applySigning(_ result: [String: Any]) {
        encrypted = result.bool("encrypted") ?? encrypted
        signingError = result.string("signing_error")
        let dictionary = result.object("entitlements") ?? [:]
        entitlements = VPhoneAppEntitlement.entries(from: dictionary)
        entitlementsPlist = VPhoneAppEntitlement.plistText(dictionary)
    }
}

// MARK: - Group Container

struct VPhoneAppContainer: Identifiable, Hashable {
    let identifier: String
    let path: String

    var id: String {
        identifier
    }
}

// MARK: - Entitlement

/// One top-level entitlement key with its value rendered as readable lines.
struct VPhoneAppEntitlement: Identifiable, Hashable {
    let key: String
    let value: String

    var id: String {
        key
    }

    static func entries(from dictionary: [String: Any]) -> [VPhoneAppEntitlement] {
        dictionary.keys.sorted().map { key in
            VPhoneAppEntitlement(key: key, value: render(dictionary[key] as Any, indent: ""))
        }
    }

    /// The entitlements as an XML property list, the form codesign prints.
    static func plistText(_ dictionary: [String: Any]) -> String {
        guard !dictionary.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isContainer(_ value: Any) -> Bool {
        (value as? [Any]).map { !$0.isEmpty } ?? (value as? [String: Any]).map { !$0.isEmpty } ?? false
    }

    private static func render(_ value: Any, indent: String) -> String {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return array.map { isContainer($0) ? render($0, indent: indent) : indent + render($0, indent: indent) }
                .joined(separator: "\n")
        case let dictionary as [String: Any]:
            guard !dictionary.isEmpty else { return "{}" }
            return dictionary.keys.sorted().map { key in
                let value = dictionary[key] as Any
                return isContainer(value)
                    ? "\(indent)\(key):\n\(render(value, indent: indent + "  "))"
                    : "\(indent)\(key) = \(render(value, indent: indent))"
            }.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Network Policy

/// CoreTelephony's per-app data policy: the Wireless Data switch that can
/// leave a sideloaded app without network access.
struct VPhoneAppNetworkPolicy {
    struct Entry: Identifiable, Hashable {
        let title: String
        let value: String

        var id: String {
            title
        }
    }

    let allowed: Bool
    let changed: Bool?
    let entries: [Entry]

    init(json: [String: Any]) {
        allowed = json.bool("allowed") ?? false
        changed = json.bool("changed")
        let policy = json.object("policy") ?? [:]
        entries = policy.keys.sorted().map { key in
            Entry(title: Self.title(forKey: key), value: Self.title(forValue: policy.string(key) ?? ""))
        }
    }

    private static func title(forKey key: String) -> String {
        switch key {
        case "kCTCellularDataUsagePolicy": String(localized: "Cellular", bundle: VPhoneLocalization.bundle)
        case "kCTWiFiDataUsagePolicy": String(localized: "Wi-Fi", bundle: VPhoneLocalization.bundle)
        default: key
        }
    }

    /// `kCTCellularDataUsagePolicyAlwaysAllow` → `Always Allow`.
    private static func title(forValue value: String) -> String {
        let prefix = "kCTCellularDataUsagePolicy"
        guard value.hasPrefix(prefix), value.count > prefix.count else { return value }
        var words = ""
        for character in value.dropFirst(prefix.count) {
            if character.isUppercase, !words.isEmpty {
                words.append(" ")
            }
            words.append(character)
        }
        return words
    }
}
