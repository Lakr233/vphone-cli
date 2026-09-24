import CommonCrypto
import Foundation

// MARK: - Opening a PKCS#12

/// What a `.p12` holds, once it has been opened: the certificates and the
/// private key's PKCS#1 bytes.
///
/// `SecPKCS12Import` would be the obvious way to do this and it cannot be:
/// it refuses an empty password with `errSecAuthFailed`, and the
/// `signcert.p12` in this repository has one, as do most of the ones people
/// pass around. Re-wrapping it with a password would work but would change
/// a checked-in file and break every other tool that reads it. So the
/// container is opened here, which needs PBES2 and PBKDF2 from CommonCrypto
/// and nothing else.
struct VPhoneSignPKCS12 {
    /// Every certificate in the file, in the order it appears.
    let certificates: [Data]
    /// The private key as PKCS#1 `RSAPrivateKey`, which is what
    /// `SecKeyCreateWithData` takes.
    let privateKey: Data

    init(data: Data, password: String) throws {
        // as in VPhoneMachOFile: the DER reader counts from zero
        let data = data.startIndex == 0 ? data : Data(data)
        let pfx = try VPhoneDER.children(of: VPhoneDER.element(in: data, at: 0).content)
        guard pfx.count >= 2 else { throw VPhoneSignError.identityUnreadable("a PFX with \(pfx.count) fields") }
        let authenticated = try Self.contentInfo(pfx[1], password: password)

        var certificates: [Data] = []
        var privateKey: Data?
        // Each payload is the DER of a SEQUENCE, not its contents, so it is
        // unwrapped once more on the way in.
        for content in try VPhoneDER.children(of: VPhoneDER.element(in: authenticated, at: 0).content) {
            let safeContents = try Self.contentInfo(content, password: password)
            for bag in try VPhoneDER.children(of: VPhoneDER.element(in: safeContents, at: 0).content) {
                let fields = try VPhoneDER.children(of: bag.content)
                guard fields.count >= 2 else { continue }
                let value = try VPhoneDER.element(in: fields[1].content, at: 0)
                switch VPhoneDER.objectIdentifier(fields[0].content) {
                case VPhoneDER.OID.certBag:
                    let certificate = try VPhoneDER.children(of: value.content)
                    guard certificate.count >= 2,
                          VPhoneDER.objectIdentifier(certificate[0].content) == VPhoneDER.OID.x509Certificate
                    else { continue }
                    try certificates.append(VPhoneDER.element(in: certificate[1].content, at: 0).content)
                case VPhoneDER.OID.shroudedKeyBag:
                    privateKey = try Self.privateKey(in: Self.decryptPrivateKey(value.encoded, password: password))
                case VPhoneDER.OID.keyBag:
                    privateKey = try Self.privateKey(in: value.encoded)
                default:
                    continue
                }
            }
        }

        guard let privateKey else { throw VPhoneSignError.identityUnreadable("no private key in the PKCS#12") }
        guard !certificates.isEmpty else { throw VPhoneSignError.identityUnreadable("no certificate in the PKCS#12") }
        self.certificates = certificates
        self.privateKey = privateKey
    }

    /// A ContentInfo's payload: plain for `data`, decrypted for
    /// `encryptedData`.
    private static func contentInfo(_ element: VPhoneDER.Element, password: String) throws -> Data {
        let fields = try VPhoneDER.children(of: element.content)
        guard fields.count >= 2 else { throw VPhoneSignError.identityUnreadable("a ContentInfo without content") }
        switch VPhoneDER.objectIdentifier(fields[0].content) {
        case VPhoneDER.OID.data:
            // [0] EXPLICIT OCTET STRING, which may be split into chunks in
            // BER; DER keeps it in one
            return try VPhoneDER.element(in: fields[1].content, at: 0).content
        case VPhoneDER.OID.encryptedData:
            let encrypted = try VPhoneDER.children(of: VPhoneDER.element(in: fields[1].content, at: 0).content)
            guard encrypted.count >= 2 else {
                throw VPhoneSignError.identityUnreadable("an EncryptedData without content")
            }
            let info = try VPhoneDER.children(of: encrypted[1].content)
            guard info.count >= 3 else {
                throw VPhoneSignError.identityUnreadable("an EncryptedContentInfo without content")
            }
            // [0] IMPLICIT OCTET STRING: the content is the value itself
            return try decrypt(info[2].content, algorithm: info[1], password: password)
        default:
            throw VPhoneSignError.identityUnreadable(
                "a PKCS#12 bag of type \(VPhoneDER.objectIdentifier(fields[0].content))",
            )
        }
    }

    /// An EncryptedPrivateKeyInfo.
    private static func decryptPrivateKey(_ encoded: Data, password: String) throws -> Data {
        let fields = try VPhoneDER.children(of: VPhoneDER.element(in: encoded, at: 0).content)
        guard fields.count >= 2 else {
            throw VPhoneSignError.identityUnreadable("an EncryptedPrivateKeyInfo without content")
        }
        return try decrypt(fields[1].content, algorithm: fields[0], password: password)
    }

