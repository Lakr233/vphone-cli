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
// The scrub starts with Apple's own way out:
//
//     bl   getenv("boot-command")
//     cbz  x0, scrub                 ; no boot-command: scrub
//     adrp x4, "upgrade"@PAGE
//     add  x4, x4, "upgrade"@PAGEOFF
//     ...
//     bl   strcmp-like
//     cbz  w0, done                  ; "upgrade": skip the scrub and the save
//   scrub:
//
// The patch turns the first `cbz` into `b done`, so every boot takes the
// "upgrade" path and NVRAM stays as the guest left it (cloudOS 27.2 24B115
// RELEASE 0x5BFC, RESEARCH_RELEASE 0x5F00). iBoot still reads only the names on
// its own NVRAM table (boot-args included only in RESEARCH_RELEASE), so this
// does not open more variables to LLB than a device's iBoot reads. The same
// `boot-command`/"upgrade" test exists outside the scrub, so the match starts
// at the keep list, which only the scrub builds.

import Foundation
import VPhonePatchKit

extension IBootPatcher {
    // MARK: - NVRAM Scrub Bypass (LLB)

    /// A keep-list name only the scrub references: a rack-testing switch.
    static let nvramScrubKeepListName = "stress-rack"
    /// The `boot-command` value that makes LLB skip the scrub.
    static let nvramScrubSkipCommand = "upgrade"

    func patchNVRAMScrubBypass() {
        let id = "\(component)-exp-nvram_scrub_bypass"
        // LLB carries some names twice, once as a table copy, so every copy's
        // references are candidates.
        let keepListXrefs = findCStrings(Self.nvramScrubKeepListName).flatMap { findADRPAddReferences(to: $0) }
        guard !keepListXrefs.isEmpty else {
            if verbose { print("  [-] nvram scrub: no keep list (\(Self.nvramScrubKeepListName) not referenced)") }
            return
        }

        for xref in keepListXrefs {
            // The test follows the keep list in the same function: 0x434 bytes
            // later in 27.2 RELEASE, 0x538 in RESEARCH_RELEASE.
            let limit = min(xref + 0x800, buffer.original.count - 12)
            for offset in stride(from: xref, to: limit, by: 4) {
                guard let done = upgradeSkipTarget(at: offset),
                      let branch = ARM64Encoder.encodeB(from: offset, to: done)
                else { continue }
                emit(offset, branch, id: id, description: "nvram scrub: always take the upgrade path (keep NVRAM)")
                return
            }
        }

        if verbose { print("  [-] nvram scrub: upgrade test not found") }
    }

    // MARK: - Matching

    /// For `cbz xN, scrub ; adrp/add "upgrade" ; ... ; cbz wM, done` at
    /// `offset`, where `scrub` is the instruction after the second `cbz`,
    /// returns `done`.
    private func upgradeSkipTarget(at offset: Int) -> Int? {
        let data = buffer.original
        guard let first = disasm.disassembleOne(in: data, at: offset), first.mnemonic == "cbz",
              let firstOperands = first.detail?.operands, firstOperands.count == 2,
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
        // The compare call and its arguments: eight instructions in every observed build.
        for candidate in stride(from: offset + 12, to: min(offset + 12 + 10 * 4, data.count - 4), by: 4) {
            guard let second = disasm.disassembleOne(in: data, at: candidate) else { return nil }
            guard second.mnemonic == "cbz" else { continue }
            guard let operands = second.detail?.operands, operands.count == 2,
                  operands[1].type == .immediate,
                  candidate + 4 == scrub
            else { return nil }
            return Int(operands[1].imm)
        }
        return nil
    }

    /// Whether `text` + NUL is at `offset`.
    private func isCString(_ text: String, at offset: Int) -> Bool {
        let needle = Data(text.utf8) + Data([0])
        guard offset >= 0, offset + needle.count <= buffer.original.count else { return false }
        return buffer.original[offset ..< offset + needle.count].elementsEqual(needle)
    }
}
