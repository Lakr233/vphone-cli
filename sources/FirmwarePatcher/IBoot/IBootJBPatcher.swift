// IBootJBPatcher.swift — JB-variant iBoot patcher (nonce bypass).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

/// JB-variant patcher for iBoot images.
///
/// Adds iBSS-only patches:
///   1. patchSkipGenerateNonce — locate "boot-nonce" ADRP+ADD refs, find
///      tbz w0, #0, <target> / mov w0, #0 / bl pattern, convert tbz → b <target>
public final class IBootJBPatcher: IBootPatcher {
    override public func findAll() throws -> [PatchRecord] {
        patches = []
        if mode == .ibss {
            patchSkipGenerateNonce()
        }
        return patches
    }

    // MARK: - JB Patches

    @discardableResult
    func patchSkipGenerateNonce() -> Bool {
        let needle = Data("boot-nonce".utf8)
        let stringOffsets = buffer.findAll(needle)

        if stringOffsets.isEmpty {
            if verbose { print("  [-] iBSS JB: no refs to 'boot-nonce'") }
            return false
        }

        // Collect all ADRP+ADD sites that reference any "boot-nonce" occurrence.
        // Allow a small negative delta (up to 16 bytes before the string) because
        // code may reference the containing structure rather than the string itself.
        var addOffsets: [Int] = []
        for strOff in stringOffsets {
            let refs = findRefsNear(strOff, tolerance: 16)
            for (_, addOff) in refs {
                addOffsets.append(addOff)
            }
        }

        if addOffsets.isEmpty {
            if verbose { print("  [-] iBSS JB: no ADRP+ADD refs to 'boot-nonce'") }
            return false
        }

        // For each ADD ref, scan forward up to 0x100 bytes for the pattern:
        //   tbz/tbnz w0, #0, <target>
        //   mov w0, #0
        //   bl <anything>
        for addOff in addOffsets {
            let scanLimit = min(addOff + 0x100, buffer.count - 12)
            var scan = addOff
            while scan <= scanLimit {
                guard
                    let i0 = disasm.disassembleOne(in: buffer.data, at: scan),
                    let i1 = disasm.disassembleOne(in: buffer.data, at: scan + 4),
                    let i2 = disasm.disassembleOne(in: buffer.data, at: scan + 8)
                else {
                    scan += 4
                    continue
                }

                // i0 must be tbz or tbnz
                guard i0.mnemonic == "tbz" || i0.mnemonic == "tbnz" else {
                    scan += 4
                    continue
                }

                // i0 operands: [0]=reg (w0), [1]=bit (0), [2]=target address
                guard
                    let detail0 = i0.aarch64,
                    detail0.operands.count >= 3,
                    detail0.operands[0].type == AARCH64_OP_REG,
                    detail0.operands[0].reg.rawValue == AARCH64_REG_W0.rawValue,
                    detail0.operands[1].type == AARCH64_OP_IMM,
                    detail0.operands[1].imm == 0
                else {
                    scan += 4
                    continue
                }

                // i1 must be: mov w0, #0
                guard i1.mnemonic == "mov", i1.operandString == "w0, #0" else {
                    scan += 4
                    continue
                }

                // i2 must be bl
                guard i2.mnemonic == "bl" else {
                    scan += 4
                    continue
                }

                // Branch target from tbz operand[2]
                let target = Int(detail0.operands[2].imm)

                guard let patchBytes = ARM64Encoder.encodeB(from: scan, to: target) else {
                    if verbose {
                        print(String(format: "  [-] iBSS JB: encodeB out of range at 0x%X → 0x%X", scan, target))
                    }
                    scan += 4
                    continue
                }

                let originalBytes = buffer.readBytes(at: scan, count: 4)
                let beforeStr = "\(i0.mnemonic) \(i0.operandString)"
                let afterInsn = disasm.disassembleOne(patchBytes, at: UInt64(scan))
                let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "b"

                let record = PatchRecord(
                    patchID: "ibss_jb.skip_generate_nonce",
                    component: component,
                    fileOffset: scan,
                    virtualAddress: nil,
                    originalBytes: originalBytes,
                    patchedBytes: patchBytes,
                    beforeDisasm: beforeStr,
                    afterDisasm: afterStr,
                    description: "JB: skip generate_nonce"
                )
                patches.append(record)

                if verbose {
                    print(String(format: "  0x%06X: %@ → %@  [ibss_jb.skip_generate_nonce]",
                                 scan, beforeStr, afterStr))
                }
                return true
            }
        }

        if verbose { print("  [-] iBSS JB: generate_nonce branch pattern not found") }
        return false
    }

    // MARK: - Reference Search Helpers

    /// Find all ADRP+ADD pairs that point within `tolerance` bytes before `targetOff`.
    ///
    /// This handles the common case where code references a structure header
    /// a few bytes before the actual string (e.g. a length-prefixed property).
    private func findRefsNear(_ targetOff: Int, tolerance: Int) -> [(adrpOff: Int, addOff: Int)] {
        let data = buffer.data
        let size = buffer.count
        var refs: [(Int, Int)] = []

        var off = 0
        while off + 8 <= size {
            guard
                let a = disasm.disassembleOne(in: data, at: off),
                let b = disasm.disassembleOne(in: data, at: off + 4)
            else {
                off += 4
                continue
            }

            guard
                a.mnemonic == "adrp",
                b.mnemonic == "add",
                let detA = a.aarch64,
                let detB = b.aarch64,
                detA.operands.count >= 2,
                detB.operands.count >= 3,
                detA.operands[0].reg.rawValue == detB.operands[1].reg.rawValue,
                detA.operands[1].type == AARCH64_OP_IMM,
                detB.operands[2].type == AARCH64_OP_IMM
            else {
                off += 4
                continue
            }

            let pageAddr = detA.operands[1].imm
            let addImm = detB.operands[2].imm
            let computed = Int(pageAddr + addImm)
            let delta = targetOff - computed

            if delta >= 0, delta <= tolerance {
                refs.append((off, off + 4))
            }

            off += 4
        }

        return refs
    }

    /// Find all ADRP+ADD pairs in the binary that point to `targetOff`.
    ///
    /// Scans the entire buffer in 4-byte steps, checking consecutive instruction
    /// pairs for the ADRP+ADD pattern. Matches when
    /// `adrp_page_addr + add_imm12 == targetOff` (raw binary, base address = 0).
    private func findRefsToOffset(_ targetOff: Int) -> [(adrpOff: Int, addOff: Int)] {
        let data = buffer.data
        let size = buffer.count
        var refs: [(Int, Int)] = []

        var off = 0
        while off + 8 <= size {
            guard
                let a = disasm.disassembleOne(in: data, at: off),
                let b = disasm.disassembleOne(in: data, at: off + 4)
            else {
                off += 4
                continue
            }

            guard
                a.mnemonic == "adrp",
                b.mnemonic == "add",
                let detA = a.aarch64,
                let detB = b.aarch64,
                detA.operands.count >= 2,
                detB.operands.count >= 3,
                // Destination register of ADRP must match source register of ADD
                detA.operands[0].reg.rawValue == detB.operands[1].reg.rawValue,
                detA.operands[1].type == AARCH64_OP_IMM,
                detB.operands[2].type == AARCH64_OP_IMM
            else {
                off += 4
                continue
            }

            let pageAddr = detA.operands[1].imm // ADRP result (page-aligned VA)
            let addImm = detB.operands[2].imm // ADD immediate (page offset)

            if pageAddr + addImm == Int64(targetOff) {
                refs.append((off, off + 4))
            }

            off += 4
        }

        return refs
    }
}
