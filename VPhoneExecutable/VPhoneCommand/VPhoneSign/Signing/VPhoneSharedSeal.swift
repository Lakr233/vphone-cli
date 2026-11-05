import CryptoKit
import Foundation

// MARK: - The shared empty seal

/// The `_CodeSignature/CodeResources` that the iOS system image shares,
/// through hard links, among every bundle that seals no resources (5,503
/// links on 23G90), and the checks to make before touching one.
public enum VPhoneSharedSeal {
    /// The seal itself: no files, under codesign's rules for a bundle with a
    /// Resources folder. PropertyListSerialization writes it byte for byte as
    /// the image carries it (SHA-256 3c727b0f… on 23G90); `matches` is what
    /// proves that for a given guest before anything writes it.
    public static func empty() throws -> Data {
        let rules: [String: Any] = [
            "^Resources/": true,
            "^Resources/.*\\.lproj/": ["omit": true, "weight": 10.0],
            "^Resources/.*\\.lproj/locversion.plist$": ["omit": true, "weight": 30.0],
            "^Resources/.*\\.nib/classes\\.nib$": ["optional": true, "weight": 5.0],
            "^Resources/.*\\.nib/data\\.dependency$": ["optional": true, "weight": 5.0],
            "^Resources/.*\\.nib/info\\.nib$": ["optional": true, "weight": 5.0],
            "^Resources/English\\.lproj/": ["optional": true, "weight": 20.0],
            "^version.plist$": ["omit": true, "weight": 10.0],
        ]
        var rules2 = rules
        rules2["^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/"] =
            ["nested": true, "weight": 0.0]
        let seal: [String: Any] = ["files": [String: Any](), "files2": [String: Any](), "rules": rules, "rules2": rules2]
        return try PropertyListSerialization.data(fromPropertyList: seal, format: .xml, options: 0)
    }

    /// A seal several bundles share cannot list files, since the files
    /// differ from bundle to bundle. One that does was written for a single
    /// bundle. Something that is not a seal at all lists nothing.
    public static func listsFiles(_ seal: Data) -> Bool {
        guard let dictionary = try? PropertyListSerialization.propertyList(from: seal, format: nil) as? [String: Any] else {
            return false
        }
        let files = dictionary["files"] as? [String: Any] ?? [:]
        let files2 = dictionary["files2"] as? [String: Any] ?? [:]
        return !files.isEmpty || !files2.isEmpty
    }

    /// Whether `seal` is what one of `recorded` expects, each hashed the way
    /// its CodeDirectory hashes (`VPhoneSigner.resourceDirectoryHashes`).
    public static func matches(_ seal: Data, recorded: [(hashType: UInt8, hash: Data)]) -> Bool {
        recorded.contains { digest(seal, hashType: $0.hashType) == $0.hash }
    }

    /// `data` hashed as a CodeDirectory of `hashType` stores a slot, or nil
    /// for a hash type there is no reading of.
    static func digest(_ data: Data, hashType: UInt8) -> Data? {
        switch hashType {
        case 1: Data(Insecure.SHA1.hash(data: data))
        case 2: Data(SHA256.hash(data: data))
        case 3: Data(Data(SHA256.hash(data: data)).prefix(20))
        case 4: Data(SHA384.hash(data: data))
        default: nil
        }
    }
}
