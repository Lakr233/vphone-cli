// KernelJBPatchSecureRoot.swift — JB: force the SecureRootName policy to return success.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal (version-independent):
//   IOSecureBSDRoot() asks the platform expert to evaluate "SecureRootName"; on
//   kIOReturnNotPrivileged it tears the root device down via mdevremoveall()
//   (iokit/bsddev/IOKitBSDInit.cpp + bsd/dev/memdev.c). The decision is made in
//   AppleARMPE::callPlatformFunction — the single function that references BOTH the
//   "SecureRoot" and "SecureRootName" strings. Its deny/allow return is a unique
//   CSEL of the form `csel Wd, wzr, Wn, <cond>` where Wn is built as
//   kIOReturnNotPrivileged (0xE00002C1). kIOReturn codes carry the IOKit error
//   system in their high half, so Wn is recognised by its `movk Wn, #0xE000, lsl#16`
//   — a stable ABI signature, not a pinned field offset or struct layout.
//   Patch: rewrite that CSEL to `mov Wd, #0` so the policy always returns success.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Force SecureRootName policy return to success in AppleARMPE::callPlatformFunction.
    @discardableResult
    func patchIoSecureBsdRoot() -> Bool {
        log("\n[JB] _IOSecureBSDRoot: force SecureRootName success")

        let candidates = findSecureRootFunctions()
        guard !candidates.isEmpty else {
            log("  [-] secure-root dispatch function not found")
            return false
        }

        // Collect the deny-return CSEL across every candidate function and require a
        // single global match — never patch the first-of-several.
        var sites: [(Int, String)] = []
        for funcStart in candidates.sorted() {
            let funcEnd = findFuncEnd(funcStart, maxSize: 0x1200)
            if let site = findSecureRootReturnSite(funcStart: funcStart, funcEnd: funcEnd) {
                sites.append(site)
            }
        }

        guard sites.count == 1 else {
            log("  [-] SecureRootName deny-return site not uniquely found (\(sites.count) candidates)")
            return false
        }

        let (off, destReg) = sites[0]
        guard destReg.hasPrefix("w"), let rd = UInt32(destReg.dropFirst()),
              let patchBytes = ARM64Encoder.encodeMovzW(rd: rd, imm16: 0)
        else {
            log("  [-] could not encode mov \(destReg), #0")
            return false
        }
        emit(off, patchBytes,
             patchID: "jb.io_secure_bsd_root.zero_return",
             virtualAddress: fileOffsetToVA(off),
             description: "mov \(destReg), #0 [_IOSecureBSDRoot SecureRootName allow]")
        return true
    }

    // MARK: - Private helpers

    /// Find all functions that reference both "SecureRootName" and "SecureRoot".
    private func findSecureRootFunctions() -> Set<Int> {
        let withName = functionsReferencingString("SecureRootName")
        let withRoot = functionsReferencingString("SecureRoot")
        let common = withName.intersection(withRoot)
        return common.isEmpty ? withName : common
    }

    /// Find all function starts that reference `needle` via ADRP+ADD.
    private func functionsReferencingString(_ needle: String) -> Set<Int> {
        var result = Set<Int>()
        // Scan all occurrences of the needle in the buffer.
        guard let encoded = needle.data(using: .utf8) else { return result }
        var searchFrom = 0
        while searchFrom < buffer.count {
            guard let range = buffer.data.range(of: encoded, in: searchFrom ..< buffer.count) else { break }
            let pos = range.lowerBound
            // Find null-terminated C string boundary.
            var cstrStart = pos
            while cstrStart > 0, buffer.data[cstrStart - 1] != 0 {
                cstrStart -= 1
            }
            var cstrEnd = pos
            while cstrEnd < buffer.count, buffer.data[cstrEnd] != 0 {
                cstrEnd += 1
            }
            // Only accept if the C string equals the needle exactly.
            if buffer.data[cstrStart ..< cstrEnd] == encoded {
                let refs = findStringRefs(cstrStart)
                for (adrpOff, _) in refs {
                    if let fn = findFunctionStart(adrpOff) {
                        result.insert(fn)
                    }
                }
            }
            searchFrom = pos + 1
        }
        return result
    }

    /// Scan [funcStart, funcEnd) for the unique CSEL that selects between success
    /// (wzr) and kIOReturnNotPrivileged — the SecureRootName deny/allow selector.
    /// Returns (offset, destRegName) on success.
    private func findSecureRootReturnSite(funcStart: Int, funcEnd: Int) -> (Int, String)? {
        var hits: [(Int, String)] = []
        for off in stride(from: funcStart, to: funcEnd - 4, by: 4) {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first, insn.mnemonic == "csel" else { continue }
            guard let detail = insn.aarch64, detail.operands.count >= 3 else { continue }

            let destOp = detail.operands[0]
            let zeroSrcOp = detail.operands[1]
            let errSrcOp = detail.operands[2]
            guard destOp.type == AARCH64_OP_REG,
                  zeroSrcOp.type == AARCH64_OP_REG,
                  errSrcOp.type == AARCH64_OP_REG else { continue }

            let destName = disasm.registerName(UInt32(destOp.reg.rawValue)) ?? ""
            let zeroName = disasm.registerName(UInt32(zeroSrcOp.reg.rawValue)) ?? ""
            let errName = disasm.registerName(UInt32(errSrcOp.reg.rawValue)) ?? ""

            // Allow value must be 0 (wzr); deny value is the error register.
            guard destName.hasPrefix("w") else { continue }
            guard zeroName == "wzr" || zeroName == "xzr" else { continue }

            // Confirm the deny value is a kIOReturn code: its register is built with
            // the IOKit error-system high half (movk Wn, #0xE000, lsl #16).
            guard hasIOKitErrorBuild(before: off, funcStart: funcStart, regName: errName) else { continue }

            hits.append((off, destName))
        }

        return hits.count == 1 ? hits[0] : nil
    }

    /// Walk backward from `off` looking for `movk <regName>, #0xE000, lsl #16` — the
    /// high half of an IOKit return code (kIOReturn* == 0xE000xxxx).
    private func hasIOKitErrorBuild(before off: Int, funcStart: Int, regName: String) -> Bool {
        let lookbackStart = max(funcStart, off - 0x40)
        var probe = off - 4
        while probe >= lookbackStart {
            defer { probe -= 4 }
            let insns = disasm.disassemble(in: buffer.data, at: probe, count: 1)
            guard let ins = insns.first, ins.mnemonic == "movk" else { continue }
            guard disasm.writesRegister(ins, named: regName) else { continue }
            let ops = ins.operandString.replacingOccurrences(of: " ", with: "").lowercased()
            // movk Wn, #0xe000, lsl #16  → "wN,#0xe000,lsl#16"
            if ops.contains("#0xe000,lsl#16") { return true }
        }
        return false
    }

}
