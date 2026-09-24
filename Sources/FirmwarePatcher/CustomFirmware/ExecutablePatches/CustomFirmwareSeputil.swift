// CustomFirmwareSeputil.swift — pin seputil's gigalocker file name to "AA".
//
// `seputil` keeps the SEP's "gigalocker" blob in a file named after the
// device's own UUID, built with a two-field format string:
//
//     snprintf(path, n, "%s/%s.gl", mountpoint, uuid);   // -> /mnt7/<uuid>.gl
//
// A vphone guest does not carry the UUID the gigalocker on the restored
// filesystem was written for, so seputil looks for a file that is not there.
// Rewriting the *uuid* field of that one literal to the constant `AA` makes
// every lookup resolve to `<mountpoint>/AA.gl`, which is the name the install
// gives the blob it ships. The mountpoint field is deliberately left as `%s`:
// it is chosen at runtime between `/mnt7` and `/private/xarts` and both must
// keep working.
//
// This is a data patch, not a code patch — the two bytes rewritten are ASCII
// inside `__TEXT,__cstring`, so no instruction is assembled here and the ARM64
// encoder has nothing to contribute. Capstone is used for the *anchor*: the
// literal has to be the one seputil actually formats with, which is proven by
// finding the `adrp`/`add` pair in `__TEXT,__text` that materialises its
// address.
//
// Anchoring, in order, none of it positional:
//
//   1. `__TEXT,__cstring` from the load commands — a literal anywhere else is
//      not a C string this binary formats with.
//   2. The one whole NUL-terminated literal in that section shaped
//      `<dir>/<2-byte field>.gl`, where the field reads `%s` (pristine) or `AA`
//      (already patched). Whole-literal equality, so the tail of a longer
//      string cannot match.
//   3. An `adrp`+`add` in `__TEXT,__text` computing that literal's VA, matched
//      on decoded operands.
//   4. The field to rewrite is the one after the literal's own last `/`.
//
// Port of `scripts/patchers/cfw_patch_seputil.py`, which stays the independent
// reference: `CustomFirmwareSeputilTests` runs the Python on one clone of a real seputil
// and this on another and compares the files byte for byte.
//
// Two deliberate differences from the reference, both of them narrowing:
//
//   * The Python searches the whole file for the *substring* `"/%s.gl\0"` and
//     patches the two bytes after the `/`. On this binary that substring is the
//     tail of `"%s/%s.gl"` and the result is the same byte, but the search is
//     not bounded to `__cstring`, does not require the match to be a whole
//     literal, and takes the first hit without checking that anything refers to
//     it. All three are tightened here.
//   * The Python leaves the code signature stale, because `cfw_install*.sh`
//     runs `ldid_sign` over the binary immediately afterwards. This
//     re-attests the page it dirtied through `CustomFirmwareMachOCodeSignature`, so the
//     binary that leaves this function verifies on its own. Pass
//     `reattest: false` to reproduce the reference's bytes exactly.

import Capstone
import Foundation

public enum CustomFirmwareSeputil {
    // MARK: - Anchors

    /// Where the format string lives. A literal outside this section is not one
    /// the binary formats with, so the search never leaves it.
    public static let cstringSection = (segment: "__TEXT", section: "__cstring")

    /// Where a reference to the literal has to come from.
    public static let textSection = (segment: "__TEXT", section: "__text")

    /// The conversion the pristine literal uses for the gigalocker's name.
    public static let uuidConversion = "%s"

    /// What this patch pins that field to.
    public static let uuidReplacement = "AA"

    /// The suffix that makes a two-field format string a gigalocker path
    /// rather than any other path-shaped literal in the binary.
    public static let gigalockerSuffix = ".gl"

    /// How far past an `adrp` its `add` may sit. Eight instructions — the same
    /// window `KernelPatcherBase.findStringRefs` uses for the same job.
    static let addSearchWindow = 8

    /// One disassembler for the whole patcher; `ARM64Disassembler` is `Sendable`
    /// and stateless across calls.
    private static let disassembler = ARM64Disassembler()

    /// Default sink for the progress lines, matching the other patchers.
    public static let stderrLog: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - Site

    /// The literal this patch rewrites, and the field inside it.
    public struct Site: Sendable, Equatable {
        /// File offset of the literal's first byte.
        public let literalOffset: Int
        /// The literal's virtual address.
        public let literalVMA: UInt64
        /// The literal as it currently reads.
        public let literal: String
        /// File offset of the two-byte field after the literal's last `/`.
        public let fieldOffset: Int
        /// That field's virtual address.
        public let fieldVMA: UInt64
        /// True while the field still holds `%s`; false once it holds `AA`.
        public let isPristine: Bool

