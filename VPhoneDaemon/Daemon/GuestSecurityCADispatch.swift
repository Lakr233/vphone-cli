import Foundation

/// RPC dispatch for the three `security.ca_*` methods, factored out of
/// `GuestAPI.executeDevice` so the request-param extraction and reply-dict
/// shaping can be exercised on the Mac through the same injected
/// `GuestTrustStore.SPI` fakes the trust-store logic uses: the daemon proper
/// imports UIKit/IcliKit/VphonedNative and cannot compile into the standalone
/// `run-trust-store-tests.sh` build. Each method is a thin, error-transparent
/// mapping over `GuestTrustStore` (install/removeAnchor/list) — the SPI-backed
/// behaviour, all-or-none rules and input rejects live there (REQ-007/008);
/// this layer only owns the RPC param keys and the reply field names (REQ-006).
enum GuestSecurityCADispatch {
    /// `security.ca_install` {pem, admin?}: install the PEM anchor into the
    /// selected trust domain (`admin: true` ⇒ admin, else user), reply
    /// `{sha256, subject, domain}`.
    static func install(_ params: [String: Any],
                        resolveSPI: GuestTrustStore.SPIProvider = GuestTrustStore.liveSPI) throws -> [String: Any] {
        let result = try GuestTrustStore.install(pem: requiredString(params, "pem"),
                                                 admin: optionalBool(params, "admin"),
                                                 resolveSPI: resolveSPI)
        return ["sha256": GuestTrustStore.hexString(result.anchor.sha256),
                "subject": GuestTrustStore.subjectSummary(fromCertificateDER: result.anchor.der),
                "domain": result.domain.name]
    }

    /// `security.ca_remove` {sha256}: remove the anchor with that digest, reply
    /// `{removed: true, sha256}`.
    static func remove(_ params: [String: Any],
                       resolveSPI: GuestTrustStore.SPIProvider = GuestTrustStore.liveSPI) throws -> [String: Any] {
        let sha256 = try GuestTrustStore.removeAnchor(sha256Hex: requiredString(params, "sha256"), resolveSPI: resolveSPI)
        return ["removed": true, "sha256": sha256]
    }

    /// `security.ca_list`: reply `{anchors: [{sha256, subject}]}`.
    static func list(resolveSPI: GuestTrustStore.SPIProvider = GuestTrustStore.liveSPI) throws -> [String: Any] {
        ["anchors": try GuestTrustStore.list(resolveSPI: resolveSPI).map {
            ["sha256": GuestTrustStore.hexString($0.sha256), "subject": $0.subject]
        }]
    }

    /// A non-empty String param or `invalidRequest`, mirroring `GuestAPI.string`
    /// (that helper lives in the IcliKit-coupled `GuestAPI.swift`, outside the
    /// standalone test build; the contract is identical).
    private static func requiredString(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw GuestAPIError.invalidRequest("\(key) is required", hint: "Pass \(key) as a non-empty string")
        }
        return value
    }

    /// An optional Bool param: absent ⇒ false; present-but-not-Bool ⇒
    /// `invalidRequest`. `JSONSerialization` decodes both JSON booleans and JSON
    /// numbers to `NSNumber`, and `NSNumber as? Bool` bridges `1`/`0` just like
    /// `true`/`false`, so a numeric `admin` would be silently accepted. Match the
    /// underlying CFBoolean type instead: only a true JSON boolean passes; a
    /// number (`1`), string, or any other type is rejected so a mistyped `admin`
    /// is never honoured.
    private static func optionalBool(_ params: [String: Any], _ key: String) throws -> Bool {
        guard let raw = params[key] else { return false }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw GuestAPIError.invalidRequest("\(key) must be a boolean", hint: "Pass \(key) as true or false")
        }
        return number.boolValue
    }
}
