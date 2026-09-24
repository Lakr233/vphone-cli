// KernelJailbreakPatchIoucSandbox.swift — JB kernel patch: IOUC *sandbox* gate bypass.
//
// Sibling to patchIoucFailedMacf. The IOKit user-client open path runs TWO
// independent MAC gates: a MACF-aggregator check ("IOUC %s failed MACF in
// process %s", handled by patchIoucFailedMacf) and a Sandbox check ("IOUC %s
// failed sandbox in process %s"). Only the MACF one was patched.
//
// On iOS 27 userland atop the 26.4 vphone600 kernel, the Sandbox gate
// spuriously DENIES the render server (backboardd) its opens of
// IOMobileFramebufferUserClient / IOSurfaceRootUserClient / IOHIDEventService
// (confirmed via serial "IOUC IOMobileFramebufferUserClient failed sandbox in
// process pid <N>, backboardd" — ABSENT on a native 26.4 userland, which
// displays fine, and backboardd is absent from every IOUserClientCreator). With
// the render server denied the framebuffer there is no present (no Apple logo)
// and no vended main display (SpringBoard's FBSDisplayMonitor asserts on a nil
// mainDisplay → crash-loop).
//
// Real shape of the gate (offsets illustrative):
//     blraa  x8, x17            ; sandbox check (PAC-indirect, NOT a plain BL)
//     mov    w8, #0x2c7 ; movk w8,#0xe000,lsl#16   ; w8 = kIOReturnNotPermitted
//     str    w0, [sp,#X] ; cmp w0,w8 ; b.eq  <ALLOW>   ; NotPermitted → allow
//     ldr    w8, [sp,#X] ; cbnz w8, <DENY>            ; other error → deny
//     ...    (w0==0 path) ... b <ALLOW>
//   <DENY>: ...pac cleanup... ADRP "failed sandbox" ...log... return error
//   <ALLOW>: str wzr,[sp,#X]; ...; bl <proceed-to-open>
//
// Fix: rewrite the FIRST instruction of the deny block (<DENY>, the CBNZ
// target that encloses the fail-log ADRP) with an unconditional B to <ALLOW>
// (the B.EQ / NotPermitted allow-proceed target). This turns the denied open
// into an allowed one while leaving the w0==0 (already-allowed) path untouched.
// Anchor is structural (fail-log string → xref → the CBNZ whose target encloses
// it → the immediately-preceding B.EQ allow target); no hardcoded offsets.

import Foundation

extension KernelJailbreakPatcher {
    @discardableResult
    func patchIoucFailedSandbox() -> Bool {
        log("\n[JB] IOUC sandbox gate: deny-block → allow redirect")

        guard let failStrOff = buffer.findString("IOUC %s failed sandbox in process %s") else {
            log("  [-] IOUC failed-sandbox format string not found")
            return false
        }
        let refs = findStringRefs(failStrOff)
        guard !refs.isEmpty else {
            log("  [-] no xrefs for IOUC failed-sandbox format string")
            return false
        }

        for (adrpOff, _) in refs {
            guard let funcStart = findFunctionStart(adrpOff) else { continue }
            let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

            // Find the CBNZ Wn, <DENY> whose target encloses the fail-log ADRP.
            var off = funcStart
            while off < adrpOff {
                defer { off += 4 }
                let insn = buffer.readU32(at: off)
                guard isCbnzW(insn) else { continue }
                guard let denyEntry = cbTarget(insn, at: off) else { continue }
                // The fail-log ADRP must sit inside the deny block.
                guard denyEntry <= adrpOff, adrpOff < denyEntry + 0x60,
                      denyEntry > funcStart, denyEntry < funcEnd else { continue }

                // The allow target is the NotPermitted B.EQ, a couple insns before
                // the CBNZ (cmp ; b.eq <ALLOW> ; ldr ; cbnz). Search a small window.
                var allowTarget = -1
                for back in stride(from: off - 4, through: off - 0x14, by: -4) where back > funcStart {
                    let bi = buffer.readU32(at: back)
                    if let t = bCondEqTarget(bi, at: back), t > funcStart, t < funcEnd {
                        allowTarget = t
                        break
                    }
                }
                guard allowTarget >= 0 else { continue }

                guard let patchBytes = ARM64Encoder.encodeB(from: denyEntry, to: allowTarget) else { continue }
                let delta = allowTarget - denyEntry
                let va = fileOffsetToVA(denyEntry)
                log("  [+] IOUC sandbox gate fn=0x\(String(format: "%X", funcStart)), cbnz=0x\(String(format: "%X", off)), deny=0x\(String(format: "%X", denyEntry)) → allow=0x\(String(format: "%X", allowTarget))")
                emit(
                    denyEntry,
                    patchBytes,
                    patchID: "iouc_sandbox_gate",
                    virtualAddress: va,
                    description: "b #\(delta >= 0 ? "" : "-")0x\(String(format: "%X", abs(delta))) [IOUC sandbox deny → allow]",
                )
                return true
            }
        }

        log("  [-] narrow IOUC sandbox deny branch not found")
        return false
    }

    /// CBNZ Wt, <label> (32-bit): high byte 0x35.
    private func isCbnzW(_ insn: UInt32) -> Bool {
        ((insn >> 24) & 0xFF) == 0x35
    }

    /// Decode CBZ/CBNZ target (imm19, sign-extended, scaled by 4).
    private func cbTarget(_ insn: UInt32, at pc: Int) -> Int? {
        let imm19 = (insn >> 5) & 0x7FFFF
        return pc + Int(Int32(bitPattern: imm19 << 13) >> 13) * 4
    }

    /// If `insn` is B.EQ <label>, return its target; else nil.
    /// B.cond: [31:24]=0x54, [4]=0, cond=[3:0]; EQ cond = 0.
    private func bCondEqTarget(_ insn: UInt32, at pc: Int) -> Int? {
        guard (insn & 0xFF00_0010) == 0x5400_0000, (insn & 0xF) == 0x0 else { return nil }
        let imm19 = (insn >> 5) & 0x7FFFF
        return pc + Int(Int32(bitPattern: imm19 << 13) >> 13) * 4
    }
}