        /// The offsets the write dirties. Two, not one: a literal can straddle
        /// a page boundary, and then two slots need re-attesting.
        public var modifiedOffsets: [Int] {
            Array(fieldOffset ..< fieldOffset + CustomFirmwareSeputil.uuidReplacement.utf8.count)
        }
    }

    // MARK: - Outcome

    /// What one run did.
    public struct Outcome: Sendable {
        public enum Verdict: Sendable, Equatable, CustomStringConvertible {
            /// The field already reads `AA`. Nothing was written, nothing was
            /// re-attested — a second run over an installed binary lands here.
            case alreadyPatched
            /// A dry run that found a pristine field and stopped before writing.
            case wouldPatch
            /// The field was rewritten, and the page it sits in re-attested
            /// unless the caller asked otherwise.
            case patched

            public var description: String {
                switch self {
                case .alreadyPatched: "already patched"
                case .wouldPatch: "would patch"
                case .patched: "patched"
                }
            }
        }

        public let verdict: Verdict
        public let site: Site
        /// Addresses of the `add` instructions that materialise the literal.
        public let references: [UInt64]
        /// The record of the single write, on a run that wrote or would write.
        public let record: PatchRecord?
        /// Slot hashes re-attestation replaced. Empty when `reattest` was off.
        public let rehashes: [CustomFirmwareSlotRehash]

        public init(
            verdict: Verdict,
            site: Site,
            references: [UInt64],
            record: PatchRecord? = nil,
            rehashes: [CustomFirmwareSlotRehash] = [],
        ) {
            self.verdict = verdict
            self.site = site
            self.references = references
            self.record = record
            self.rehashes = rehashes
        }

        /// Sites this run put on disk — 1 on a live patch, 0 otherwise. Mirrors
        /// what `patch_seputil()` reports.
        public var sitesWritten: Int {
            verdict == .patched ? 1 : 0
        }
    }

    // MARK: - Entry points

