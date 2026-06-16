// KernelJBPatchProcPidinfo.swift — JB: NOP the two early pid-0 guards in proc_pidinfo.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal (version-independent, self-contained):
//   proc_pidinfo is inlined into _proc_info_internal on current kernels. The pid==0
//   region-flavor permission guards sit immediately ahead of the proc_pidinfo
//   `flavor` switch and form a globally-unique shape in __TEXT_EXEC:
//       ldr  Xd, [Xn, #imm]    ; load proc field
//       cbz  Xd, deny          ; guard A   (patched -> nop)
//       bl   <helper>
//       cbz/cbnz wN, deny      ; guard B   (patched -> nop)
//       movz w0, #0x16         ; EINVAL default (anchors the proc_pidinfo switch)
//       sub  wM, wK, #1        ; flavor switch zero-base
//   The `mov w0,#0x16(EINVAL) ; sub _,_,#1` trailer makes the shape unique, so we
//   scan kernel text directly rather than resolving the giant inlined function
//   (its prologue is not recoverable by a single backward PACIBSP walk). NOPing the
//   two guards lets kernel-task / restricted-pid flavors fall through to the switch.

import Foundation

extension KernelJBPatcher {
    /// Bypass the two early pid-0 guards in the inlined proc_pidinfo path.
    @discardableResult
    func patchProcPidinfo() -> Bool {
        log("\n[JB] _proc_pidinfo: NOP pid-0 guard (2 sites)")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] kernel __TEXT_EXEC range not found")
            return false
        }

        var matches: [Int] = [] // file offset of i0 (the `ldr` opening the guard)
        var off = ks
        while off + 24 <= ke {
            defer { off += 4 }

            // Cheap distinctive prefilter: i4 == `movz w0, #0x16` (EINVAL default).
            let i4 = buffer.readU32(at: off + 16)
            guard ARM64Inst.isMOVZW(i4), ARM64Inst.rd(i4) == 0, ARM64Inst.movImm16(i4) == 0x16 else { continue }

            // i0: ldr Xd, [Xn, #imm]  (64-bit unsigned-offset load; reg/imm unpinned)
            let i0 = buffer.readU32(at: off)
            guard ARM64Inst.isLDRImm64(i0) else { continue }
            let ldrRt = ARM64Inst.rd(i0)

            // i1: cbz Xd, deny  (guard A — same register the load wrote)
            let i1 = buffer.readU32(at: off + 4)
            guard ARM64Inst.isCBZX(i1), ARM64Inst.rd(i1) == ldrRt else { continue }

            // i2: bl <helper>
            let i2 = buffer.readU32(at: off + 8)
            guard ARM64Inst.isBL(i2) else { continue }

            // i3: cbz/cbnz wN, deny  (guard B, 32-bit register)
            let i3 = buffer.readU32(at: off + 12)
            guard ARM64Inst.isCBZorCBNZW(i3) else { continue }

            // i5: sub wM, wK, #1  (the flavor-switch zero-base right after EINVAL)
            let i5 = buffer.readU32(at: off + 20)
            guard ARM64Inst.isSUBImm32(i5), ARM64Inst.addSubImm12(i5) == 1 else { continue }

            matches.append(off)
        }

        guard matches.count == 1 else {
            log("  [-] precise proc_pidinfo guard pair not found (\(matches.count) candidates)")
            return false
        }

        let guardA = matches[0] + 4 // cbz Xd
        let guardB = matches[0] + 12 // cbz/cbnz wN
        emit(guardA, ARM64.nop,
             patchID: "jb.proc_pidinfo.nop_guard_a",
             virtualAddress: fileOffsetToVA(guardA),
             description: "NOP [_proc_pidinfo pid-0 guard A]")
        emit(guardB, ARM64.nop,
             patchID: "jb.proc_pidinfo.nop_guard_b",
             virtualAddress: fileOffsetToVA(guardB),
             description: "NOP [_proc_pidinfo pid-0 guard B]")
        return true
    }
}
