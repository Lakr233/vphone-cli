// KernelJBPatchCredLabel.swift — JB kernel patch: _cred_label_update_execve C21-v3
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (C21-v3): Split late exits, add helper bits on success.
//   - Keep _cred_label_update_execve body intact.
//   - Redirect the shared deny return (MOV W0,#1 just before epilogue) to a
//     deny cave that forces W0=0 and returns through the original epilogue.
//   - Redirect late success exits (B epilogue preceded by MOV W0,#0) to a
//     success cave that reloads x26 = u_int *csflags, clears kill bits, ORs
//     CS_GET_TASK_ALLOW|CS_INSTALLER, forces W0=0, then returns via epilogue.
//
// CS mask constants (matching Python):
//   RELAX_CSMASK   = 0xFFFFC0FF  (clears CS_HARD|CS_KILL|CS_RESTRICT etc.)
//   RELAX_SETMASK  = 0x0000000C  (CS_GET_TASK_ALLOW | CS_INSTALLER)

import Foundation

extension KernelJBPatcher {
    // MARK: - Constants

    private static let retInsns: Set<UInt32> = [0xD65F_0FFF, 0xD65F_0BFF, 0xD65F_03C0]
    private static let movW0_0_u32: UInt32 = 0x5280_0000
    private static let movW0_1_u32: UInt32 = 0x5280_0020
    private static let relaxCSMask: UInt32 = 0xFFFF_C0FF
    private static let relaxSetMask: UInt32 = 0x0000_000C

    // MARK: - Entry Point

