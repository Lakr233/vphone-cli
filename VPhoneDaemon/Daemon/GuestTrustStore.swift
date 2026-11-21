import CryptoKit
import Darwin
import Foundation
import Security

/// Installs, removes and lists a fully-trusted custom root anchor in the guest's
/// **user or admin** trust domain (operator-selected per install) through the
/// Security.framework trust-store SPI, which drives trustd over its XPC
/// interface. trustd performs the TrustStore write and keeps its own evaluation
/// caches coherent, so there is NO direct DB access, no domain uuid computed, no
/// store path hardcoded, and no trustd restart.
///
/// The operator selects the domain via `security.ca_install {admin}` (default
/// user). On the guest's single-trustd topology — one trustd running as
/// `_trustd` (euid 282) — the user and admin domains compute the SAME row uuid
/// (`mbr_uid_to_uuid(282)`) and so write, enumerate and remove one shared
/// physical TrustStore row; the selector is a real operator control over that
/// one keyspace (live-verified: both domains produce a byte-identical row). The
/// earlier "admin only" rationale (user-domain uuid keyed to a per-user trustd)
/// did not hold here — there is a single trustd, so the user write is honored.
/// See `Domain`.
///
/// The four SPIs are `SecTrustSettingsPriv.h` SPI the iOS SDK does not vend, so
/// they are resolved at runtime via `dlsym(RTLD_DEFAULT, …)` with
/// `@convention(c)` signatures. The resolved calls are exposed through the
/// injectable `SPI` seam so unit tests drive the logic without a live trustd.
enum GuestTrustStore {
    /// The trust domain an anchor is written into. `SecTrustStoreDomain` codes:
    /// 2 = User, 3 = Admin (1 = System is never used). The operator selects the
    /// domain per install via `security.ca_install {admin}` (default user).
    ///
    /// On the guest's single-trustd topology — one trustd as `_trustd` (euid
    /// 282) — both domains compute the same row uuid (`mbr_uid_to_uuid(282)`) and
    /// therefore write, enumerate and remove the SAME physical TrustStore row.
    /// The selector is a real operator control over one shared keyspace; both
    /// domains are honored, and an anchor installed into either is seen by both.
    enum Domain {
        case user, admin
        /// `SecTrustStoreDomain` value.
        var code: Int32 { self == .user ? 2 : 3 }
        /// Operator-facing name (RPC/CLI).
        var name: String { self == .user ? "user" : "admin" }
    }

    /// The domain whose store handle backs enumeration and removal. Because both
    /// domains share one physical keyspace (uuid 282), a single fixed handle sees
    /// anchors installed into either; admin is always a valid store.
    static let enumerationDomain = Domain.admin
    /// A CA PEM must be one certificate no larger than 64 KiB.
    static let maxPEMBytes = 64 * 1024
    /// Serializes every `security.ca_*` trust-store sequence (pre-check, write,
    /// verify, rollback) so concurrent RPC calls — the daemon's RPC queue is
    /// `.concurrent` — never interleave and a cross-call rollback never deletes
    /// a just-reported anchor. A NEW serial queue, not `GuestCryptex.queue`.
    static let queue = DispatchQueue(label: "vphoned.trust-store")

    // MARK: - Injectable SPI seam

    /// The four trust-store SPI calls, wrapped so tests can inject
    /// fakes. `forDomain` returns `nil` for a NULL store; `set` always installs
    /// with nil trust settings (a default-trusted root); `copyAll` returns the
    /// OSStatus and the `[[certDER, settings], …]` array (element 0 = full DER).
    struct SPI {
        let forDomain: (Int32) -> OpaquePointer?
        let set: (OpaquePointer, SecCertificate) -> OSStatus
        let remove: (OpaquePointer, SecCertificate) -> OSStatus
        let copyAll: (OpaquePointer) -> (status: OSStatus, contents: CFArray?)
    }

