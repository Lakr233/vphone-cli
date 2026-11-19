// IBootPatchNVRAMScrubBypass.swift — LLB keeps NVRAM as an iPhone's iBoot does.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.
//
// The Private Cloud Compute boot loaders (vresearch101 and the j226c/j236c
// servers) scrub NVRAM right after loading it: unless `boot-command` is
// "upgrade", they read a keep list of names (auto-boot, boot-volume,
// stress-rack, the obliteration and darwin-init state, ...), delete every
// variable that came from NVRAM, set the kept ones again and save. An
// iPhone's iBoot does not (iPhone17,3 27.2 LLB: the same init step loads
// NVRAM and runs the Developer Mode handler, with no scrub between). So on a
// guest, everything iOS writes to NVRAM (language, volume, Find My, panic and
// update state) is gone at the next boot.
//
// That includes the Developer Mode request. Settings › Developer Mode ›
// Restart makes AMFI write `security-mode-change-enable`; on the next boot
// iBoot's handler copies it to /chosen and deletes it, AMFI delays latching
// Developer Mode, and PreBoard asks "Ready to Enable Developer Mode". The
// vresearch101 LLB (the only boot stage on the research board) has that
// handler too, but the scrub deletes the request first.
//
// The scrub starts with Apple's own way out (cloudOS 27.2 24B115 RELEASE):
//
//     adrp x0, "boot-command"@PAGE
//     add  x0, x0, "boot-command"@PAGEOFF
//     ...                            ; x1, x2: the name's bounds
//     bl   <env lookup>
//     cbz  x0, scrub                 ; no boot-command: scrub
//     adrp x4, "upgrade"@PAGE
//     add  x4, x4, "upgrade"@PAGEOFF
//     ...                            ; the compare's other arguments
//     bl   <compare>
//     cbz  w0, done                  ; "upgrade": skip the scrub and the save
//   scrub:
//
// The patch turns the first `cbz` into `b done`, so every boot takes the
// "upgrade" path and NVRAM stays as the guest left it. iBoot still reads only
// the names on its own NVRAM table (boot-args included only in
// RESEARCH_RELEASE), so this does not open more variables to LLB than a
// device's iBoot reads. The same `boot-command`/"upgrade" test exists outside
// the scrub, so the match starts at the keep list, which only the scrub
// builds, and must find exactly one site. Every vresearch101 LLB from cloudOS
// 18.6 (22G86) to 27.2 (24B115), RELEASE and RESEARCH_RELEASE, has exactly one.
//
// A preset that selects the patch on an LLB without that one site fails the
// patch step instead of booting a guest whose Developer Mode silently never
// latches.

import Foundation
import VPhonePatchKit

extension IBootPatcher {
    // MARK: - NVRAM Scrub Bypass (LLB)

    /// A keep-list name only the scrub references: a rack-testing switch.
    static let nvramScrubKeepListName = "stress-rack"
    /// The variable whose value decides whether LLB scrubs.
    static let nvramScrubCommandName = "boot-command"
    /// The `boot-command` value that makes LLB skip the scrub.
    static let nvramScrubSkipCommand = "upgrade"

    /// The scrub bypass is selected, but this LLB does not have exactly one
    /// place to apply it.
    struct NVRAMScrubBypassMiss: Error, CustomStringConvertible {
        let description: String
    }

    /// One `boot-command` == "upgrade" test after the keep list.
    struct NVRAMScrubUpgradeTest: Hashable {
        /// The `cbz x0` taken when there is no boot-command.
        let test: Int
        /// Where the "upgrade" path continues, past the scrub.
        let done: Int
    }

    func patchNVRAMScrubBypass() throws {
        let id = "\(component)-exp-nvram_scrub_bypass"
        let sites = nvramScrubUpgradeTests()
        guard sites.count == 1, let site = sites.first,
              let branch = ARM64Encoder.encodeB(from: site.test, to: site.done)
        else {
            let reason = sites.isEmpty
                ? "no \(Self.nvramScrubCommandName) == \"\(Self.nvramScrubSkipCommand)\" test after the keep list"
                : "\(sites.count) candidate tests (" + sites.map { String(format: "0x%X", $0.test) }.joined(separator: ", ") + "), expected one"
            guard !gateAllows(id) else {
                throw NVRAMScrubBypassMiss(description: "\(id): \(reason). This LLB is not one the patch was matched against, so a guest would lose NVRAM, and its Developer Mode request, at every boot.")
            }
            if verbose { print("  [-] nvram scrub: \(reason)") }
            return
        }
        emit(site.test, branch, id: id, description: "nvram scrub: always take the upgrade path (keep NVRAM)")
    }

    // MARK: - Matching

