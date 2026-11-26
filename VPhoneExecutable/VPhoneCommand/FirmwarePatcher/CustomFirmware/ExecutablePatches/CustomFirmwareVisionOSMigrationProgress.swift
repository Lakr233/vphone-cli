import CryptoKit
import Foundation
import VPhonePatchKit

/// visionOS 27.2.1 can start migration before its progress window can obtain
/// a Metal device. Bypass only construction of that window. The stock path
/// that continues with a nil window still runs the collected migration jobs.
public enum CustomFirmwareVisionOSMigrationProgress {
    private static let stockDigest = "a784a944f8b2fcc4fb5e2e6a6d3c1a3b82a242353d25519e5655606c19afd8a8"

    public static func patch(at url: URL, dryRun: Bool = false, log: ((String) -> Void)? = nil) throws {
        var image = try Data(contentsOfFileToRewrite: url)
        guard let text = MachOParser.parseSections(from: image)["__TEXT,__text"],
              text.size <= UInt64(image.count), UInt64(text.fileOffset) <= UInt64(image.count) - text.size
        else { throw PatcherError.invalidFormat("datamigrator text section") }

        let base = Int(text.fileOffset)
        let instructions = ARM64Disassembler().disassemble(
            image.subdata(in: base..<base + Int(text.size)), at: text.address,
        )
        let byAddress = Dictionary(uniqueKeysWithValues: instructions.map { ($0.address, $0) })
        let matches = instructions.indices.dropFirst(4).compactMap { index -> (branch: ARM64Instruction, noPlugins: UInt64)? in
            let branch = instructions[index]
            let prologue = instructions[(index - 4)..<index]
            guard prologue.map(\.mnemonic) == ["mov", "adrp", "adrp", "add"],
                  prologue.first?.detail?.operands.map(\.reg.name) == ["x26", "x0"],
                  let last = branch.detail?.operands.last, last.type == .immediate,
                  let destination = UInt64(exactly: last.imm)
            else { return nil }

            let noPlugins: UInt64
            if branch.mnemonic == "cbz", branch.detail?.operands.first?.reg.name == "x0" {
                noPlugins = destination
            } else if branch.mnemonic == "b", destination >= 20 {
                noPlugins = destination - 20
            } else {
                return nil
            }
            let block = (0..<7).compactMap { byAddress[noPlugins + UInt64(4 * $0)] }
            guard block.map(\.mnemonic) == ["adrp", "add", "mov", "mov", "bl", "str", "b"],
                  let store = block[5].detail?.operands, store.count == 2,
                  store[0].reg.name == "xzr", store[1].type == .memory,
                  store[1].mem.base.name == "sp", store[1].mem.disp == 0x30
            else { return nil }
            return (branch, noPlugins)
        }
        guard matches.count == 1, let site = matches.first,
              let pc = Int(exactly: site.branch.address), let noPlugins = Int(exactly: site.noPlugins),
              noPlugins <= Int.max - 20 else {
            throw PatcherError.patchSiteNotFound("unique visionOS migration progress branch")
        }

        let offset = base + Int(site.branch.address - text.address)
        if site.branch.mnemonic == "b" {
            guard let original = ARM64Encoder.encodeCompareBranch(
                nonzero: false, register: 0, from: pc, to: noPlugins, width64: true,
            ) else { throw PatcherError.patchVerificationFailed("cannot reconstruct migration progress branch") }
            image.replaceSubrange(offset..<offset + 4, with: original)
            _ = try CustomFirmwareMachOCodeSignature.reattest(&image, modifiedOffsets: [offset])
            try verifyStock(image)
            log?("  [.] visionOS migration already skips the progress window")
            return
        }

        try verifyStock(image)
        guard let replacement = ARM64Encoder.encodeB(from: pc, to: noPlugins + 20) else {
            throw PatcherError.patchVerificationFailed("cannot encode windowless migration branch")
        }
        image.replaceSubrange(offset..<offset + 4, with: replacement)
        let slots = try CustomFirmwareMachOCodeSignature.reattest(&image, modifiedOffsets: [offset])
        guard !slots.isEmpty else { throw PatcherError.patchVerificationFailed("migration progress code page was not re-attested") }
        if !dryRun { try image.write(to: url) }
        log?("  [+] visionOS migration will run the collected jobs without opening the progress window")
    }

    private static func verifyStock(_ data: Data) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == stockDigest else { throw PatcherError.patchVerificationFailed("unreviewed visionOS datamigrator build") }
    }
}
