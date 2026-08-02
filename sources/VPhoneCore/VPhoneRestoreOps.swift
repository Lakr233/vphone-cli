import Foundation

public enum VPhoneRestoreError: Error, Equatable {
    case ecidUnresolved
    case noSHSH
    case noRestoreDir
    case aeaDecryptFailed(String)
    case aeaStillEncrypted(String)
}

public enum VPhoneRestoreOps {
    // MARK: - ECID

    /// ECID from `--ecid`, else the `ECID=` line of the bundle's udid-prediction.txt.
    public static func resolveECID(explicit: String?, bundle: VPhoneBundle) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        let pred = bundle.url.appendingPathComponent("udid-prediction.txt")
        guard let text = try? String(contentsOf: pred, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ECID=") {
            let value = line.dropFirst("ECID=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - UDID

    /// UDID from the `UDID=` line of the bundle's udid-prediction.txt, or nil.
    public static func resolveUDID(bundle: VPhoneBundle) -> String? {
        let pred = bundle.url.appendingPathComponent("udid-prediction.txt")
        guard let text = try? String(contentsOf: pred, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("UDID=") {
            let value = line.dropFirst("UDID=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - AEA

    /// True if the file begins with the AEA1 magic (`41 45 41 31`).
    public static func isAEAEncrypted(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4)
        return head == Data([0x41, 0x45, 0x41, 0x31])
    }

    /// Decrypt every AEA1-encrypted `*.dmg.aea` in `dir` in place (via `ipsw fw aea`),
    /// keeping the `.aea` filename with decrypted content (matches make restore_offline).
    public static func decryptAEAImages(inRestoreDir dir: URL) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for aea in entries where aea.lastPathComponent.hasSuffix(".dmg.aea") {
            guard try isAEAEncrypted(aea) else { continue }
            let code = try VPhoneProcessRunner.runStreaming(
                URL(fileURLWithPath: "/usr/bin/env"), ["ipsw", "fw", "aea", "-o", dir.path, aea.path])
            guard code == 0 else { throw VPhoneRestoreError.aeaDecryptFailed(aea.lastPathComponent) }
            // ipsw wrote <dir>/<name minus .aea>; move it onto the .aea filename.
            // Confirm the decrypted output exists BEFORE removing the original (mv -f semantics).
            let decrypted = dir.appendingPathComponent(aea.deletingPathExtension().lastPathComponent)
            guard fm.fileExists(atPath: decrypted.path) else {
                throw VPhoneRestoreError.aeaDecryptFailed(aea.lastPathComponent)
            }
            if fm.fileExists(atPath: aea.path) { try fm.removeItem(at: aea) }
            try fm.moveItem(at: decrypted, to: aea)
            if try isAEAEncrypted(aea) { throw VPhoneRestoreError.aeaStillEncrypted(aea.lastPathComponent) }
        }
    }
}
