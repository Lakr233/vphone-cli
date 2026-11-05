// CustomFirmwareBundleSeal.swift — The CodeResources iOS shares between bundles.
//
// Every iOS bundle that seals no resources carries the same
// `_CodeSignature/CodeResources`, and the system volume stores them as one
// file under many names: 6111 hard links on iOS 27.2 (24B91020), the
// VirtualAudio HAL plugin and Instruments' dtsecurity XPC service among them.
// `codesign` rewrites a bundle's seal in place, so re-sealing one of those
// bundles on the guest volume re-seals all of them with its resources. The
// rest then fail resource validation: xpcroleaccountd refuses to stage
// dtsecurity (`bundle code signature not valid`, EFTYPE), and Instruments
// gets no symbolicator for any process.
//
// The installer gives such a bundle a file of its own before it re-seals it,
// and puts Apple's seal back into the shared file when an earlier run wrote
// through it. Apple's seal is rebuilt here rather than copied from an IPSW: it
// is the build system's resource rules with nothing sealed, written by
// CoreFoundation's XML writer, and comes out byte for byte the same as the
// shipped file (iOS 18.6.2 22G100 and 27.2 24B91020 checked, SHA-1
// c0c8a907e2663ee1dc33a137fbfb55f253bcf464). Before it is written back it is
// checked against the resource-directory hash the bundle's original
// executable was signed with, so a release that seals differently is left
// alone.

import CryptoKit
import Foundation

public enum CustomFirmwareBundleSeal {
    /// CS_CodeDirectory special slot 3, the hash of `_CodeSignature/CodeResources`.
    static let resourceDirectorySlot = 3

    /// The CodeResources of an iOS bundle with no sealed resources.
    public static let empty: Data = {
        func rule(_ key: String, _ weight: Double) -> [String: Any] {
            [key: true, "weight": weight]
        }
        let rules: [String: Any] = [
            "^Resources/": true,
            "^Resources/.*\\.lproj/": rule("omit", 10),
            "^Resources/.*\\.lproj/locversion.plist$": rule("omit", 30),
            "^Resources/.*\\.nib/classes\\.nib$": rule("optional", 5),
            "^Resources/.*\\.nib/data\\.dependency$": rule("optional", 5),
            "^Resources/.*\\.nib/info\\.nib$": rule("optional", 5),
            "^Resources/English\\.lproj/": rule("optional", 20),
            "^version.plist$": rule("omit", 10),
        ]
        var rules2 = rules
        let nested = "^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/"
        rules2[nested] = rule("nested", 0)
        let seal: [String: Any] = [
            "files": [String: Any](),
            "files2": [String: Any](),
            "rules": rules,
            "rules2": rules2,
        ]
        // A literal dictionary of property-list types always serializes.
        return try! PropertyListSerialization.data(fromPropertyList: seal, format: .xml, options: 0)
    }()

    /// Whether every CodeDirectory of `executable` commits to `seal` as its
    /// bundle's resources. False when the executable has no parsable
    /// signature, or a CodeDirectory has no resource slot or a hash type this
    /// does not compute.
    public static func executable(_ executable: Data, isSealedWith seal: Data) -> Bool {
        let data = CustomFirmwareMachOCodeSignature.rebased(executable)
        guard let directories = CustomFirmwareMachOCodeSignature.codeDirectories(in: data),
              !directories.isEmpty
        else { return false }
        return directories.allSatisfy { directory in
            guard let recorded = CustomFirmwareMachOCodeSignature.specialSlotHash(
                resourceDirectorySlot, of: directory, in: data,
            ),
                let digest = digest(seal, hashType: directory.hashType),
                digest.count >= directory.hashSize
            else { return false }
            return recorded == digest.prefix(directory.hashSize)
        }
    }

    static func digest(_ data: Data, hashType: UInt8) -> Data? {
        switch hashType {
        case CustomFirmwareMachOCodeSignature.hashTypeSHA1:
            Data(Insecure.SHA1.hash(data: data))
        case CustomFirmwareMachOCodeSignature.hashTypeSHA256,
             CustomFirmwareMachOCodeSignature.hashTypeSHA256Truncated:
            Data(SHA256.hash(data: data))
        case CustomFirmwareMachOCodeSignature.hashTypeSHA384:
            Data(SHA384.hash(data: data))
        default:
            nil
        }
    }
}
