import CryptoKit
import Foundation
import Security

// MARK: - Signing for real

/// A signing identity read out of a `.p12`, and the detached CMS it makes.
///
/// The CMS is assembled here rather than with `CMSEncoder` for one reason:
/// `CMSEncoder` wants a `SecIdentity`, and getting one means putting the
/// private key in a keychain. Signing a firmware should not write to the
/// user's keychain or raise a prompt for it. `SecKeyCreateSignature` needs
/// no keychain, so the SignedData around it is written out by hand — which
/// also makes the signed attributes exactly the set `ldid` produces, rather
/// than whatever the encoder decides to add.
public struct VPhoneSignIdentity: VPhoneSigningIdentity, @unchecked Sendable {
    public let commonName: String
    public let teamIdentifier: String
    /// Leaf first, as the chain came out of the container.
    private let certificates: [Data]
    private let key: SecKey
    /// The leaf's issuer and serial, which is how a SignerInfo names it.
    private let issuer: Data
    private let serialNumber: Data

    /// `password` is the one the container was wrapped with; the `.p12` in
    /// this repository has none, which is why it is read without
    /// `SecPKCS12Import`.
    public init(pkcs12 data: Data, password: String) throws {
        let container = try VPhoneSignPKCS12(data: data, password: password)
        // The leaf is the one the private key belongs to. localKeyID would
        // say so, but the modulus does too and needs no bag attributes: it
        // is the certificate whose public key the key reproduces.
        guard let key = SecKeyCreateWithData(
            container.privateKey as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
            nil
        ) else {
            throw VPhoneSignError.identityUnreadable("the private key is not an RSA key Security will take")
        }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let ours = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            throw VPhoneSignError.identityUnreadable("the private key has no public half")
        }
        guard let leafIndex = try container.certificates.firstIndex(where: {
            try Self.publicKey(ofCertificate: $0) == ours
        }) else {
            throw VPhoneSignError.identityUnreadable("no certificate in the PKCS#12 matches the private key")
        }

