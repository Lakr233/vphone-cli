// VPhoneAEA.swift — the AEA1 prologue, and the key Apple hands back for it.
//
// This replaces `ipsw fw aea`, which was the last thing in the CFW install path
// that needed a Homebrew program on the machine running the install. Three
// shapes were used: `--info` (the archive's auth data), `--key` (the symmetric
// key) and `-o` (decrypt). The first two are here; the third is
// `/usr/bin/aea decrypt`, which ships with macOS.
//
// Two facts make this small. The prologue is a flat list of length-prefixed
// key/value records, so reading it needs no framework at all. And the key
// exchange is plain RFC 9180 HPKE — base mode, DHKEM(P-256, HKDF-SHA256),
// HKDF-SHA256, AES-256-GCM, empty `info` and empty `aad` — which CryptoKit
// implements, so there is no crypto written here either.
//
// The one thing that is not local is the private key: `fcs-key-url` points at
// wkms-public.apple.com and the archive cannot be opened without fetching it.
// That is Apple's design, not a dependency this project added — `ipsw` made the
// same request.

import CryptoKit
import Foundation

public enum VPhoneAEA {
    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError {
        case notAEA(URL)
        case truncatedPrologue(URL)
        case missingAuthField(String)
        case malformedFCSResponse
        case keyFetchFailed(URL, Int)

        public var errorDescription: String? {
            switch self {
            case let .notAEA(url):
                "\(url.lastPathComponent) does not start with AEA1"
            case let .truncatedPrologue(url):
                "\(url.lastPathComponent) has a truncated AEA prologue"
            case let .missingAuthField(name):
                "the AEA prologue has no '\(name)' field"
            case .malformedFCSResponse:
                "the AEA prologue's fcs-response is not the expected JSON"
            case let .keyFetchFailed(url, status):
                "fetching the AEA key from \(url.host() ?? url.absoluteString) returned HTTP \(status)"
            }
        }
    }

    // MARK: - Prologue

    /// The archive's authentication data: the key/value pairs `ipsw fw aea
    /// --info` prints, as they are stored.
    ///
    /// Layout, all little-endian: `AEA1`, a u32 profile, a u32 giving the size
    /// of everything that follows, then that many bytes of records. Each record
    /// is a u32 length — counting its own four bytes — followed by a
    /// NUL-separated key and value. The value is bytes, not text: `auth-data`
    /// is a protobuf.
    public static func authData(of url: URL) throws -> [String: Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: 12), header.count == 12 else {
            throw Error.truncatedPrologue(url)
        }
        guard header.prefix(4) == Data("AEA1".utf8) else { throw Error.notAEA(url) }

        let size = Int(u32(header, 8))
        guard size > 0, size <= 16 * 1024 * 1024,
              let body = try handle.read(upToCount: size), body.count == size
        else { throw Error.truncatedPrologue(url) }

        var fields: [String: Data] = [:]
        var offset = 0
        while offset + 4 <= size {
            let length = Int(u32(body, offset))
            // A record has to carry its own header and at least a key; a length
            // that does not is a corrupt prologue, not an empty field.
            guard length > 4, offset + length <= size else { break }
            let record = body.subdata(in: (offset + 4) ..< (offset + length))
            if let separator = record.firstIndex(of: 0) {
                fields[String(decoding: record[..<separator], as: UTF8.self)] =
                    Data(record[(separator + 1)...])
            }
            offset += length
        }
        return fields
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    // MARK: - Key

    /// The archive's symmetric key, in the `base64:…` spelling `aea` takes for
    /// `-key-value` — and the spelling `ipsw fw aea --key` printed, so the call
    /// sites did not have to change.
    ///
    /// Three steps, none of them optional: `fcs-key-url` names a one-time P-256
    /// private key that Apple serves as a PEM; `fcs-response` carries the HPKE
    /// encapsulated key and the wrapped symmetric key; opening the second with
    /// the first gives 32 bytes.
    public static func symmetricKey(of url: URL) async throws -> String {
        let fields = try authData(of: url)

        guard let keyURLBytes = fields["com.apple.wkms.fcs-key-url"],
              let keyURL = URL(string: String(decoding: keyURLBytes, as: UTF8.self))
        else { throw Error.missingAuthField("com.apple.wkms.fcs-key-url") }

        guard let responseBytes = fields["com.apple.wkms.fcs-response"] else {
            throw Error.missingAuthField("com.apple.wkms.fcs-response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseBytes) as? [String: String],
              let encapsulated = response["enc-request"].flatMap({ Data(base64Encoded: $0) }),
              let wrapped = response["wrapped-key"].flatMap({ Data(base64Encoded: $0) })
        else { throw Error.malformedFCSResponse }

        let (pem, urlResponse) = try await URLSession.shared.data(from: keyURL)
        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw Error.keyFetchFailed(keyURL, http.statusCode)
        }

        let privateKey = try P256.KeyAgreement.PrivateKey(
            pemRepresentation: String(decoding: pem, as: UTF8.self)
        )
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: HPKE.Ciphersuite(
                kem: .P256_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256
            ),
            info: Data(),
            encapsulatedKey: encapsulated
        )
        return "base64:" + (try recipient.open(wrapped)).base64EncodedString()
    }

    // MARK: - Re-encryption metadata

    /// The auth data in the form `aea -auth-data-value` takes it, matching what
    /// this project fed back into a rebuilt archive when it parsed `ipsw fw aea
    /// --info` output instead of the file.
    ///
    /// The shape is inherited, not chosen. `ipsw` printed a field either as
    /// text or as a hex dump, depending on whether it looked printable, and the
    /// parser on this end turned the first into the text's bytes and the second
    /// into the *base64 spelling* of the bytes. Reproducing that split keeps a
    /// re-encrypted archive byte-identical to the ones this path has always
    /// produced; "fixing" it would change every archive the CFW installer
    /// writes, silently, for no benefit.
    public static func reencryptionMetadata(of url: URL) throws -> [String: String] {
        try authData(of: url).mapValues { value in
            if let text = printableText(value) {
                "hex:" + Data(text.utf8).hexString
            } else {
                "hex:" + Data(value.base64EncodedString().utf8).hexString
            }
        }
    }

    /// What `ipsw` would have printed as text rather than hex-dumped: valid
    /// UTF-8 with no control bytes in it, trimmed the way the old parser
    /// trimmed the lines it joined.
    private static func printableText(_ data: Data) -> String? {
        guard !data.contains(where: { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Running one async call from synchronous code

/// Wait for an async call from a synchronous caller.
///
/// The firmware pipeline is straight-line synchronous code from `main.swift`
/// down, and `VPhoneAEA.symmetricKey` is the only step anywhere in it that
/// touches the network. Threading `async` through every frame between them —
/// the CLI command, the cryptex patcher, half of FirmwarePatcher — to serialise
/// on one HTTPS GET would buy nothing.
///
/// `Task.detached` and a semaphore, deliberately: the task must not inherit the
/// caller's actor, or a call made on the main actor would block the queue the
/// work is waiting to run on.
public func vphoneRunBlocking<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Swift.Error>!
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