    /// C21-v3 split exits + helper bits for _cred_label_update_execve.
    func patchCredLabelUpdateExecve() {
        log("\n[JB] _cred_label_update_execve: C21-v3 split exits + helper bits")

        // 1. Locate the function.
        guard let funcOff = locateCredLabelExecveFunc() else {
            log("  [-] function not found, skipping shellcode patch")
            return
        }
        log("  [+] func at 0x\(String(format: "%X", funcOff))")

        // 2. Find canonical epilogue: last `ldp x29, x30, [sp, ...]` before ret.
        guard let epilogueOff = findCredLabelEpilogue(funcOff: funcOff) else {
            log("  [-] epilogue not found")
            return
        }
        log("  [+] epilogue at 0x\(String(format: "%X", epilogueOff))")

        // 3. Find shared deny return: MOV W0,#1 immediately before the epilogue.
        let denyOff = findCredLabelDenyReturn(funcOff: funcOff, epilogueOff: epilogueOff)

        // Check if deny is already allow
        let denyAlreadyAllowed: Bool
        if let denyOff {
            denyAlreadyAllowed = buffer.readU32(at: denyOff) == Self.movW0_0_u32
            if denyAlreadyAllowed {
                log("  [=] deny return at 0x\(String(format: "%X", denyOff)) already MOV W0,#0, skipping deny trampoline")
            }
        } else {
            log("  [-] shared deny return not found")
            return
        }

        // 4. Find success exits: B epilogue with preceding MOV W0,#0.
        let successExits = findCredLabelSuccessExits(funcOff: funcOff, epilogueOff: epilogueOff)
        guard !successExits.isEmpty else {
            log("  [-] success exits not found")
            return
        }

        // 5. Recover csflags stack reload instruction bytes.
        guard let (csflagsInsn, _) = findCredLabelCSFlagsReload(funcOff: funcOff) else {
            log("  [-] csflags stack reload (ldr x26, [x29, #imm]) not found")
            return
        }

        // 6. Allocate code caves.
        var denyCaveOff: Int? = nil
        if !denyAlreadyAllowed {
            denyCaveOff = findCodeCave(size: 8)
            guard denyCaveOff != nil else {
                log("  [-] no code cave for C21-v3 deny trampoline")
                return
            }
        }

        // Success cave: 8 instructions = 32 bytes
        guard let successCaveOff = findCodeCave(size: 32),
              successCaveOff != denyCaveOff
        else {
            log("  [-] no code cave for C21-v3 success trampoline")
            return
        }

        // 7. Build deny shellcode (8 bytes): MOV W0,#0 + B epilogue.
        if !denyAlreadyAllowed, let dOff = denyOff, let dCaveOff = denyCaveOff {
            guard let branchBack = encodeB(from: dCaveOff + 4, to: epilogueOff) else {
                log("  [-] deny trampoline → epilogue branch out of range")
                return
            }
            let denyShellcode = ARM64.movW0_0 + branchBack

            // Write deny cave
            for i in stride(from: 0, to: denyShellcode.count, by: 4) {
                let chunk = denyShellcode[denyShellcode.index(denyShellcode.startIndex, offsetBy: i) ..< denyShellcode.index(denyShellcode.startIndex, offsetBy: i + 4)]
                emit(dCaveOff + i, Data(chunk),
                     patchID: "jb.cred_label_update_execve.deny_cave",
                     description: "deny_trampoline+\(i) [_cred_label_update_execve C21-v3]")
            }

            // Redirect deny site → deny cave
            guard let branchToCave = encodeB(from: dOff, to: dCaveOff) else {
                log("  [-] branch from deny site 0x\(String(format: "%X", dOff)) to cave out of range")
                return
            }
            emit(dOff, branchToCave,
                 patchID: "jb.cred_label_update_execve.deny_redirect",
                 description: "b deny cave [_cred_label_update_execve C21-v3 exit @ 0x\(String(format: "%X", dOff))]")
        }

        // 8. Build success shellcode (8 instrs = 32 bytes):
        //   ldr x26, [x29, #imm]      (reload csflags ptr from stack)
        //   cbz x26, #0x10             (skip if null)
        //   ldr w8, [x26]
        //   and w8, w8, #relaxCSMask
        //   orr w8, w8, #relaxSetMask
        //   str w8, [x26]
        //   mov w0, #0
        //   b epilogue
        guard let successBranchBack = encodeB(from: successCaveOff + 28, to: epilogueOff) else {
            log("  [-] success trampoline → epilogue branch out of range")
            return
        }

        var successShellcode = Data()
        successShellcode += csflagsInsn // ldr x26, [x29, #imm]
        successShellcode += encodeCBZ_X26_skip16() // cbz x26, #0x10 (skip 4 insns)
        successShellcode += encodeLDR_W8_X26() // ldr w8, [x26]
        successShellcode += encodeAND_W8_W8_mask(Self.relaxCSMask) // and w8, w8, #0xFFFFC0FF
        successShellcode += encodeORR_W8_W8_imm(Self.relaxSetMask) // orr w8, w8, #0xC
        successShellcode += encodeSTR_W8_X26() // str w8, [x26]
        successShellcode += ARM64.movW0_0 // mov w0, #0
        successShellcode += successBranchBack // b epilogue

        guard successShellcode.count == 32 else {
            log("  [-] success shellcode size mismatch: \(successShellcode.count) != 32")
            return
        }

        for i in stride(from: 0, to: successShellcode.count, by: 4) {
            let chunk = successShellcode[successShellcode.index(successShellcode.startIndex, offsetBy: i) ..< successShellcode.index(successShellcode.startIndex, offsetBy: i + 4)]
            emit(successCaveOff + i, Data(chunk),
                 patchID: "jb.cred_label_update_execve.success_cave",
                 description: "success_trampoline+\(i) [_cred_label_update_execve C21-v3]")
        }

        // 9. Redirect success exits → success cave.
        for exitOff in successExits {
            guard let branchToCave = encodeB(from: exitOff, to: successCaveOff) else {
                log("  [-] branch from success exit 0x\(String(format: "%X", exitOff)) to cave out of range")
                return
            }
            emit(exitOff, branchToCave,
                 patchID: "jb.cred_label_update_execve.success_redirect",
                 description: "b success cave [_cred_label_update_execve C21-v3 exit @ 0x\(String(format: "%X", exitOff))]")
        }
    }

    // MARK: - Function Locators

    /// Locate _cred_label_update_execve: try symbol first, then string-cluster scan.
    private func locateCredLabelExecveFunc() -> Int? {
        // Symbol lookup
        for (sym, off) in symbols {
            if sym.contains("cred_label_update_execve"), !sym.contains("hook") {
                if isCredLabelExecveCandidate(funcOff: off) {
                    return off
                }
            }
        }
        return findCredLabelExecveByStrings()
    }