    /// Resolve the four SPI symbols from `RTLD_DEFAULT`. Throws the
    /// SPI-unavailable error naming the first symbol that does not resolve, so a
    /// guest build that lacks the SPI fails every `security.ca_*` method before
    /// any store change. Injectable (`resolveSPI`) so tests simulate the
    /// unavailable path.
    static func liveSPI() throws -> SPI {
        typealias ForDomainC = @convention(c) (Int32) -> OpaquePointer?
        typealias SetC = @convention(c) (OpaquePointer?, SecCertificate, CFTypeRef?) -> OSStatus
        typealias RemoveC = @convention(c) (OpaquePointer?, SecCertificate) -> OSStatus
        typealias CopyAllC = @convention(c) (OpaquePointer?, UnsafeMutablePointer<CFArray?>) -> OSStatus

        // RTLD_DEFAULT is the pseudo-handle (void *)-2 on Darwin.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let pointer = dlsym(rtldDefault, name) else {
                throw GuestAPIError.operationFailed(
                    "The trust-store SPI \(name) could not be resolved via dlsym; this guest build does not export it.",
                    hint: "Confirm the guest links Security.framework's trust-store SPI.")
            }
            return pointer
        }
        let forDomain = unsafeBitCast(try symbol("SecTrustStoreForDomain"), to: ForDomainC.self)
        let set = unsafeBitCast(try symbol("SecTrustStoreSetTrustSettings"), to: SetC.self)
        let remove = unsafeBitCast(try symbol("SecTrustStoreRemoveCertificate"), to: RemoveC.self)
        let copyAll = unsafeBitCast(try symbol("SecTrustStoreCopyAll"), to: CopyAllC.self)
        return SPI(
            forDomain: { forDomain($0) },
            set: { set($0, $1, nil) },
            remove: { remove($0, $1) },
            copyAll: { store in
                var out: CFArray?
                let status = copyAll(store, &out)
                return (status, out)
            })
    }

    typealias SPIProvider = () throws -> SPI

    // MARK: - Decoding

    /// A decoded anchor ready to write: full DER and its SHA-256.
    struct Anchor: Equatable {
        /// Full certificate DER.
        let der: Data
        /// SHA-256 of the full certificate DER (32 bytes) — the `sha256` key.
        let sha256: Data
    }

    /// Decode a PEM certificate into its full DER and SHA-256. Throws
    /// `invalidRequest` when the PEM is not a single parseable X.509 certificate.
    static func anchor(fromPEM pem: String) throws -> (anchor: Anchor, certificate: SecCertificate) {
        let der = try derFromPEM(pem)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw GuestAPIError.invalidRequest(
                "The CA is not a valid DER X.509 certificate.",
                hint: "Pass one PEM-encoded CA certificate.")
        }
        return (Anchor(der: der, sha256: Data(SHA256.hash(data: der))), certificate)
    }

    /// Extract the single base64 DER body between the first PEM CERTIFICATE
    /// markers. Rejects input with no markers or a non-base64 body.
    static func derFromPEM(_ pem: String) throws -> Data {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound ..< pem.endIndex)
        else {
            throw GuestAPIError.invalidRequest(
                "The CA is not PEM-encoded.",
                hint: "Pass a certificate wrapped in -----BEGIN CERTIFICATE----- / -----END CERTIFICATE-----.")
        }
        let base64 = pem[beginRange.upperBound ..< endRange.lowerBound].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64), !der.isEmpty else {
            throw GuestAPIError.invalidRequest(
                "The CA PEM body is not valid base64.",
                hint: "Re-export the CA in PEM format.")
        }
        return der
    }

    // MARK: - Enumeration

    /// Find the certificate whose full DER has SHA-256 `sha256`, or
    /// `nil` when none matches. Enumerates with `SecTrustStoreCopyAll`; a
    /// non-zero status or a malformed element (not a 2-item `[certDER, settings]`
    /// array, or an undecodable DER) throws naming `spiName`, never a crash or a
    /// silent skip. Scans every element (no short-circuit) so a malformed row is
    /// always surfaced.
    static func findCertificate(sha256: Data,
                                store: OpaquePointer,
                                spi: SPI,
                                spiName: String) throws -> SecCertificate? {
        try enumerate(store, spi, spiName).last { Data(SHA256.hash(data: $0.der)) == sha256 }?.certificate
    }

    /// Decode every `SecTrustStoreCopyAll` element into its DER and certificate.
    private static func enumerate(_ store: OpaquePointer,
                                  _ spi: SPI,
                                  _ spiName: String) throws -> [(der: Data, certificate: SecCertificate)] {
        let (status, contents) = spi.copyAll(store)
        // iOS trustd returns errSecParam (-50) from SecTrustStoreCopyAll when the
        // trust store holds no anchors. Treat that as an empty enumeration, not a
        // failure: it is the normal state before the first install. Correctness is
        // still guarded — the install post-write verify re-enumerates a now
        // non-empty store, so a genuinely failed write is caught (returns empty →
        // "not present after write" → rollback).
        if status == errSecParam { return [] }
        guard status == errSecSuccess else {
            throw GuestAPIError.operationFailed(
                "\(spiName) failed (OSStatus \(status)) enumerating the trust store.")
        }
        guard let elements = contents as? [Any] else { return [] }
        return try elements.map { element in
            guard let pair = element as? [Any], pair.count == 2, let der = pair[0] as? Data else {
                throw GuestAPIError.operationFailed(
                    "\(spiName) returned a malformed element (not a 2-item [certificate, settings] array) "
                        + "from the trust store.")
            }
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw GuestAPIError.operationFailed(
                    "\(spiName) returned an element with an undecodable certificate DER from the trust store.")
            }
            return (der, certificate)
        }
    }

    /// The store handle for `domain`; throws when the SPI returns NULL.
    private static func storeHandle(_ spi: SPI, _ domain: Domain) throws -> OpaquePointer {
        guard let store = spi.forDomain(domain.code) else {
            throw GuestAPIError.operationFailed(
                "SecTrustStoreForDomain returned NULL for the \(domain.name) domain; the trust store is unavailable.")
        }
        return store
    }

    private static func contains(sha256: Data, store: OpaquePointer, spi: SPI, spiName: String) throws -> Bool {
        try findCertificate(sha256: sha256, store: store, spi: spi, spiName: spiName) != nil
    }

    // MARK: - Install

    /// Install an anchor into the selected trust domain (`admin` ? admin : user),
    /// all-or-none (REQ-007):
    /// (0) a NULL store returns the SPI error before any other call;
    /// (1) pre-check `SecTrustStoreCopyAll` for pre-presence (a failed/malformed
    ///     pre-check errors before any write; an empty store enumerates as
    ///     not-present, not an error); (2) write
    ///     `SecTrustStoreSetTrustSettings(cert, nil)`; (3) verify via a
    ///     post-write `SecTrustStoreCopyAll`; (4) on any failure, if the cert was
    ///     not pre-present, always `SecTrustStoreRemoveCertificate` (safe — it
    ///     returns errSecSuccess when absent), leaving a pre-present cert intact;
    ///     (5) if that undo itself fails, surface the undo-failure error.
    /// Re-installing a cert that verifies present is success (idempotent).
    /// Returns the anchor and the domain it was installed into. Runs the whole
    /// sequence on the serial `queue`.
    @discardableResult
    static func install(pem: String, admin: Bool = false, resolveSPI: SPIProvider = liveSPI) throws -> (anchor: Anchor, domain: Domain) {
        try queue.sync {
            try validate(pem: pem)
            let (anchor, certificate) = try anchor(fromPEM: pem)
            let spi = try resolveSPI()
            let domain: Domain = admin ? .admin : .user

            // Step 0: a NULL store fails closed before any other trust-store call.
            let store = try storeHandle(spi, domain)

            // Step 1: pre-presence. A failed/malformed pre-check throws here,
            // before any write (so spi.set is never reached in that case).
            let prePresent = try contains(sha256: anchor.sha256, store: store, spi: spi, spiName: "SecTrustStoreCopyAll")

            // Step 2: write.
            let setStatus = spi.set(store, certificate)

            // Steps 3–5. On any failure, roll back a cert this call added, then
            // surface the original error (or the undo-failure error if the
            // rollback itself fails). This unconditional undo is the one
            // exception to the SPI-failure "make no further change" rule.
            func finishFailure(_ original: GuestAPIError, setStatus: OSStatus) throws -> Never {
                if !prePresent {
                    let removeStatus = spi.remove(store, certificate)
                    if removeStatus != errSecSuccess {
                        throw GuestAPIError.operationFailed(
                            "SecTrustStoreSetTrustSettings and SecTrustStoreRemoveCertificate both failed "
                                + "(OSStatus \(setStatus) and \(removeStatus)); the anchor may still be installed "
                                + "in the \(domain.name) trust store. Check with security.ca_list and clean up with "
                                + "security.ca_remove.")
                    }
                }
                throw original
            }

            // Step 3: verify. A failed/malformed post-write enumeration routes
            // through the rollback path naming SecTrustStoreCopyAll.
            let present: Bool
            do {
                present = try contains(sha256: anchor.sha256, store: store, spi: spi, spiName: "SecTrustStoreCopyAll")
            } catch let error as GuestAPIError {
                try finishFailure(error, setStatus: setStatus)
            }

            if setStatus == errSecSuccess && present {
                return (anchor, domain)
            }
            if setStatus != errSecSuccess {
                try finishFailure(
                    GuestAPIError.operationFailed(
                        "SecTrustStoreSetTrustSettings failed (OSStatus \(setStatus)); "
                            + "the CA was not installed in the \(domain.name) trust store."),
                    setStatus: setStatus)
            }
            try finishFailure(
                GuestAPIError.operationFailed(
                    "SecTrustStoreSetTrustSettings returned success but SecTrustStoreCopyAll shows the CA was not "
                        + "present in the \(domain.name) trust store after the write; the install did not take effect."),
                setStatus: setStatus)
        }
    }

    // MARK: - Remove

    /// Remove the anchor with the given 64-char lowercase-hex
    /// sha256, returning that normalized hex. A malformed value throws
    /// `invalidRequest`; a sha256 with no installed row throws `notFound` and
    /// calls no `SecTrustStoreRemoveCertificate`. After the remove, re-enumerates
    /// and errors (never reports success) if the cert is still present. Runs on
    /// the serial `queue`.
    @discardableResult
    static func removeAnchor(sha256Hex hex: String, resolveSPI: SPIProvider = liveSPI) throws -> String {
        try queue.sync {
            guard hex == hex.lowercased(), let sha256 = sha256(fromHex: hex) else {
                throw GuestAPIError.invalidRequest(
                    "sha256 must be 64 lowercase hex characters; got '\(hex)'.",
                    hint: "Pass the sha256 shown by security.ca_list.")
            }
            let spi = try resolveSPI()
            let store = try storeHandle(spi, enumerationDomain)
            guard let certificate = try findCertificate(sha256: sha256, store: store, spi: spi,
                                                        spiName: "SecTrustStoreCopyAll") else {
                throw GuestAPIError.notFound(
                    "No installed CA has sha256 \(hex) in the trust store.",
                    hint: "Run security.ca_list to see installed CAs.")
            }
            let removeStatus = spi.remove(store, certificate)
            guard removeStatus == errSecSuccess else {
                throw GuestAPIError.operationFailed(
                    "SecTrustStoreRemoveCertificate failed (OSStatus \(removeStatus)) "
                        + "removing the CA from the trust store.")
            }
            if try contains(sha256: sha256, store: store, spi: spi, spiName: "SecTrustStoreCopyAll") {
                throw GuestAPIError.operationFailed(
                    "SecTrustStoreRemoveCertificate reported success but SecTrustStoreCopyAll still shows the CA "
                        + "in the trust store; the removal did not take effect.")
            }
            return hexString(sha256)
        }
    }

    // MARK: - List

    /// List every anchor as its SHA-256 (full DER) and subject
    /// summary. A non-zero status or malformed element throws naming
    /// `SecTrustStoreCopyAll`. Returns rows in enumeration order; the host CLI
    /// sorts. Runs on the serial `queue`.
    static func list(resolveSPI: SPIProvider = liveSPI) throws -> [(sha256: Data, subject: String)] {
        try queue.sync {
            let spi = try resolveSPI()
            let store = try storeHandle(spi, enumerationDomain)
            return try enumerate(store, spi, "SecTrustStoreCopyAll").map {
                (Data(SHA256.hash(data: $0.der)), subjectSummary(fromCertificateDER: $0.der))
            }
        }
    }

    // MARK: - Input validation

    /// Reject a PEM over 64 KiB, or with more than one `-----BEGIN CERTIFICATE-----`
    /// marker (a multi-cert bundle). Zero markers is left to `derFromPEM`'s
    /// not-PEM reject. Mirrors the host CLI's count so the daemon enforces the
    /// rule independently of how the PEM arrived.
    static func validate(pem: String) throws {
        let bytes = pem.utf8.count
        guard bytes <= maxPEMBytes else {
            throw GuestAPIError.invalidRequest(
                "The CA PEM is \(bytes) bytes, over the 64 KiB (\(maxPEMBytes)-byte) limit.",
                hint: "Install a single certificate under 64 KiB.")
        }
        let certificates = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        guard certificates <= 1 else {
            throw GuestAPIError.invalidRequest(
                "The CA PEM holds \(certificates) certificates; install exactly one.",
                hint: "Split the bundle and install the root CA alone.")
        }
    }

    /// Parse a 64-character hex SHA-256 into its 32 bytes; nil when the input is
    /// not exactly 64 hex digits.
    static func sha256(fromHex hex: String) -> Data? {
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Lowercase hex of a byte blob (the `sha256` presentation form).
    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Subject summary

    /// The certificate's subject summary (typically its common name) from
    /// `SecCertificateCopySubjectSummary` on the stored DER, sanitized by
    /// `sanitize(summary:)`. A certificate with no summary renders as the
    /// empty string.
    static func subjectSummary(fromCertificateDER der: Data) -> String {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let summary = SecCertificateCopySubjectSummary(certificate) as String?
        else { return "" }
        return sanitize(summary: summary)
    }

    /// Replace every C0 control character (0x00–0x1F) or DEL (0x7F) in a subject
    /// summary with a single space so the one-line `ca list` format stays
    /// unambiguous; the rest of the summary is left intact.
    static func sanitize(summary: String) -> String {
        var sanitized = ""
        for scalar in summary.unicodeScalars {
            if scalar.value <= 0x1F || scalar.value == 0x7F {
                sanitized.append(" ")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        return sanitized
    }
}
