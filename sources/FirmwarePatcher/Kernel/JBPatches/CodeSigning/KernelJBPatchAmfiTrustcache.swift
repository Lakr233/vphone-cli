// KernelJBPatchAmfiTrustcache.swift — JB kernel patch: AMFI trustcache gate bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (semantic function matching):
//   Scan amfi_text for functions (PACIBSP boundaries) that match the
//   AMFIIsCDHashInTrustCache body shape:
//     1. mov x19, x2   (save x2 into x19)
//     2. stp xzr, xzr, [sp, ...] (stack-zeroing pair)
//     3. mov x2, sp    (pass stack slot as out-param)
//     4. bl <lookup>
//     5. mov x20, x0   (save result)
//     6. cbnz w0, ...  (fast-path already-trusted check)
//     7. cbz x19, ...  (nil out-param guard)
//   Exactly one function must match. Rewrite its first 4 instructions with
//   the always-allow stub: mov x0,#1 / cbz x2,+8 / str x0,[x2] / ret.

import Foundation

extension KernelJBPatcher {
    /// AMFI trustcache gate bypass: rewrite AMFIIsCDHashInTrustCache to always return 1.
    @discardableResult
    func patchAmfiCdhashInTrustcache() -> Bool {
        log("\n[JB] AMFIIsCDHashInTrustCache: always allow + store flag")

        // Determine the AMFI text range. Fall back to full __TEXT_EXEC if no kext split.
        let amfiRange = amfiTextRange()
        let (amfiStart, amfiEnd) = amfiRange

        // Instruction encoding constants (used for structural matching).
        // Derived semantically — no hardcoded offsets, only instruction shape.
        let movX19X2: UInt32 = 0xAA02_03F3 // mov x19, x2  (ORR X19, XZR, X2)
        let movX2Sp: UInt32 = 0x9100_03E2 // mov x2, sp   (ADD X2, SP, #0)

        // Mask for STP XZR,XZR,[SP,#imm]: fixed bits excluding the immediate.
        // STP (pre-index / signed-offset) 64-bit XZR,XZR: 0xA900_7FFF base
        let stpXzrXzrMask: UInt32 = 0xFFC0_7FFF
        let stpXzrXzrVal: UInt32 = 0xA900_7FFF // any [sp, #imm_scaled]

        // CBZ/CBNZ masks
        let cbnzWMask: UInt32 = 0x7F00_0000
        let cbnzWVal: UInt32 = 0x3500_0000 // CBNZ 32-bit
        let cbzXMask: UInt32 = 0xFF00_0000
        let cbzXVal: UInt32 = 0xB400_0000 // CBZ 64-bit

        // BL mask
        let blMask: UInt32 = 0xFC00_0000
        let blVal: UInt32 = 0x9400_0000

        var hits: [Int] = []

        var off = amfiStart
        while off < amfiEnd - 4 {
            guard buffer.readU32(at: off) == ARM64.pacibspU32 else {
                off += 4
                continue
            }
            let funcStart = off

            // Determine function end: next PACIBSP or limit.
            var funcEnd = min(funcStart + 0x200, amfiEnd)
            var probe = funcStart + 4
            while probe < funcEnd {
                if buffer.readU32(at: probe) == ARM64.pacibspU32 {
                    funcEnd = probe
                    break
                }
                probe += 4
            }

            // Collect instructions in this function.
            var insns: [UInt32] = []
            var p = funcStart
            while p < funcEnd {
                insns.append(buffer.readU32(at: p))
                p += 4
            }

            // Structural shape check — mirrors Python _find_after sequence:
            //  i1: mov x19, x2
            //  i2: stp xzr, xzr, [sp, ...]
            //  i3: mov x2, sp
            //  i4: bl <anything>
            //  i5: mov x20, x0   (ORR X20, XZR, X0 = 0xAA0003F4)
            //  i6: cbnz w0, ...
            //  i7: cbz x19, ...
            let movX20X0: UInt32 = 0xAA00_03F4

            guard let i1 = insns.firstIndex(where: { $0 == movX19X2 }) else {
                off = funcEnd
                continue
            }
            guard let i2 = insns[(i1 + 1)...].firstIndex(where: { ($0 & stpXzrXzrMask) == stpXzrXzrVal }) else {
                off = funcEnd
                continue
            }
            guard let i3 = insns[(i2 + 1)...].firstIndex(where: { $0 == movX2Sp }) else {
                off = funcEnd
                continue
            }
            guard let i4 = insns[(i3 + 1)...].firstIndex(where: { ($0 & blMask) == blVal }) else {
                off = funcEnd
                continue
            }
            guard let i5 = insns[(i4 + 1)...].firstIndex(where: { $0 == movX20X0 }) else {
                off = funcEnd
                continue
            }
            guard insns[(i5 + 1)...].first(where: { ($0 & cbnzWMask) == cbnzWVal && ($0 & 0x1F) == 0 }) != nil else {
                off = funcEnd
                continue
            }
            guard insns[(i5 + 1)...].first(where: { ($0 & cbzXMask) == cbzXVal && ($0 & 0x1F) == 19 }) != nil else {
                off = funcEnd
                continue
            }

            hits.append(funcStart)
            off = funcEnd
        }

        guard hits.count == 1 else {
            log("  [-] expected 1 AMFI trustcache body hit, found \(hits.count)")
            return false
        }

        let funcStart = hits[0]
        let va0 = fileOffsetToVA(funcStart)
        let va1 = fileOffsetToVA(funcStart + 4)
        let va2 = fileOffsetToVA(funcStart + 8)
        let va3 = fileOffsetToVA(funcStart + 12)

        emit(
            funcStart,
            ARM64.movX0_1,
            patchID: "amfi_trustcache_1",
            virtualAddress: va0,
            description: "mov x0,#1 [AMFIIsCDHashInTrustCache]",
        )
        emit(
            funcStart + 4,
            ARM64.cbzX2_8,
            patchID: "amfi_trustcache_2",
            virtualAddress: va1,
            description: "cbz x2,+8 [AMFIIsCDHashInTrustCache]",
        )
        emit(
            funcStart + 8,
            ARM64.strX0X2,
            patchID: "amfi_trustcache_3",
            virtualAddress: va2,
            description: "str x0,[x2] [AMFIIsCDHashInTrustCache]",
        )
        emit(
            funcStart + 12,
            ARM64.ret,
            patchID: "amfi_trustcache_4",
            virtualAddress: va3,
            description: "ret [AMFIIsCDHashInTrustCache]",
        )
        return true
    }
}
