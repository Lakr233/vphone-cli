// KernelJBPatchDiskImages2.swift — JB kernel patch: DiskImages2 ABI acceptance.
//
// Productionizes the known-good DiskImages2 pokes that make the 26.4 vphone600
// kernel accept the iOS-27 userland's DiskImages2 client (kernel driver ABI v9 vs
// daemon/controller ABI v11) and fix a RegisterNotificationPort off-by-one. Without
// these the iOS-27 personalized DDI never attaches (kernel:
// "DIDeviceCreatorUserClient::CreateDevice: Incompatible client: expected ABI
// version 9 actual 11"), so `pymobiledevice3 mounter auto-mount` fails at attach.
//
// Pairs with the sandbox mac_policy_ops[124] allow (KernelJBPatchSandboxExtended)
// and the diskimagesiod isMountComplete→YES userland patch (cfw_install) that
// together let the attached DDI actually mount at /System/Developer.
//
// All sites are in the com.apple.driver.AppleDiskImages2 kext inside the MH_FILESET
// kernelcache. The existing JB patches scan the whole kernel text, which covers the
// kext; every anchor here is a globally-unique C++ signature / AssertMacros cstring,
// or a shape made unique by first pinning the enclosing function — so no DI2-range
// restriction is required.
//
// Layers:
//  - GATE1/GATE2b (ABI reject NOP): version-robust — anchored on the C++ signature
//    cstring + a unique `cmp #9 ; b.ne`. No-op-in-effect on version-matched userlands
//    (ABI 9 == 9, so the b.ne isn't taken anyway).
//  - GATE2 (notification-ports array + bound-check widen): the off-by-one is specific
//    to the 26.4-kernel / iOS-27-userland hybrid, and its instruction shapes vary by
//    kernel build. Applied ALL-OR-NOTHING (widening the bound checks without also
//    widening the backing array would let RegisterNotificationPort write past the
//    array); on builds whose codegen doesn't present all three sites the whole gate
//    is skipped (logged) — the ABI gates above remain the essential attach fix.
//
// Guardrails: no hardcoded offsets/VAs/bytes in patch logic — matching is from
// Capstone decode, replacement bytes from the Keystone-backed ARM64/ARM64Encoder
// helpers.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Apply all DiskImages2 ABI pokes. Wired into KernelJBPatcher.findAll().
    @discardableResult
    func patchDiskImages2ClientAbi() -> Bool {
        var ok = true
        ok = patchDiskImages2CreateDeviceAbi() && ok
        ok = patchDiskImages2ConnectAbi() && ok
        ok = patchDiskImages2NotificationPortArray() && ok
        return ok
    }

    // MARK: - GATE 1 / GATE 2b: ABI-version reject b.ne → NOP

    /// `DIDeviceCreatorUserClient::CreateDevice` rejects a client whose controller ABI
    /// (`cmp wN,#9 ; b.ne <reject>`) != 9. NOP the b.ne so the ABI-11 iOS-27 client is
    /// accepted. Function pinned by its unique C++ signature cstring.
    @discardableResult
    func patchDiskImages2CreateDeviceAbi() -> Bool {
        log("\n[JB] DiskImages2 GATE1: CreateDevice controller-ABI b.ne -> nop")
        return nopAbiVersionGate(
            funcSig: "static IOReturn DIDeviceCreatorUserClient::CreateDevice(OSObject *, void *, IOExternalMethodArguments *)",
            patchID: "di2_createdevice_abi",
            desc: "nop [DI2 CreateDevice controller-ABI cmp#9/b.ne gate]"
        )
    }

    /// `DIDeviceIOUserClient::Connect` rejects a client whose daemon ABI
    /// (`cmp wN,#9 ; b.ne <reject>`) != 9. NOP the b.ne. Same shape, different function.
    @discardableResult
    func patchDiskImages2ConnectAbi() -> Bool {
        log("\n[JB] DiskImages2 GATE2b: Connect daemon-ABI b.ne -> nop")
        return nopAbiVersionGate(
            funcSig: "static IOReturn DIDeviceIOUserClient::Connect(OSObject *, void *, IOExternalMethodArguments *)",
            patchID: "di2_connect_abi",
            desc: "nop [DI2 Connect daemon-ABI cmp#9/b.ne gate]"
        )
    }

    /// Pin the function via its unique signature cstring, then NOP the unique
    /// `cmp wN,#9 ; b.ne` inside it.
    private func nopAbiVersionGate(funcSig: String, patchID: String, desc: String) -> Bool {
        guard let sigOff = buffer.findString(funcSig) else {
            log("  [-] signature string not found: \(funcSig.prefix(48))…")
            return false
        }
        let refs = findStringRefs(sigOff)
        guard let ref = refs.first, let funcStart = findFunctionStart(ref.adrpOff) else {
            log("  [-] no xref/function for signature string")
            return false
        }
        let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

        // CMP Wn,#9 (== SUBS WZR,Wn,#9) immediately followed by B.NE.
        var hits: [Int] = []
        var off = funcStart
        while off + 8 <= funcEnd {
            defer { off += 4 }
            guard let cmp = disasAt(off), cmp.mnemonic == "cmp",
                  let ops = cmp.aarch64?.operands, ops.count == 2,
                  ops[0].type == AARCH64_OP_REG,
                  (disasm.firstRegisterName(cmp)?.hasPrefix("w") ?? false),
                  ops[1].type == AARCH64_OP_IMM, ops[1].imm == 9
            else { continue }
            guard let nxt = disasAt(off + 4), nxt.mnemonic == "b.ne" else { continue }
            hits.append(off + 4) // the b.ne
        }

        guard hits.count == 1 else {
            log("  [-] expected 1 cmp#9/b.ne gate, found \(hits.count)")
            return false
        }
        let bneOff = hits[0]
        emit(bneOff, ARM64.nop, patchID: patchID, virtualAddress: fileOffsetToVA(bneOff), description: desc)
        return true
    }

    // MARK: - GATE 2 (a/b/c): notification-ports array + bound checks widen

    /// Widen the notification-ports array allocation AND both bound-check fields to
    /// 0x800 entries, fixing the RegisterNotificationPort off-by-one (userland
    /// registers at index == maxPorts, one past the array).
    ///
    /// ALL-OR-NOTHING: widening the bound checks (type < 0x800) without also widening
    /// the backing array would let RegisterNotificationPort write past the array
    /// (memory corruption). So all three sites are located first and patched only if
    /// all are present. On kernel builds whose notif-port codegen differs (the
    /// off-by-one is specific to the 26.4-kernel / iOS-27-userland hybrid), the whole
    /// gate is skipped — the version-robust ABI gates (GATE1/GATE2b) are the essential
    /// attach fix.
    @discardableResult
    func patchDiskImages2NotificationPortArray() -> Bool {
        log("\n[JB] DiskImages2 GATE2: widen notification-ports array + bound checks")

        guard let allocSite = findDI2AllocPortsSizeSite() else {
            log("  [~] AllocPortsArray size-shift not present on this kernel — skipping GATE2 (build-specific notif-port codegen; GATE1/GATE2b are the essential fix)")
            return true
        }
        guard let (rnpStart, rnpEnd) = findDI2RegisterNotifFunc(),
              let f1 = findUniqueFieldLoad(funcStart: rnpStart, funcEnd: rnpEnd, mnemonic: "ldrh", disp: 0xD8, requireWDest: false),
              let f2 = findUniqueFieldLoad(funcStart: rnpStart, funcEnd: rnpEnd, mnemonic: "ldr", disp: 0xE8, requireWDest: true)
        else {
            log("  [~] notification-port bound-check loads not both present — skipping GATE2 (all-or-nothing)")
            return true
        }

        // All three located — apply together.
        var ok = applyDI2AllocPortsSize(at: allocSite)
        ok = applyFieldLoadMov800(at: f1, patchID: "di2_notif_boundcheck_d8",
                 desc: "mov wD,#0x800 [DI2 RegisterNotificationPort bound-check field1 @+0xd8]") && ok
        ok = applyFieldLoadMov800(at: f2, patchID: "di2_notif_boundcheck_e8",
                 desc: "mov wD,#0x800 [DI2 RegisterNotificationPort bound-check field2 @+0xe8]") && ok
        return ok
    }

    /// Locate the AllocPortsArray allocator size arg `lsl x1, xN, #3` (count << 3 ==
    /// count * 8), unique within the function. Function pinned by its C++ signature.
    private func findDI2AllocPortsSizeSite() -> Int? {
        guard let sigOff = buffer.findString(
            "static IOReturn DIDeviceIOUserClient::AllocPortsArray(OSObject *, void *, IOExternalMethodArguments *)"
        ) else { return nil }
        let refs = findStringRefs(sigOff)
        guard let ref = refs.first, let funcStart = findFunctionStart(ref.adrpOff) else { return nil }
        let funcEnd = findFuncEnd(funcStart, maxSize: 0x1000)

        // The allocator size arg `lsl x1, xN, #3` (count << 3 == count * 8). Capstone on
        // this toolchain decodes the lsl-immediate (a UBFM alias) as 2 operands (not the
        // xd,xn,#imm 3-operand shape), so match on mnemonic + destination x1 — the only
        // lsl that writes the size register, unique within AllocPortsArray. Replacement is
        // a fixed `mov x1,#0x4000`, so the original shift amount is irrelevant.
        var hits: [Int] = []
        var off = funcStart
        while off + 4 <= funcEnd {
            defer { off += 4 }
            guard let lsl = disasAt(off), lsl.mnemonic == "lsl",
                  disasm.firstRegisterName(lsl) == "x1"
            else { continue }
            hits.append(off)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Pin the RegisterNotificationPort function via its unique AssertMacros cstring.
    private func findDI2RegisterNotifFunc() -> (Int, Int)? {
        guard let sOff = buffer.findString("!notification_ports[ type ]") else { return nil }
        let refs = findStringRefs(sOff)
        guard let ref = refs.first, let funcStart = findFunctionStart(ref.adrpOff) else { return nil }
        return (funcStart, findFuncEnd(funcStart, maxSize: 0x400))
    }

    /// Locate a unique `<mnemonic> wD,[xB,#disp]` field load in [funcStart,funcEnd).
    private func findUniqueFieldLoad(funcStart: Int, funcEnd: Int, mnemonic: String, disp: Int64, requireWDest: Bool) -> Int? {
        var hits: [Int] = []
        var off = funcStart
        while off + 4 <= funcEnd {
            defer { off += 4 }
            guard let ins = disasAt(off), ins.mnemonic == mnemonic,
                  let ops = ins.aarch64?.operands, ops.count == 2,
                  ops[0].type == AARCH64_OP_REG,
                  ops[1].type == AARCH64_OP_MEM, ops[1].mem.disp == disp
            else { continue }
            if requireWDest, !(disasm.firstRegisterName(ins)?.hasPrefix("w") ?? false) { continue }
            hits.append(off)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Rewrite the AllocPortsArray size shift to `mov x1,#0x4000` (0x800 entries * 8).
    private func applyDI2AllocPortsSize(at lslOff: Int) -> Bool {
        guard let name = disasm.firstRegisterName(disasAt(lslOff)!),
              let dst = xRegIndex(name),
              let bytes = ARM64Encoder.encodeMovzX(rd: dst, imm16: 0x4000, shift: 0)
        else { log("  [-] could not encode mov x1,#0x4000"); return false }
        emit(lslOff, bytes,
             patchID: "di2_allocports_size",
             virtualAddress: fileOffsetToVA(lslOff),
             description: "mov x1,#0x4000 [DI2 AllocPortsArray widen notif-ports alloc to 0x800 entries]")
        return true
    }

    /// Rewrite a bound-check field load to `mov wD,#0x800`, deriving wD from the decode.
    private func applyFieldLoadMov800(at ldOff: Int, patchID: String, desc: String) -> Bool {
        guard let name = disasm.firstRegisterName(disasAt(ldOff)!),
              let dst = wRegIndex(name),
              let bytes = ARM64Encoder.encodeMovzW(rd: dst, imm16: 0x800, shift: 0)
        else { log("  [-] could not encode mov wD,#0x800"); return false }
        emit(ldOff, bytes, patchID: patchID, virtualAddress: fileOffsetToVA(ldOff), description: desc)
        return true
    }

    // MARK: - Register-name → index helpers

    private func wRegIndex(_ name: String) -> UInt32? {
        if name == "wzr" { return 31 }
        guard name.hasPrefix("w"), let n = UInt32(name.dropFirst()), n < 31 else { return nil }
        return n
    }

    private func xRegIndex(_ name: String) -> UInt32? {
        if name == "xzr" { return 31 }
        guard name.hasPrefix("x"), let n = UInt32(name.dropFirst()), n < 31 else { return nil }
        return n
    }
}
