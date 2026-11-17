// KernelCustomFirmwarePatchAmfiTrustcache.swift — CFW kernel patch: AMFI trustcache gate bypass
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
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    /// AMFI trustcache gate bypass: rewrite AMFIIsCDHashInTrustCache to always return 1.
    @discardableResult
    func patchAmfiCdhashInTrustcache() -> Bool {
        log("\n[CFW]AMFIIsCDHashInTrustCache: always allow + store flag")

        // Determine the AMFI text range. Fall back to full __TEXT_EXEC if no kext split.
        let amfiRange = amfiTextRange()
        let (amfiStart, amfiEnd) = amfiRange

        // The out-param register. 26.x kernels pass the found-flag pointer in x2;
        // iOS 27's trust-cache query took another argument, so AMFI's wrapper saves
        // and passes x3 instead. Everything else about the body is unchanged, so the
        // register is the only thing to discover — and it is also what the stub has
        // to store through, which is why it is carried to the emit below.
        let outParamCandidates: [UInt32] = [2, 3]

        /// `mov x19, xN` (ORR X19, XZR, XN) and `mov xN, sp` (ADD XN, SP, #0), from
        /// the keystone-backed encoders rather than literals.
        func word(_ data: Data) -> UInt32 {
            data.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        func shapeWords(outParam: UInt32) -> (movX19XN: UInt32, movXNSp: UInt32)? {
            guard let add = ARM64Encoder.encodeAddImm12(rd: outParam, rn: 31, imm12: 0) else { return nil }
            return (word(ARM64Encoder.encodeMovX(rd: 19, rm: outParam)), word(add))
        }

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

        var hits: [(funcStart: Int, outParam: UInt32)] = []

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
            //  i1: mov x19, xN   (N is the out-param register: 2 on 26.x, 3 on 27)
            //  i2: stp xzr, xzr, [sp, ...]
            //  i3: mov xN, sp
            //  i4: bl <anything>
            //  i5: mov x20, x0   (ORR X20, XZR, X0 = 0xAA0003F4)
            //  i6: cbnz w0, ...
            //  i7: cbz x19, ...
            let movX20X0: UInt32 = 0xAA00_03F4

            for outParam in outParamCandidates {
                guard let shape = shapeWords(outParam: outParam) else { continue }
                guard let i1 = insns.firstIndex(where: { $0 == shape.movX19XN }) else { continue }
                guard let i2 = insns[(i1 + 1)...].firstIndex(where: { ($0 & stpXzrXzrMask) == stpXzrXzrVal }) else { continue }
                guard let i3 = insns[(i2 + 1)...].firstIndex(where: { $0 == shape.movXNSp }) else { continue }
                guard let i4 = insns[(i3 + 1)...].firstIndex(where: { ($0 & blMask) == blVal }) else { continue }
                guard let i5 = insns[(i4 + 1)...].firstIndex(where: { $0 == movX20X0 }) else { continue }
                guard insns[(i5 + 1)...].first(where: { ($0 & cbnzWMask) == cbnzWVal && ($0 & 0x1F) == 0 }) != nil else { continue }
                guard insns[(i5 + 1)...].first(where: { ($0 & cbzXMask) == cbzXVal && ($0 & 0x1F) == 19 }) != nil else { continue }
                hits.append((funcStart, outParam))
                break
            }
            off = funcEnd
        }

        guard hits.count == 1 else {
            log("  [-] expected 1 AMFI trustcache body hit, found \(hits.count)")
            return false
        }

        let (funcStart, outParam) = hits[0]

        // The out-param is a 16-byte record the real body fills from the query's
        // own result, not a boolean. Storing the return value into it is only safe
        // where it has always been done — the 26.x layout, where x2 carries it and
        // the frozen words below are the measured ones. iOS 27's AMFI reads a hash
        // type out of that record and rejects `CS_HASHTYPE_SHA1`, so a stored 1
        // turns "in the trust cache" into "signed with SHA-1" and every adhoc
        // system binary is refused — `/sbin/launchd` included, which panics the
        // guest at init. On that layout the stub answers the question it was asked
        // and leaves the record to the caller.
        guard outParam == 2 else {
            emit(
                funcStart,
                ARM64.movX0_1,
                patchID: "kernel-boot-amfi_trustcache.1",
                virtualAddress: fileOffsetToVA(funcStart),
                description: "mov x0,#1 [AMFIIsCDHashInTrustCache]",
            )
            emit(
                funcStart + 4,
                ARM64.ret,
                patchID: "kernel-boot-amfi_trustcache.4",
                virtualAddress: fileOffsetToVA(funcStart + 4),
                description: "ret [AMFIIsCDHashInTrustCache]",
            )
            return true
        }

        emit(
            funcStart,
            ARM64.movX0_1,
            patchID: "kernel-boot-amfi_trustcache.1",
            virtualAddress: fileOffsetToVA(funcStart),
            description: "mov x0,#1 [AMFIIsCDHashInTrustCache]",
        )
        emit(
            funcStart + 4,
            ARM64.cbzX2_8,
            patchID: "kernel-boot-amfi_trustcache.2",
            virtualAddress: fileOffsetToVA(funcStart + 4),
            description: "cbz x2,+8 [AMFIIsCDHashInTrustCache]",
        )
        emit(
            funcStart + 8,
            ARM64.strX0X2,
            patchID: "kernel-boot-amfi_trustcache.3",
            virtualAddress: fileOffsetToVA(funcStart + 8),
            description: "str x0,[x2] [AMFIIsCDHashInTrustCache]",
        )
        emit(
            funcStart + 12,
            ARM64.ret,
            patchID: "kernel-boot-amfi_trustcache.4",
            virtualAddress: fileOffsetToVA(funcStart + 12),
            description: "ret [AMFIIsCDHashInTrustCache]",
        )
        return true
    }
}
