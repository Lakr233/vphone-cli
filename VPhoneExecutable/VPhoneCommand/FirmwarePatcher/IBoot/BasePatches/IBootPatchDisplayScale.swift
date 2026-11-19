// IBootPatchDisplayScale.swift — LLB `/chosen/display-scale` for an iPad guest.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.
//
// The guest's UIScreen scale is MobileGestalt's `main-screen-scale`, which
// libMobileGestalt reads from `IODeviceTree:/chosen/display-scale` — the only
// reader of that property in the iOS 26.6.2 userland. LLB (the single-stage
// boot path, so it is LLB and not iBoot that prepares the kernel's tree) fills
// it from the boot video depth word:
//
//     adrp x8, "display-scale"@PAGE ; add x8, x8, "display-scale"@PAGEOFF
//     ...                              ; look the property up in /chosen
//     ubfx w8, w20, #16, #8           ; v_depth scale byte
//     add  w8, w8, #1                 ; stored as scale - 1
//     str  w8, [x0]                   ; property value
//
// For the paravirtual display that byte always says 3, whatever the panel's
// size or density, which is right for the phone vphone600 is and wrong for an
// iPad: an iPad mini's 1488x2266 panel at 3x is 496x755 points, a phone-sized
// canvas the iPad layouts overflow. The patch replaces the `add` with
// `mov w8, #<scale>`, so the property carries the guest device's own artwork
// scale and the screen is 744x1133 points, as on the real device. The boot
// video word itself, which only the kernel's boot console reads, is left alone.

import Foundation
import VPhonePatchKit

extension IBootPatcher {
    // MARK: - Display Scale (LLB, iPad guests only)

    static let displayScaleProperty = "display-scale"

    func patchDisplayScale(_ scale: UInt16) {
        let id = "\(component)-cfw-display_scale"
        guard let stringOffset = findCString(Self.displayScaleProperty) else {
            if verbose {
                print("  [-] display-scale: property name not found")
            }
            return
        }

        for xref in findADRPAddReferences(to: stringOffset) {
            // The value the property gets is computed a few lookups after its name
            // is loaded; 48 instructions is past the store for every observed build.
            var offset = xref + 8
            let limit = min(xref + 8 + 48 * 4, buffer.original.count - 12)
            while offset <= limit {
                defer { offset += 4 }
                guard let extract = disasm.disassembleOne(in: buffer.original, at: offset),
                      let increment = disasm.disassembleOne(in: buffer.original, at: offset + 4),
                      let store = disasm.disassembleOne(in: buffer.original, at: offset + 8),
                      let register = scaleByteExtract(extract),
                      isIncrementByOne(increment, of: register),
                      isStore(store, of: register),
                      let number = generalRegisterNumber(register),
                      let replacement = ARM64Encoder.encodeMovzW(rd: UInt32(number), imm16: scale)
                else { continue }

                emit(
                    offset + 4,
                    replacement,
                    id: id,
                    description: "display-scale: \(scale)x instead of the boot video's",
                )
                return
            }
        }

        if verbose {
            print("  [-] display-scale: value computation not found")
        }
    }

    // MARK: - Matching

    /// `ubfx wN, wM, #16, #8`: the boot video depth word's scale byte. Returns wN.
    private func scaleByteExtract(_ instruction: ARM64Instruction) -> ARM64Register? {
        guard instruction.mnemonic == "ubfx",
              let operands = instruction.detail?.operands,
              operands.count == 4,
              operands[0].type == .register,
              operands[1].type == .register,
              operands[2].type == .immediate, operands[2].imm == 16,
              operands[3].type == .immediate, operands[3].imm == 8
        else { return nil }
        return operands[0].reg
    }

    /// `add wN, wN, #1`.
    private func isIncrementByOne(_ instruction: ARM64Instruction, of register: ARM64Register) -> Bool {
        guard instruction.mnemonic == "add",
              let operands = instruction.detail?.operands,
              operands.count == 3,
              operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .register, operands[1].reg == register,
              operands[2].type == .immediate, operands[2].imm == 1
        else { return false }
        return true
    }

    /// `str wN, [xK]` — the property value, written in place.
    private func isStore(_ instruction: ARM64Instruction, of register: ARM64Register) -> Bool {
        guard instruction.mnemonic == "str",
              let operands = instruction.detail?.operands,
              operands.count == 2,
              operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .memory, operands[1].mem.disp == 0
        else { return false }
        return true
    }

    private func generalRegisterNumber(_ register: ARM64Register) -> Int? {
        (0 ... 30).first { ARM64Register.w($0) == register }
    }

    // MARK: - References

    /// Offset of a NUL-terminated string that starts on a string boundary.
    private func findCString(_ text: String) -> Int? {
        findCStrings(text).first
    }

    /// Every copy of `text` + NUL that starts on a string boundary.
    func findCStrings(_ text: String) -> [Int] {
        let needle = Data(text.utf8) + Data([0])
        return buffer.findAll(needle).filter { $0 == 0 || buffer.original[$0 - 1] == 0 }
    }

    /// ADRP+ADD pairs that materialise `target` (raw binary, base address 0:
    /// the page arithmetic is the same at any page-aligned load address).
    func findADRPAddReferences(to target: Int) -> [Int] {
        let data = buffer.original
        var references: [Int] = []
        var offset = 0
        while offset + 8 <= data.count {
            defer { offset += 4 }
            guard let adrp = disasm.disassembleOne(in: data, at: offset), adrp.mnemonic == "adrp",
                  let add = disasm.disassembleOne(in: data, at: offset + 4), add.mnemonic == "add",
                  let page = adrp.detail?.operands, page.count >= 2,
                  let low = add.detail?.operands, low.count >= 3,
                  page[0].reg == low[1].reg,
                  page[1].type == .immediate, low[2].type == .immediate,
                  page[1].imm + low[2].imm == Int64(target)
            else { continue }
            references.append(offset)
        }
        return references
    }
}