        let leaf = container.certificates[leafIndex]
        // leaf first, then the rest in the order they were stored, which is
        // the order ldid hands OpenSSL
        certificates = [leaf] + container.certificates.enumerated()
            .filter { $0.offset != leafIndex }.map(\.element)
        self.key = key
        let fields = try Self.certificateFields(leaf)
        issuer = fields.issuer
        serialNumber = fields.serialNumber
        commonName = try Self.name(fields.subject, oid: VPhoneDER.OID.commonName)
        teamIdentifier = try Self.name(fields.subject, oid: VPhoneDER.OID.organizationalUnit)
    }

    // MARK: The CMS

    /// A detached CMS SignedData over the CodeDirectory, with the signed
    /// attributes ldid writes: the content type, Apple's two hash agility
    /// attributes, the message digest and the signing time.
    public func cms(codeDirectory: Data, cdHashes: [Data]) throws -> Data {
        var attributes = [
            attribute(VPhoneDER.OID.contentType, [VPhoneDER.objectIdentifier(dotted: VPhoneDER.OID.data)]),
            attribute(VPhoneDER.OID.messageDigest, [VPhoneDER.octetString(Data(SHA256.hash(data: codeDirectory)))]),
            attribute(VPhoneDER.OID.signingTime, [VPhoneDER.utcTime(Date())]),
        ]
        // 1.2.840.113635.100.9.1: a plist of every cdhash, truncated to 20
        // bytes, which is the form the older attribute carries.
        if let plist = try? PropertyListSerialization.data(
            fromPropertyList: ["cdhashes": cdHashes.map { $0.prefix(20) }], format: .xml, options: 0
        ) {
            attributes.append(attribute(VPhoneDER.OID.hashAgility, [VPhoneDER.octetString(plist)]))
        }
        // 1.2.840.113635.100.9.2: one entry per CodeDirectory, at full
        // length, each tagged with the digest that made it. The digest is a
        // bare OID here, not an AlgorithmIdentifier — Apple's structure has
        // no parameters field, and adding the customary NULL is enough for
        // `codesign --verify` to answer "Unable to decode the provided
        // data" while OpenSSL still verifies the signature happily.
        attributes.append(attribute(VPhoneDER.OID.hashAgilityV2, cdHashes.map { hash in
            VPhoneDER.sequence([
                VPhoneDER.objectIdentifier(dotted: hash.count == 20 ? VPhoneDER.OID.sha1 : VPhoneDER.OID.sha256),
                VPhoneDER.octetString(hash),
            ])
        }))

        // The digest is over the attributes as a SET, not as the [0] IMPLICIT
        // they are stored in: the tag is swapped for the signature and back
        // for the encoding. Getting this backwards is the classic way to
        // produce a CMS that every verifier rejects.
        let signed = VPhoneDER.setOf(attributes)
        let signature = try sign(signed)
        var stored = signed
        stored[stored.startIndex] = 0xA0

        let signerInfo = VPhoneDER.sequence([
            VPhoneDER.integer(1),
            VPhoneDER.sequence([issuer, serialNumber]),
            VPhoneDER.algorithm(VPhoneDER.OID.sha256),
            stored,
            VPhoneDER.algorithm(VPhoneDER.OID.rsaEncryption),
            VPhoneDER.octetString(signature),
        ])
        let signedData = VPhoneDER.sequence([
            VPhoneDER.integer(1),
            VPhoneDER.setOf([VPhoneDER.algorithm(VPhoneDER.OID.sha256)]),
            // detached: the content type and nothing else
            VPhoneDER.sequence([VPhoneDER.objectIdentifier(dotted: VPhoneDER.OID.data)]),
            VPhoneDER.encode(0xA0, certificates.reduce(Data(), +)),
            VPhoneDER.setOf([signerInfo]),
        ])
        return VPhoneDER.sequence([
            VPhoneDER.objectIdentifier(dotted: VPhoneDER.OID.signedData),
            VPhoneDER.encode(0xA0, signedData),
        ])
    }

    private func sign(_ content: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, content as CFData, &error
        ) as Data? else {
            throw VPhoneSignError.signingFailed(
                (error?.takeRetainedValue()).map { "\($0)" } ?? "SecKeyCreateSignature gave no signature"
            )
        }
        return signature
    }

    private func attribute(_ oid: String, _ values: [Data]) -> Data {
        VPhoneDER.sequence([VPhoneDER.objectIdentifier(dotted: oid), VPhoneDER.setOf(values)])
    }

    // MARK: Reading the certificate

    private static func certificateFields(_ certificate: Data) throws -> (
        issuer: Data, subject: Data, serialNumber: Data
    ) {
        let tbs = try VPhoneDER.children(of: try VPhoneDER.element(in: certificate, at: 0).content)
        guard let first = tbs.first else { throw VPhoneSignError.identityUnreadable("an empty certificate") }
        let fields = try VPhoneDER.children(of: first.content)
        // [0] EXPLICIT version is optional; everything after it shifts by one
        let offset = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count >= offset + 6 else {
            throw VPhoneSignError.identityUnreadable("a certificate with \(fields.count) fields")
        }
        return (fields[offset + 2].encoded, fields[offset + 4].encoded, fields[offset].encoded)
    }

    private static func publicKey(ofCertificate certificate: Data) throws -> Data? {
        guard let certificate = SecCertificateCreateWithData(nil, certificate as CFData),
              let key = SecCertificateCopyKey(certificate)
        else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    /// One attribute of a `Name`: a SEQUENCE of SETs of type-and-value.
    private static func name(_ encoded: Data, oid: String) throws -> String {
        for set in try VPhoneDER.children(of: try VPhoneDER.element(in: encoded, at: 0).content) {
            for pair in try VPhoneDER.children(of: set.content) {
                let fields = try VPhoneDER.children(of: pair.content)
                guard fields.count >= 2, VPhoneDER.objectIdentifier(fields[0].content) == oid else { continue }
                return String(decoding: fields[1].content, as: UTF8.self)
            }
        }
        throw VPhoneSignError.identityUnreadable("the certificate's subject has no \(oid)")
    }
}