    /// Every distinct upgrade test within the function after a keep-list
    /// reference. LLB carries some names twice, once as a table copy, so
    /// every copy's references are searched.
    func nvramScrubUpgradeTests() -> [NVRAMScrubUpgradeTest] {
        let keepListXrefs = findCStrings(Self.nvramScrubKeepListName).flatMap { findADRPAddReferences(to: $0) }
        var sites: [NVRAMScrubUpgradeTest] = []
        for xref in keepListXrefs {
            // The test follows the keep list in the same function: 0x434 bytes
            // later in 27.2 RELEASE, 0x538 in RESEARCH_RELEASE.
            let limit = min(xref + 0x800, buffer.original.count - 12)
            for offset in stride(from: xref, to: limit, by: 4) {
                if let site = upgradeTest(at: offset), !sites.contains(site) {
                    sites.append(site)
                }
            }
        }
        return sites
    }

    /// The upgrade test whose `cbz x0, scrub` is at `offset`, or nil.
    ///
    /// `x0` must be the result of a `bl` taking `"boot-command"` in `x0`, and
    /// the "upgrade" compare must be a `bl` whose `w0` the next `cbz` tests,
    /// with `scrub` right after that `cbz`.
    private func upgradeTest(at offset: Int) -> NVRAMScrubUpgradeTest? {
        let data = buffer.original
        guard offset >= 4,
              let lookup = disasm.disassembleOne(in: data, at: offset - 4), lookup.mnemonic == "bl",
              loadsCString(Self.nvramScrubCommandName, into: 0, before: offset - 4),
              let first = disasm.disassembleOne(in: data, at: offset), first.mnemonic == "cbz",
              let firstOperands = first.detail?.operands, firstOperands.count == 2,
              firstOperands[0].type == .register, firstOperands[0].reg == .x(0),
              firstOperands[1].type == .immediate,
              let page = disasm.disassembleOne(in: data, at: offset + 4), page.mnemonic == "adrp",
              let low = disasm.disassembleOne(in: data, at: offset + 8), low.mnemonic == "add",
              let pageOperands = page.detail?.operands, pageOperands.count >= 2,
              let lowOperands = low.detail?.operands, lowOperands.count >= 3,
              pageOperands[0].reg == lowOperands[1].reg,
              pageOperands[1].type == .immediate, lowOperands[2].type == .immediate,
              isCString(Self.nvramScrubSkipCommand, at: Int(pageOperands[1].imm + lowOperands[2].imm))
        else { return nil }

        let scrub = Int(firstOperands[1].imm)
        // The compare's arguments and call: eight instructions in every observed build.
        var calledCompare = false
        for candidate in stride(from: offset + 12, to: min(offset + 12 + 10 * 4, data.count - 4), by: 4) {
            guard let instruction = disasm.disassembleOne(in: data, at: candidate) else { return nil }
            if !calledCompare {
                if instruction.mnemonic == "bl" {
                    calledCompare = true
                } else if Self.controlFlowMnemonics.contains(instruction.mnemonic) || instruction.mnemonic.hasPrefix("b.") {
                    return nil
                }
                continue
            }
            guard instruction.mnemonic == "cbz",
                  let operands = instruction.detail?.operands, operands.count == 2,
                  operands[0].type == .register, operands[0].reg == .w(0),
                  operands[1].type == .immediate,
                  candidate + 4 == scrub
            else { return nil }
            return NVRAMScrubUpgradeTest(test: offset, done: Int(operands[1].imm))
        }
        return nil
    }

    /// Whether one of the six instructions before `call` is
    /// `add xN, xN, #lo` after `adrp xN, #page`, pointing at `text`.
    private func loadsCString(_ text: String, into register: Int, before call: Int) -> Bool {
        let data = buffer.original
        for back in 1 ... 6 {
            let addOffset = call - back * 4
            guard addOffset >= 4,
                  let add = disasm.disassembleOne(in: data, at: addOffset), add.mnemonic == "add",
                  let addOperands = add.detail?.operands, addOperands.count == 3,
                  addOperands[0].reg == .x(register), addOperands[1].reg == .x(register),
                  addOperands[2].type == .immediate,
                  let page = disasm.disassembleOne(in: data, at: addOffset - 4), page.mnemonic == "adrp",
                  let pageOperands = page.detail?.operands, pageOperands.count == 2,
                  pageOperands[0].reg == .x(register), pageOperands[1].type == .immediate
            else { continue }
            return isCString(text, at: Int(pageOperands[1].imm + addOperands[2].imm))
        }
        return false
    }

    /// Branches other than `b.cond`, which would leave the compare's setup.
    private static let controlFlowMnemonics: Set<String> = ["b", "br", "blr", "ret", "cbz", "cbnz", "tbz", "tbnz"]

    /// Whether `text` + NUL is at `offset`.
    private func isCString(_ text: String, at offset: Int) -> Bool {
        let needle = Data(text.utf8) + Data([0])
        guard offset >= 0, offset + needle.count <= buffer.original.count else { return false }
        return buffer.original[offset ..< offset + needle.count].elementsEqual(needle)
    }
}
