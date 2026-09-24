// KernelJBPatchIomfbSwap.swift — JB kernel patch: make the IOMobileFramebuffer
// SwapEnd userclient accept the caller's native swap-struct size.
//
// Background: iOS 27's `_kern_SwapEnd` sends a 0x6e0-byte IOMFBSwapRec, but the
// 26.4 kernel's IOMobileFramebufferUserClient external-method-5 dispatch does an
// EXACT `checkStructureInputSize == 0x588` check → 27's call is rejected
// (kIOReturnBadArgument), no frame presented. The userland size patch (truncate
// 0x6e0 -> 0x588) makes the check pass but feeds the 26.4 handler a truncated /
// misaligned struct (iOS 27's layout ≠ 26.4's) → still no valid frame.
//
// This patch flips that dispatch entry's `checkStructureInputSize` to
// kIOUCVariableStructureSize (0xffffffff) so the kernel accepts the caller's
// native size and passes the full, correctly-laid-out struct to the handler.
// Combined with LEAVING iOS 27's userland at its native 0x6e0 (no truncation),
// the handler then reads its fields from an authentic iOS-27 IOMFBSwapRec — which
// works iff iOS 27's layout is a superset of what the 26.4 handler reads.
//
// Anchor (structural, no hardcoded offsets): the sole IOExternalMethodDispatch
// entry whose shape matches the SwapEnd selector — an 8-byte ptrauth-signed code
// pointer followed by checkScalarInputCount==0, checkStructureInputSize==0x588,
// checkScalarOutputCount==0, checkStructureOutputSize==0. Verified unique in the
// vphone600 26.4 kernelcache. Scanned in __DATA_CONST (where the dispatch table
// lives), 8-byte aligned.
//
// NOTE: only meaningful for an iOS-27 build; on a 26.x userland the native size
// is 0x588 anyway. Variable-size is safe for callers that send >= the fields the
// handler reads (26.5=0x588, 27=0x6e0 both do).

import Foundation

extension KernelJBPatcher {
    private static let swapEndExpectedSize: UInt32 = 0x588 // 26.4 kernel's native SwapEnd struct size
    private static let swapEndIOS27Size: UInt32 = 0x6E0 // iOS 27's native IOMFBSwapRec size
    private static let kIOUCVariableStructureSize: UInt32 = 0xFFFF_FFFF

    /// The swap_submit handler has a SECOND, internal exact-size gate beyond the
    /// dispatch table's checkStructureInputSize:
    ///     cmp w2, #0x588 ; b.ne <error>   (w2 = structureInputSize)
    /// With iOS 27 sending 0x6e0 this branches to the error path (kIOReturnBadArgument,
    /// swap aborted) even after the dispatch check is relaxed — so no frame is ever
    /// presented (no Apple logo, no UI). Retarget the compare to iOS 27's size so the
    /// handler takes the success path and processes the native struct. Anchor is the
    /// unique `cmp w2, #0x588` immediately followed by `b.ne` (semantic; the 0x588 is
    /// the SwapEnd struct size the handler gates on — the value being changed). Only
    /// the imm12 field is rewritten, preserving the rest of the instruction.
    @discardableResult
    func patchIomfbSwapEndHandlerSize() -> Bool {
        log("\n[JB] IOMFB swap_submit handler size gate cmp w2,#0x588 -> #0x6e0 (accept iOS 27 native struct)")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] no kernel text range")
            return false
        }

        // cmp w2,#imm == SUBS wzr,w2,#imm : 0x71000000 | imm12<<10 | Rn(2)<<5 | Rd(31)
        let cmpW2Old: UInt32 = 0x7100_0000 | (Self.swapEndExpectedSize << 10) | (2 << 5) | 31

        var hits: [Int] = []
        var off = ks
        while off + 8 <= ke {
            if buffer.readU32(at: off) == cmpW2Old {
                // Confirm the following instruction is a conditional b.ne (the gate).
                if let nxt = disasAt(off + 4), nxt.mnemonic == "b.ne" {
                    hits.append(off)
                }
            }
            off += 4
        }

        guard hits.count == 1 else {
            log("  [-] swap_submit handler size gate (cmp w2,#0x588 -> b.ne) not found uniquely (found \(hits.count))")
            return false
        }

        let cmpOff = hits[0]
        // Rewrite only the imm12 field [21:10] to the iOS 27 size.
        var word = buffer.readU32(at: cmpOff)
        word = (word & ~(UInt32(0xFFF) << 10)) | (Self.swapEndIOS27Size << 10)
        var le = word.littleEndian
        var newBytes = Data(count: 4)
        withUnsafeBytes(of: &le) { newBytes.replaceSubrange(0 ..< 4, with: $0) }

        let va = fileOffsetToVA(cmpOff)
        emit(
            cmpOff,
            newBytes,
            patchID: "iomfb_swapend_handler_size",
            virtualAddress: va,
            description: "swap_submit cmp w2,#0x588 -> #0x6e0 [accept iOS 27 native SwapEnd struct]",
        )
        return true
    }

    @discardableResult
    func patchIomfbSwapEndVariableSize() -> Bool {
        log("\n[JB] IOMFB SwapEnd dispatch checkStructureInputSize -> variable (accept iOS 27 native struct)")

        guard let seg = segments.first(where: { $0.name == "__DATA_CONST" }), seg.fileSize > 0 else {
            log("  [-] no __DATA_CONST segment")
            return false
        }
        let start = Int(seg.fileOffset)
        let end = start + Int(seg.fileSize)

        var hits: [Int] = []
        var off = start
        while off + 24 <= end {
            // entry: ptr(8) scalarIn(4) structIn(4) scalarOut(4) structOut(4)
            let structIn = buffer.readU32(at: off + 12)
            if structIn == Self.swapEndExpectedSize {
                let scalarIn = buffer.readU32(at: off + 8)
                let scalarOut = buffer.readU32(at: off + 16)
                let structOut = buffer.readU32(at: off + 20)
                let ptrHi = buffer.readU32(at: off + 4) // top word of the 8-byte fn ptr
                let topByte = ptrHi >> 24
                if scalarIn == 0, scalarOut == 0, structOut == 0, topByte >= 0x80 {
                    hits.append(off)
                }
            }
            off += 8 // pointer-aligned dispatch entries
        }

        guard hits.count == 1 else {
            log("  [-] SwapEnd dispatch entry not found uniquely (found \(hits.count))")
            return false
        }

        let entryOff = hits[0]
        let sizeFieldOff = entryOff + 12
        var newBytes = Data(count: 4)
        var v = Self.kIOUCVariableStructureSize.littleEndian
        withUnsafeBytes(of: &v) { newBytes.replaceSubrange(0 ..< 4, with: $0) }

        let va = fileOffsetToVA(sizeFieldOff)
        emit(
            sizeFieldOff,
            newBytes,
            patchID: "iomfb_swapend_variable_size",
            virtualAddress: va,
            description: "SwapEnd checkStructureInputSize 0x588 -> variable [accept iOS 27 native IOMFBSwapRec]",
        )
        return true
    }
}