    /// The PKCS#1 `RSAPrivateKey` inside a PKCS#8 `PrivateKeyInfo`.
    private static func privateKey(in pkcs8: Data) throws -> Data {
        let fields = try VPhoneDER.children(of: VPhoneDER.element(in: pkcs8, at: 0).content)
        guard fields.count >= 3 else { throw VPhoneSignError.identityUnreadable("a PrivateKeyInfo without a key") }
        let algorithm = try VPhoneDER.children(of: fields[1].content)
        guard let first = algorithm.first,
              VPhoneDER.objectIdentifier(first.content) == VPhoneDER.OID.rsaEncryption
        else {
            throw VPhoneSignError.identityUnreadable("a private key that is not RSA")
        }
        return fields[2].content
    }

    // MARK: PBES2

    /// PBES2: PBKDF2 over the password, then AES-CBC. It is what every
    /// PKCS#12 written this decade uses, including the one in this
    /// repository. A file wrapped with the older PKCS#12 key derivation is
    /// refused by name rather than guessed at.
    private static func decrypt(_ ciphertext: Data, algorithm: VPhoneDER.Element, password: String) throws -> Data {
        let fields = try VPhoneDER.children(of: algorithm.content)
        guard let oid = fields.first.map({ VPhoneDER.objectIdentifier($0.content) }), fields.count >= 2 else {
            throw VPhoneSignError.identityUnreadable("an encryption algorithm without parameters")
        }
        guard oid == VPhoneDER.OID.pbes2 else {
            throw VPhoneSignError.identityUnreadable("""
            the PKCS#12 is encrypted with \(oid), which this reader does not implement. \
            Re-wrap it with PBES2: openssl pkcs12 -in old.p12 -nodes -out tmp.pem && \
            openssl pkcs12 -export -in tmp.pem -out new.p12
            """)
        }
        let parameters = try VPhoneDER.children(of: fields[1].content)
        guard parameters.count >= 2 else { throw VPhoneSignError.identityUnreadable("PBES2 without both halves") }

        let derivation = try VPhoneDER.children(of: parameters[0].content)
        guard derivation.count >= 2,
              VPhoneDER.objectIdentifier(derivation[0].content) == VPhoneDER.OID.pbkdf2
        else {
            throw VPhoneSignError.identityUnreadable("PBES2 with a key derivation that is not PBKDF2")
        }
        let pbkdf2 = try VPhoneDER.children(of: derivation[1].content)
        guard pbkdf2.count >= 2 else { throw VPhoneSignError.identityUnreadable("PBKDF2 without a salt") }
        let salt = pbkdf2[0].content
        let iterations = try VPhoneDER.integer(pbkdf2[1].content)

        var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        for field in pbkdf2.dropFirst(2) where field.tag == 0x30 {
            let algorithm = try VPhoneDER.children(of: field.content)
            switch algorithm.first.map({ VPhoneDER.objectIdentifier($0.content) }) {
            case VPhoneDER.OID.hmacWithSHA1: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case VPhoneDER.OID.hmacWithSHA224: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
            case VPhoneDER.OID.hmacWithSHA256: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case VPhoneDER.OID.hmacWithSHA384: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case VPhoneDER.OID.hmacWithSHA512: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            case let other:
                throw VPhoneSignError.identityUnreadable("PBKDF2 with the pseudorandom function \(other ?? "?")")
            }
        }

        let scheme = try VPhoneDER.children(of: parameters[1].content)
        guard scheme.count >= 2 else { throw VPhoneSignError.identityUnreadable("an encryption scheme without an IV") }
        let keyLength: Int
        switch VPhoneDER.objectIdentifier(scheme[0].content) {
        case VPhoneDER.OID.aes128CBC: keyLength = 16
        case VPhoneDER.OID.aes192CBC: keyLength = 24
        case VPhoneDER.OID.aes256CBC: keyLength = 32
        case let other:
            throw VPhoneSignError.identityUnreadable("PBES2 with the cipher \(other)")
        }
        let iv = scheme[1].content

        var key = [UInt8](repeating: 0, count: keyLength)
        let derived = Array(password.utf8).withUnsafeBufferPointer { bytes in
            [UInt8](salt).withUnsafeBufferPointer { salt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    // an empty password is a real password here: the pointer
                    // may be null, which CCKeyDerivationPBKDF accepts with a
                    // length of zero
                    bytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    bytes.count,
                    salt.baseAddress,
                    salt.count,
                    prf,
                    UInt32(iterations),
                    &key,
                    key.count,
                )
            }
        }
        guard derived == kCCSuccess else {
            throw VPhoneSignError.identityUnreadable("PBKDF2 failed with \(derived)")
        }

        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = [UInt8](ciphertext).withUnsafeBufferPointer { input in
            [UInt8](iv).withUnsafeBufferPointer { iv in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    key,
                    key.count,
                    iv.baseAddress,
                    input.baseAddress,
                    input.count,
                    &plaintext,
                    plaintext.count,
                    &written,
                )
            }
        }
        guard status == kCCSuccess else {
            // the one failure a caller can act on: the password is wrong
            throw VPhoneSignError.identityUnreadable(
                status == kCCDecodeError || status == kCCAlignmentError
                    ? "the PKCS#12 password is wrong"
                    : "decrypting the PKCS#12 failed with \(status)",
            )
        }
        return Data(plaintext.prefix(written))
    }
}