    /// Validate candidate function shape for _cred_label_update_execve.
    private func isCredLabelExecveCandidate(funcOff: Int) -> Bool {
        let funcEnd = findFuncEnd(funcOff, maxSize: 0x1000)
        guard funcEnd - funcOff >= 0x200 else { return false }
        // Must contain ldr x26, [x29, #imm]
        return findCredLabelCSFlagsReload(funcOff: funcOff) != nil
    }

    /// String-cluster search for _cred_label_update_execve.
    private func findCredLabelExecveByStrings() -> Int? {
        let anchorStrings = [
            "AMFI: hook..execve() killing",
            "Attempt to execute completely unsigned code",
            "Attempt to execute a Legacy VPN Plugin",
            "dyld signature cannot be verified",
        ]
        var candidates: Set<Int> = []
        for anchor in anchorStrings {
            guard let strOff = buffer.findString(anchor) else { continue }
            let refs = findStringRefs(strOff)
            for (adrpOff, _) in refs {
                if let funcStart = findFunctionStart(adrpOff) {
                    candidates.insert(funcStart)
                }
            }
        }
        // Pick best candidate (largest, as a proxy for most complex body)
        var bestFunc: Int? = nil
        var bestScore = -1
        for funcOff in candidates {
            let funcEnd = findFuncEnd(funcOff, maxSize: 0x1000)
            let score = funcEnd - funcOff
            if score > bestScore, isCredLabelExecveCandidate(funcOff: funcOff) {
                bestScore = score
                bestFunc = funcOff
            }
        }
        return bestFunc
    }

    // MARK: - Epilogue / Deny / Success Finders

    /// Find the canonical epilogue: last `ldp x29, x30, [sp, ...]` in function.
    private func findCredLabelEpilogue(funcOff: Int) -> Int? {
        let funcEnd = findFuncEnd(funcOff, maxSize: 0x1000)
        for off in stride(from: funcEnd - 4, through: funcOff, by: -4) {
            guard let insn = disasAt(off) else { continue }
            let op = insn.operandString.replacingOccurrences(of: " ", with: "")
            if insn.mnemonic == "ldp", op.hasPrefix("x29,x30,[sp") {
                return off
            }
        }
        return nil
    }

    /// Find shared deny return: MOV W0,#1 at epilogueOff - 4.
    private func findCredLabelDenyReturn(funcOff: Int, epilogueOff: Int) -> Int? {
        let scanStart = max(funcOff, epilogueOff - 0x40)
        for off in stride(from: epilogueOff - 4, through: scanStart, by: -4) {
            if buffer.readU32(at: off) == Self.movW0_1_u32, off + 4 == epilogueOff {
                return off
            }
        }
        return nil
    }

    /// Find success exits: `b epilogue` preceded (within 0x10 bytes) by `mov w0, #0`.
    private func findCredLabelSuccessExits(funcOff: Int, epilogueOff: Int) -> [Int] {
        var exits: [Int] = []
        let funcEnd = findFuncEnd(funcOff, maxSize: 0x1000)
        for off in stride(from: funcOff, to: funcEnd, by: 4) {
            guard let target = jbDecodeBBranch(at: off), target == epilogueOff else { continue }
            // Scan back for MOV W0, #0 in preceding 4 instructions
            var hasMov = false
            let scanBack = max(funcOff, off - 0x10)
            for prev in stride(from: off - 4, through: scanBack, by: -4) {
                if buffer.readU32(at: prev) == Self.movW0_0_u32 {
                    hasMov = true
                    break
                }
            }
            if hasMov { exits.append(off) }
        }
        return exits
    }

    /// Recover ldr x26, [x29, #imm] instruction bytes from the function body.
    private func findCredLabelCSFlagsReload(funcOff: Int) -> (Data, String)? {
        let funcEnd = findFuncEnd(funcOff, maxSize: 0x1000)
        for off in stride(from: funcOff, to: funcEnd, by: 4) {
            guard let insn = disasAt(off) else { continue }
            let op = insn.operandString.replacingOccurrences(of: " ", with: "")
            if insn.mnemonic == "ldr", op.hasPrefix("x26,[x29") {
                // Return the raw 4 bytes plus the disassembly string
                let insnBytes = buffer.data[off ..< off + 4]
                return (Data(insnBytes), insn.operandString)
            }
        }
        return nil
    }

