import Capstone
import Foundation

extension CustomFirmwareCacheLoaderPatcher {
    // MARK: - The boot-arg string

    /// One `anchorTokens` match, resolved to the whole C string around it.
    struct StringHit: Sendable, Equatable {
        let token: String
        let text: String
        let sectionName: String
        let stringFileOffset: Int
        let stringVMA: UInt64
        let matchVMA: UInt64
    }

    /// Every token match, most specific token first and, within a token,
    /// `__TEXT,__cstring` before the rest.
    ///
    /// Searching sections rather than the raw file — which is what the Python
    /// does — is what keeps a byte sequence inside the code signature or the
    /// link-edit tables from being mistaken for a string literal.
    static func stringHits(in data: Data, sections: [String: MachOSectionInfo]) -> [StringHit] {
        // A zerofill section has no file bytes, and its `offset` field is 0;
        // searching it would walk the Mach-O header instead.
        let searchable = sections.values
            .filter { $0.fileOffset > 0 && $0.size > 0 }
            .filter { Int($0.fileOffset) + Int($0.size) <= data.count }
            .sorted {
                let cstring = "__cstring"
                if ($0.sectionName == cstring) != ($1.sectionName == cstring) {
                    return $0.sectionName == cstring
                }
                return $0.fileOffset < $1.fileOffset
            }

        var hits: [StringHit] = []
        for token in anchorTokens {
            let needle = Array(token.utf8)
            for section in searchable {
                let start = Int(section.fileOffset)
                let end = start + Int(section.size)
                guard let match = firstOccurrence(of: needle, in: data, from: start, to: end) else {
                    continue
                }
                let stringStart = cStringStart(in: data, containing: match, notBefore: start)
                let stringEnd = cStringEnd(in: data, from: stringStart, notAfter: end)
                hits.append(StringHit(
                    token: token,
                    text: String(decoding: data[stringStart ..< stringEnd], as: UTF8.self),
                    sectionName: "\(section.segmentName),\(section.sectionName)",
                    stringFileOffset: stringStart,
                    stringVMA: section.address + UInt64(stringStart - start),
                    matchVMA: section.address + UInt64(match - start),
                ))
                break
            }
        }
        return hits
    }

    static func firstOccurrence(of needle: [UInt8], in data: Data, from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, to - from >= needle.count else { return nil }
        for offset in from ... (to - needle.count) {
            var matched = true
            for (index, byte) in needle.enumerated() where data[offset + index] != byte {
                matched = false
                break
            }
            if matched {
                return offset
            }
        }
        return nil
    }

    /// The first byte of the null-terminated string containing `offset`.
    ///
    /// Code forms the address of a literal's START, never of a substring inside
    /// it, so a token that matched mid-string has to be walked back before its
    /// address can be looked for.
    static func cStringStart(in data: Data, containing offset: Int, notBefore floor: Int) -> Int {
        var position = offset - 1
        while position >= floor, data[position] != 0 {
            position -= 1
        }
        return position + 1
    }

    static func cStringEnd(in data: Data, from start: Int, notAfter ceiling: Int) -> Int {
        var position = start
        while position < ceiling, data[position] != 0 {
            position += 1
        }
        return position
    }

    // MARK: - The string xref

    /// The ADRP of the first ADRP+ADD pair in `__TEXT,__text` that forms
    /// `targetVMA`.
    ///
    /// The pair need not be adjacent — the compiler interleaves other setup
    /// between them — so an ADRP is remembered per destination register and
    /// matched against a later ADD that reads it. Everything is read from
    /// Capstone's decoded operands: the ADRP's immediate is already the absolute
    /// page, and the ADD's is the page offset.
    static func findStringReference(
        in data: Data,
        text: MachOSectionInfo,
        targetVMA: UInt64,
    ) -> (fileOffset: Int, vma: UInt64)? {
        let targetPage = Int64(targetVMA & ~0xFFF)
        let targetPageOffset = Int64(targetVMA & 0xFFF)
        let disassembler = ARM64Disassembler()

        // ADRP destination register -> (instruction index, address, page).
        var pendingADRP: [UInt32: (index: Int, fileOffset: Int, vma: UInt64, page: Int64)] = [:]

        for (index, offset) in wordOffsets(of: text).enumerated() {
            let vma = text.address + UInt64(offset - Int(text.fileOffset))
            guard let instruction = disassembler.disassembleOne(in: data, at: offset, address: vma),
                  let operands = instruction.aarch64?.operands
            else { continue }

            switch instruction.mnemonic {
            case "adrp":
                guard operands.count >= 2,
                      operands[0].type == AARCH64_OP_REG,
                      operands[1].type == AARCH64_OP_IMM
                else { continue }
                pendingADRP[UInt32(operands[0].reg.rawValue)] = (index, offset, vma, operands[1].imm)

            case "add":
                guard operands.count >= 3,
                      operands[1].type == AARCH64_OP_REG,
                      operands[2].type == AARCH64_OP_IMM,
                      let adrp = pendingADRP[UInt32(operands[1].reg.rawValue)],
                      adrp.page == targetPage,
                      operands[2].imm == targetPageOffset,
                      index - adrp.index <= maxADRPToADDInstructions
                else { continue }
                return (adrp.fileOffset, adrp.vma)

            default:
                continue
            }
        }
        return nil
    }
}
