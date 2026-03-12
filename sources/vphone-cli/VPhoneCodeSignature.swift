import Foundation
import Security

enum VPhoneCodeSignature {
    static func entitlementsXML(for binaryURL: URL) throws -> String {
        let entitlements = try entitlementsDictionary(for: binaryURL)
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    static func signAdHoc(binaryURL: URL, entitlementsURL: URL? = nil) async throws {
        var arguments = ["--force", "--sign", "-"]
        if let entitlementsURL {
            arguments.append(contentsOf: ["--entitlements", entitlementsURL.path])
        }
        arguments.append(binaryURL.path)
        _ = try await VPhoneHost.runCommand("/usr/bin/codesign", arguments: arguments, requireSuccess: true)
    }

    private static func entitlementsDictionary(for binaryURL: URL) throws -> [String: Any] {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(binaryURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard infoStatus == errSecSuccess,
              let dictionary = info as? [String: Any]
        else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(infoStatus))
        }

        if let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            return entitlements
        }
        return [:]
    }
}
