import Foundation
import Security

// MARK: - Error

struct VPhoneLaunchpadHelperError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

// MARK: - Code signature checks

enum VPhoneLaunchpadHelperCodeCheck {
    /// Strict validation of a bundle and everything nested in it. The release
    /// bundle is ad hoc signed, so this proves integrity, not origin; origin
    /// comes from the archive's SHA-256.
    static func requireValidBundle(_ url: URL) throws {
        let code = try staticCode(url)
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode,
        )
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status == errSecSuccess else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle has an invalid code signature. Download it again.")
        }
    }

    /// Hex cdhash of one Mach-O.
    static func cdhash(of url: URL) throws -> String {
        let code = try staticCode(url)
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data
        else {
            throw VPhoneLaunchpadHelperError("Unable to read the code signature of \(url.lastPathComponent). Reinstall VPhone.bundle.")
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Refuses to go on unless `url` still has the cdhash recorded at install.
    static func requireCDHash(_ url: URL, _ expected: String?) throws {
        guard let expected else {
            throw VPhoneLaunchpadHelperError("Unable to verify \(url.lastPathComponent). Reinstall VPhone.bundle.")
        }
        let actual = try cdhash(of: url)
        guard actual == expected else {
            throw VPhoneLaunchpadHelperError(
                "\(url.lastPathComponent) was modified after installation. Reinstall VPhone.bundle.",
            )
        }
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw VPhoneLaunchpadHelperError("Unable to read the code signature of \(url.lastPathComponent). Reinstall VPhone.bundle.")
        }
        return code
    }
}