    /// Patch the seputil binary at `url`.
    ///
    /// - Parameters:
    ///   - dryRun: locate and report, write nothing.
    ///   - reattest: recompute the slot hash of the page the write dirties.
    ///     On by default, so the binary verifies without an external re-sign.
    ///     Off reproduces `cfw_patch_seputil.py`'s bytes exactly.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        dryRun: Bool = false,
        reattest: Bool = true,
        log: ((String) -> Void)? = stderrLog,
    ) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        log?("  [.] \(url.path)")
        var data = try Data(contentsOfFileToRewrite: url)
        let outcome = try patch(&data, dryRun: dryRun, reattest: reattest, log: log)
        if outcome.verdict == .patched {
            try data.write(to: url)
        }
        return outcome
    }

    /// Patch an in-memory seputil image.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        dryRun: Bool = false,
        reattest: Bool = true,
        log: ((String) -> Void)? = stderrLog,
    ) throws -> Outcome {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let (cstring, text) = try sections(in: data)
        let site = try findSite(in: data, cstring: cstring)
        log?(
            "      [.] literal \"\(site.literal)\" @ 0x\(hex(site.literalVMA)) "
                + "(file 0x\(hex(site.literalOffset)))",
        )

        // The literal has to be one the code actually formats with. Without
        // this, a build that moved the gigalocker path into a different string
        // would still offer some `<dir>/%s.gl` to rewrite and the patch would
        // report success while changing nothing that runs.
        let references = references(to: site.literalVMA, in: data, text: text)
        guard !references.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "seputil: \"\(site.literal)\" @ 0x\(hex(site.literalVMA)) has no adrp+add "
                    + "reference in \(textSection.segment),\(textSection.section); "
                    + "it is not the literal the gigalocker path is built from",
            )
        }
        log?("      [.] referenced from \(references.map { "0x" + hex($0) }.joined(separator: ", "))")

        guard site.isPristine else {
            log?(
                "      [=] field at 0x\(hex(site.fieldOffset)) already reads "
                    + "\"\(uuidReplacement)\"; nothing to patch/re-attest",
            )
            return Outcome(verdict: .alreadyPatched, site: site, references: references)
        }

        let replacement = Data(uuidReplacement.utf8)
        let range = site.fieldOffset ..< site.fieldOffset + replacement.count
        let original = Data(data[range])
        let record = record(for: site, original: original, replacement: replacement)

        guard !dryRun else {
            log?("      [+] would write \"\(uuidReplacement)\" at 0x\(hex(site.fieldOffset))")
            return Outcome(
                verdict: .wouldPatch,
                site: site,
                references: references,
                record: record,
            )
        }

        data.replaceSubrange(range, with: replacement)
        log?(
            "      [+] 0x\(hex(site.fieldOffset)): \(original.hex) -> \(replacement.hex) "
                + "(\"\(site.literal)\" -> \"\(patchedLiteral(of: site))\")",
        )

        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest {
            for directory in CustomFirmwareMachOCodeSignature.unsupportedCodeDirectories(in: data) {
                log?(
                    "      [-] CodeDirectory @ 0x\(hex(directory.offset)) is hashType "
                        + "\(directory.hashType), not SHA-256 — left untouched",
                )
            }
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: site.modifiedOffsets)
            for rehash in rehashes {
                log?("      [+] \(rehash)")
            }
        }

        // Re-read the site the same way it was found, rather than trusting the
        // write: anything that moved underneath it shows up here.
        let after = try findSite(in: data, cstring: cstring)
        guard after.fieldOffset == site.fieldOffset, !after.isPristine else {
            throw PatcherError.patchVerificationFailed(
                "seputil: post-write read back \"\(after.literal)\" at 0x\(hex(after.fieldOffset))",
            )
        }
        log?("  [+] seputil gigalocker name pinned to \"\(uuidReplacement)\(gigalockerSuffix)\"")

        return Outcome(
            verdict: .patched,
            site: site,
            references: references,
            record: record,
            rehashes: rehashes,
        )
    }

    // MARK: - Reveal

    /// The two sections this patcher reads, from the load commands.
    static func sections(in data: Data) throws -> (cstring: MachOSectionInfo, text: MachOSectionInfo) {
        let all = MachOParser.parseSections(from: data)
        guard let cstring = all["\(cstringSection.segment),\(cstringSection.section)"] else {
            throw PatcherError.invalidFormat(
                "seputil: no \(cstringSection.segment),\(cstringSection.section) section "
                    + "(not a 64-bit Mach-O, or not the binary we were handed)",
            )
        }
        guard let text = all["\(textSection.segment),\(textSection.section)"] else {
            throw PatcherError.invalidFormat(
                "seputil: no \(textSection.segment),\(textSection.section) section",
            )
        }
        return (cstring, text)
    }

    /// The single gigalocker path literal in `__TEXT,__cstring`.
    ///
    /// Matching is on whole NUL-terminated literals, so `"%s.gl"` — the very
    /// next literal after the one we want on the reference binary — cannot be
    /// mistaken for it, and neither can the tail of any longer string.
    ///
    /// Throws when there is no candidate or more than one: with two, there is
    /// no evidence which one seputil formats with, and picking either is a
    /// coin flip that boots or does not.
    static func findSite(in data: Data, cstring: MachOSectionInfo) throws -> Site {
        let start = Int(cstring.fileOffset)
        let end = start + Int(cstring.size)
        guard start >= 0, end <= data.count, start <= end else {
            throw PatcherError.invalidFormat(
                "seputil: \(cstringSection.section) runs to 0x\(hex(end)), past the end of a "
                    + "0x\(hex(data.count))-byte file",
            )
        }

        var sites: [Site] = []
        var cursor = start
        while cursor < end {
            var terminator = cursor
            while terminator < end, data[terminator] != 0 {
                terminator += 1
            }
            guard terminator < end else { break } // unterminated tail, not a literal
            let literal = Array(data[cursor ..< terminator])
            if let field = fileField(of: literal), let pristine = pristineness(of: literal[field]) {
                sites.append(Site(
                    literalOffset: cursor,
                    literalVMA: cstring.address + UInt64(cursor - start),
                    literal: String(decoding: literal, as: UTF8.self),
                    fieldOffset: cursor + field.lowerBound,
                    fieldVMA: cstring.address + UInt64(cursor - start + field.lowerBound),
                    isPristine: pristine,
                ))
            }
            cursor = terminator + 1
        }

        guard let site = sites.first else {
            throw PatcherError.patchSiteNotFound(
                "seputil: no \"<dir>/\(uuidConversion)\(gigalockerSuffix)\" literal in "
                    + "\(cstringSection.segment),\(cstringSection.section)",
            )
        }
        guard sites.count == 1 else {
            throw PatcherError.patchSiteNotFound(
                "seputil: \(sites.count) gigalocker path literals "
                    + "(\(sites.map { "\"\($0.literal)\" @ 0x" + hex($0.literalOffset) }.joined(separator: ", "))); "
                    + "refusing to guess which one builds the path",
            )
        }
        return site
    }

    /// The range, within `literal`, of the field after its last `/`.
    ///
    /// `"%s/%s.gl"` names a directory and a file. The field this patch pins is
    /// the file's, so it is read off the literal's own last separator instead
    /// of being counted in from either end.
    static func fileField(of literal: [UInt8]) -> Range<Int>? {
        let suffix = Array(gigalockerSuffix.utf8)
        let width = uuidReplacement.utf8.count
        guard literal.count > suffix.count,
              literal.suffix(suffix.count).elementsEqual(suffix),
              let slash = literal.lastIndex(of: UInt8(ascii: "/"))
        else { return nil }
        let fieldStart = slash + 1
        let fieldEnd = literal.count - suffix.count
        guard fieldEnd - fieldStart == width else { return nil }
        return fieldStart ..< fieldEnd
    }

    /// `true` for a field that still reads `%s`, `false` for one already
    /// reading `AA`, `nil` for anything else — which is not this patch's site.
    static func pristineness(of field: ArraySlice<UInt8>) -> Bool? {
        if field.elementsEqual(uuidConversion.utf8) {
            return true
        }
        if field.elementsEqual(uuidReplacement.utf8) {
            return false
        }
        return nil
    }

    /// Addresses of the `add` instructions that, with their `adrp`, materialise
    /// `vma` somewhere in `__TEXT,__text`.
    ///
    /// Pairing is the same shape `KernelPatcherBase.findStringRefs` uses, but
    /// read off Capstone's decoded operands rather than raw encodings: an
    /// `adrp` whose immediate is the literal's page, then an `add` within the
    /// window whose source register is that `adrp`'s destination and whose
    /// immediate is the literal's page offset.
    static func references(to vma: UInt64, in data: Data, text: MachOSectionInfo) -> [UInt64] {
        let start = Int(text.fileOffset)
        let size = Int(text.size)
        guard start >= 0, size > 0, start + size <= data.count else { return [] }
        let instructions = disassembler.disassemble(Data(data[start ..< start + size]), at: text.address)

        let page = vma & ~0xFFF
        let pageOffset = Int64(vma & 0xFFF)

        var sites: [UInt64] = []
        for (index, insn) in instructions.enumerated() {
            guard insn.mnemonic == "adrp",
                  let operands = insn.aarch64?.operands,
                  operands.count == 2,
                  operands[0].type == AARCH64_OP_REG,
                  operands[1].type == AARCH64_OP_IMM,
                  UInt64(bitPattern: operands[1].imm) == page
            else { continue }

            let base = operands[0].reg.rawValue
            let limit = Swift.min(index + addSearchWindow, instructions.count - 1)
            var cursor = index + 1
            while cursor <= limit {
                let candidate = instructions[cursor]
                cursor += 1
                guard candidate.mnemonic == "add",
                      let addOperands = candidate.aarch64?.operands,
                      addOperands.count == 3,
                      addOperands[0].type == AARCH64_OP_REG,
                      addOperands[1].type == AARCH64_OP_REG,
                      addOperands[1].reg.rawValue == base,
                      addOperands[2].type == AARCH64_OP_IMM,
                      addOperands[2].imm == pageOffset,
                      !isShiftedAddImmediate(candidate)
                else { continue }
                sites.append(candidate.address)
                break
            }
        }
        return sites
    }

    /// True when an `add` immediate carries `lsl #12`.
    ///
    /// The Swift Capstone wrapper does not surface an operand's shift, so the
    /// `sh` field is read off the instruction's own 32-bit encoding — still a
    /// property of the decode, never of the printed operand text. Without it an
    /// `add xD, xN, #imm, lsl #12` could be paired as if it computed
    /// `page + imm`, which is a different address than it really forms.
    static func isShiftedAddImmediate(_ insn: Instruction) -> Bool {
        guard insn.bytes.count == 4 else { return false }
        let word = UInt32(insn.bytes[0])
            | UInt32(insn.bytes[1]) << 8
            | UInt32(insn.bytes[2]) << 16
            | UInt32(insn.bytes[3]) << 24
        return (word >> 22) & 1 == 1
    }

    // MARK: - Reporting

    /// How the literal reads once the field is rewritten.
    static func patchedLiteral(of site: Site) -> String {
        var literal = Array(site.literal.utf8)
        guard let field = fileField(of: literal) else { return site.literal }
        literal.replaceSubrange(field, with: Array(uuidReplacement.utf8))
        return String(decoding: literal, as: UTF8.self)
    }

    /// The record for the one write, with the reference's own `patchID`,
    /// `component` and wording so a captured reference compares field for
    /// field.
    private static func record(for site: Site, original: Data, replacement: Data) -> PatchRecord {
        PatchRecord(
            patchID: "seputil.gigalocker_uuid",
            component: "seputil",
            fileOffset: site.fieldOffset,
            virtualAddress: site.fieldVMA,
            originalBytes: original,
            patchedBytes: replacement,
            description: "gigalocker path format '/\(uuidConversion)\(gigalockerSuffix)' "
                + "-> '/\(uuidReplacement)\(gigalockerSuffix)'",
        )
    }

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }

    private static func hex(_ value: Int) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
