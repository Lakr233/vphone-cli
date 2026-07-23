// KernelJBPatchFpfsScopedOpen.swift — iOS 27 only.
//
// The JB neuters Sandbox vnode_check_open globally so processes can reach /var/jb. But
// FileProvider's fpfs parent-walk needs the stock check to deny at the domain-container
// boundary; without it the walk climbs unbounded and ResolverService balloons → jetsam →
// respring. KernelJBPatchSandboxExtended therefore leaves ops[267] un-neutered on 27, and
// this patch retargets it to a trampoline that runs the real check only for the FileProvider
// daemons (matched by p_comm) and returns allow for everyone else — preserving the bypass.

import Foundation

extension KernelJBPatcher {
    private static let vnodeCheckOpenIndex = 267

    @discardableResult
    func patchFpfsScopedVnodeOpen() -> Bool {
        log("\n[JB] fpfs: scope vnode_check_open to FileProvider daemons")

        guard let opsTable = findSandboxOpsTableFpfs() else {
            log("  [-] sandbox ops table not found"); return false
        }
        let entryOff = opsTable + Self.vnodeCheckOpenIndex * 8
        guard entryOff + 8 <= buffer.count else { return false }
        let entryRaw = buffer.readU64(at: entryOff)
        guard (entryRaw & (1 << 63)) != 0 else {
            log("  [-] ops[267] not the real hook (neutered?): 0x\(String(format: "%016X", entryRaw))"); return false
        }
        let realHookOff = decodeChainedPtr(entryRaw)
        guard realHookOff >= 0, codeRanges.contains(where: { realHookOff >= $0.start && realHookOff < $0.end }) else {
            log("  [-] ops[267] target not in code"); return false
        }

        guard let caveOff = findCodeCave(size: 20 * 4) else { log("  [-] no code cave"); return false }
        guard let caveBytes = buildScopedOpenCave(caveOff: caveOff, realHookOff: realHookOff) else { return false }
        guard let newEntry = encodeAuthRebaseTarget(origVal: entryRaw, targetFoff: caveOff) else { return false }

        emit(entryOff, newEntry, patchID: "jb.fpfs_scoped_open.ops_retarget",
             description: "ops[267] -> FileProvider-scoped vnode_check_open trampoline")
        emit(caveOff, caveBytes, patchID: "jb.fpfs_scoped_open.cave",
             description: "trampoline: FileProvider daemons -> real check, else allow")
        return true
    }

    // vphone600 struct offsets recovered via the kernel gdb stub; cave bytes verified by
    // capstone round-trip. p_comm[0:8] little-endian: "Resolver" = ResolverService,
    // "fileprov" = fileproviderd.
    private func buildScopedOpenCave(caveOff: Int, realHookOff: Int) -> Data? {
        func movkX10(_ hw: [UInt16]) -> [UInt32] {
            var out: [UInt32] = [0xD280_0000 | (UInt32(hw[0]) << 5) | 10] // movz x10, #hw0
            for i in 1 ..< 4 { out.append(0xF280_0000 | (UInt32(i) << 21) | (UInt32(hw[i]) << 5) | 10) } // movk lsl #16*i
            return out
        }
        var w: [UInt32] = [
            0xD538_D088, // mrs x8, tpidr_el1
            0xF941_F908, // ldr x8, [x8, #0x3F0]   ; uthread
            0xF940_0D08, // ldr x8, [x8, #0x18]    ; proc
            0x9115_B108, // add x8, x8, #0x56C     ; &p_comm
            0xF940_0109, // ldr x9, [x8]           ; p_comm[0:8]
        ]
        w += movkX10([0x6552, 0x6f73, 0x766c, 0x7265]) // x10 = "Resolver"
        w.append(0xEB0A_013F) // cmp x9, x10
        let beqA = w.count; w.append(0)
        w += movkX10([0x6966, 0x656c, 0x7270, 0x766f]) // x10 = "fileprov"
        w.append(0xEB0A_013F) // cmp x9, x10
        let beqB = w.count; w.append(0)
        w.append(0xD280_0000) // mov x0, #0
        w.append(0xD65F_03C0) // ret
        let enforce = w.count; w.append(0) // b <realHook>

        func beq(from: Int) -> UInt32 {
            let imm19 = UInt32(bitPattern: Int32(((enforce - from) * 4) >> 2)) & 0x7FFFF
            return 0x5400_0000 | (imm19 << 5) // b.eq (cond EQ)
        }
        w[beqA] = beq(from: beqA)
        w[beqB] = beq(from: beqB)
        guard let bData = encodeB(from: caveOff + enforce * 4, to: realHookOff) else { return nil }
        w[enforce] = bData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian

        guard w.count == 20 else { log("  [-] cave length drifted: \(w.count)"); return nil }
        var data = Data(capacity: 80)
        for x in w { withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func encodeAuthRebaseTarget(origVal: UInt64, targetFoff: Int) -> Data? {
        guard (origVal & (1 << 63)) != 0 else { return nil }
        let v = (origVal & ~UInt64(0xFFFF_FFFF)) | (UInt64(targetFoff) & 0xFFFF_FFFF)
        return withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private func findSandboxOpsTableFpfs() -> Int? {
        guard let seatbeltOff = buffer.findString("Seatbelt sandbox policy"),
              let pattern = "\u{0}Sandbox\u{0}".data(using: .utf8),
              let range = buffer.data.range(of: pattern) else { return nil }
        let sandboxOff = range.lowerBound + 1
        for seg in segments where (seg.name == "__DATA_CONST" || seg.name == "__DATA") && seg.fileSize > 40 {
            var i = Int(seg.fileOffset); let end = i + Int(seg.fileSize)
            while i <= end - 40 {
                defer { i += 8 }
                let v0 = buffer.readU64(at: i)
                guard v0 != 0, (v0 & (1 << 63)) == 0, (v0 & 0x7FF_FFFF_FFFF) == UInt64(sandboxOff) else { continue }
                let v1 = buffer.readU64(at: i + 8)
                guard (v1 & (1 << 63)) == 0, (v1 & 0x7FF_FFFF_FFFF) == UInt64(seatbeltOff) else { continue }
                let vOps = buffer.readU64(at: i + 32)
                if (vOps & (1 << 63)) == 0 { return Int(vOps & 0x7FF_FFFF_FFFF) }
            }
        }
        return nil
    }
}