    // MARK: - Instruction Encoders

    /// CBZ X26, #0x10  — skip 4 instructions if x26 == 0
    private func encodeCBZ_X26_skip16() -> Data {
        // CBZ encoding: [31]=1 (64-bit), [30:24]=0110100, [23:5]=imm19, [4:0]=Rt
        // imm19 = offset/4 = 16/4 = 4  → bits [23:5] = 4 << 5 = 0x80
        // Full: 1_0110100_000000000000000000100_11010 = ?
        // CBZ X26 = 0xB400_0000 | (imm19 << 5) | 26
        // imm19 = 4, Rt = 26 (x26)
        let imm19: UInt32 = 4
        let insn: UInt32 = 0xB400_0000 | (imm19 << 5) | 26
        return ARM64.encodeU32(insn)
    }

    /// LDR W8, [X26]
    private func encodeLDR_W8_X26() -> Data {
        // LDR W8, [X26] — 32-bit load, no offset
        // Encoding: size=10, V=0, opc=01, imm12=0, Rn=X26(26), Rt=W8(8)
        // 1011 1001 0100 0000 0000 0011 0100 1000
        // 0xB940_0348
        let insn: UInt32 = 0xB940_0348
        return ARM64.encodeU32(insn)
    }

    /// STR W8, [X26]
    private func encodeSTR_W8_X26() -> Data {
        // STR W8, [X26] — 32-bit store, no offset
        // 0xB900_0348
        let insn: UInt32 = 0xB900_0348
        return ARM64.encodeU32(insn)
    }

    /// AND W8, W8, #imm (32-bit logical immediate).
    /// For mask 0xFFFFC0FF: encodes as NOT(0x3F00) = elements with inverted bits
    private func encodeAND_W8_W8_mask(_: UInt32) -> Data {
        // We encode directly using ARM64 logical immediate encoding.
        // For 0xFFFFC0FF: this is ~0x3F00 which represents "clear bits 8..13".
        // Logical imm: sf=0 (32-bit), N=0, immr=8, imms=5 for ~(0x3F<<8)
        // Actually use: AND W8, W8, #0xFFFFC0FF
        // N=0, immr=8, imms=5: encodes 6 replicated ones starting at bit 8 being 0
        // Encoding: 0_00100100_N_immr_imms_Rn_Rd
        // sf=0, opc=00, AND imm: 0001 0010 0 N immr imms Rn Rd
        // For mask 0xFFFFC0FF in 32-bit:
        //   bit pattern: 1111 1111 1111 1100 0000 0000 1111 1111
        //   inverted:    0000 0000 0000 0011 1111 1111 0000 0000 = 0x3F00
        //   This is a run of 8 ones (bits 8-15 are zero so inverted = ones)
        //   N=0, immr=8, imms=5 (count-1 of ones in the "element" minus 1)
        //   But we have 6 zeros in positions 8..13, not a clean power-of-2 element.
        //   Actually 0xFFFFC0FF has zeros at bits 8-13 (6 zeros), so mask has 6 zeros.
        //   For AND W8, W8, #0xFFFFC0FF:
        //   Use a pre-computed value from Python: asm("and w8, w8, #0xFFFFC0FF")
        //   Python result: 0x12126508 → bytes: 08 65 12 12
        let insn: UInt32 = 0x1212_6508
        return ARM64.encodeU32(insn)
    }

    /// ORR W8, W8, #0xC (CS_GET_TASK_ALLOW | CS_INSTALLER)
    private func encodeORR_W8_W8_imm(_: UInt32) -> Data {
        // ORR W8, W8, #0xC
        // 0xC = bit 2 and bit 3 set
        // Python result: asm("orr w8, w8, #0xC") → 0x321e0508
        let insn: UInt32 = 0x321E_0508
        return ARM64.encodeU32(insn)
    }
}
