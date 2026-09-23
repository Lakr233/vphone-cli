// CryptexFilesystemPatcherAEA.swift — Apple Encrypted Archive handling for the OS image.
//
// Split out of CryptexFilesystemPatcher.swift. Reading an .aea file's key and auth metadata,
// decrypting it into a plain dmg, and re-encrypting the rebuilt image.
//
// All three used to shell out to `ipsw fw aea`, and the parsing half of this
// file existed to read `--info`'s hex dumps back into bytes. `VPhoneAEA` reads
// the prologue directly, so the dumps — and the Homebrew program that printed
// them — are gone. Encryption and decryption are `/usr/bin/aea`, which is part
// of macOS.

import Foundation
import VPhoneCore

extension Data {
    init?(fromHexString hex: String) {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }

        let chars = hex.map { $0 }
        let bytes = stride(from: 0, to: chars.count, by: 2)
            .map { String(chars[$0]) + String(chars[$0 + 1]) }
            .compactMap { UInt8($0, radix: 16) }

        guard hex.count / bytes.count == 2 else { return nil }
        self.init(bytes)
    }
}

extension CryptexFilesystemPatcher {
    func getAeaKey(_ path: URL, metadata: [String: String]) throws -> String {
        if let key = metadata["encryption_key"] {
            let key = String(key.dropFirst(4))
            if let unwrapped = Data(fromHexString: key),
               let encoded = String(data: unwrapped, encoding: .utf8),
               let data = Data(fromHexString: encoded) {
                return "base64:\(data.base64EncodedString())"
            }
            return key
        }

        // `await` inside a synchronous pipeline: the whole cryptex patcher is
        // straight-line code on one thread, and this is the only step in it
        // that touches the network. A semaphore here is the smallest thing that
        // works; making the pipeline async would mean threading it through
        // every caller up to the CLI for one HTTPS GET.
        return try vphoneRunBlocking { try await VPhoneAEA.symmetricKey(of: path) }
    }

    func encryptAeaFile(_ path: URL, output: URL, key: String, metadata: [String: String]) throws {
        var arguments = [
            "encrypt", "-i", path.path, "-o", output.path,
            "-profile", "1", "-key-value", key,
        ]
        for (metaKey, metaValue) in metadata {
            arguments.append("-auth-data-key")
            arguments.append(metaKey)
            arguments.append("-auth-data-value")
            arguments.append(metaValue)
        }
        _ = try runProcess("/usr/bin/aea", arguments)
    }

    /// Decrypt with `/usr/bin/aea`, which is what `ipsw fw aea -o` shelled out
    /// to once it had the key. The name is the archive's with `.aea` dropped,
    /// which is the name ipsw gave the file inside the directory it wrote.
    func decryptAeaFile(_ path: URL) throws -> URL {
        let output = try createTmpDir()
            .appending(path: String(path.lastPathComponent.dropLast(4)))
        let key = try getAeaKey(path, metadata: [:])
        _ = try runProcess("/usr/bin/aea", [
            "decrypt", "-i", path.path, "-o", output.path, "-key-value", key,
        ])
        return output
    }

    func getAeaMetadata(_ path: URL) throws -> [String: String] {
        try VPhoneAEA.reencryptionMetadata(of: path)
    }
}
