// KernelJBPatchKcall10.swift — JB kernel patch: kcall10 ABI-correct sysent[439] cave
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy: Replace SYS_kas_info (sysent[439]) with a cave implementing
// the kcall10 primitive:
//   uap[0] = target function pointer
//   uap[1..7] = arg0..arg6
// Returns 64-bit X0 via retval and _SYSCALL_RET_UINT64_T.
//
// The cave is a standard ARM64e function body with PACIBSP/RETAB.
// The sysent entries use arm64e chained auth-rebase fixup pointers.

import Foundation

extension KernelJBPatcher {
    // MARK: - Constants

    private static let sysent_max_entries = 558
    private static let sysent_entry_size = 24
    private static let sysent_pac_diversity: UInt32 = 0xBCAD

    // kcall10 semantics
    private static let kcall10_narg: UInt16 = 8
    private static let kcall10_arg_bytes: UInt16 = 32 // 8 * 4
    private static let kcall10_return_type: UInt32 = 7 // _SYSCALL_RET_UINT64_T
    private static let kcall10_einval: UInt32 = 22

    // MARK: - Entry Point

    /// ABI-correct kcall10 patch: install a sysent[439] cave.
    @discardableResult
    func patchKcall10() -> Bool {
        log("\n[JB] kcall10: ABI-correct sysent[439] cave")

        // 1. Find sysent table base (structural; this kernel is symbol-stripped).
        guard let sysEntOff = findSysentTable() else {
            log("  [-] sysent table not found")
            return false
        }

        let entry439 = sysEntOff + 439 * Self.sysent_entry_size

        // 3. Find a reusable 8-arg munge32 helper.
        let (mungerTarget, _, matchCount) = findMunge32ForNarg(
            sysEntOff: sysEntOff,
            narg: Self.kcall10_narg,
            argBytes: Self.kcall10_arg_bytes
        )
        guard mungerTarget >= 0 else {
            log("  [-] no unique reusable 8-arg munge32 helper found")
            return false
        }

        // 4. Build cave and allocate.
        let caveBytes = buildKcall10Cave()
        guard let caveOff = findCodeCave(size: caveBytes.count) else {
            log("  [-] no executable code cave found for kcall10")
            return false
        }

        // 5. Read original sysent[439] chain metadata.
        guard entry439 + Self.sysent_entry_size <= buffer.count else {
            log("  [-] sysent[439] outside file")
            return false
        }
        let oldSyCallRaw = buffer.readU64(at: entry439)
        let callNext = extractChainNext(oldSyCallRaw)

        let oldMungeRaw = buffer.readU64(at: entry439 + 8)
        let mungeNext = extractChainNext(oldMungeRaw)
        let mungeDiv = extractChainDiversity(oldMungeRaw)
        let mungeAddrDiv = extractChainAddrDiv(oldMungeRaw)
        let mungeKey = extractChainKey(oldMungeRaw)

        log("  [+] sysent table at file offset 0x\(String(format: "%X", sysEntOff))")
        log("  [+] sysent[439] entry at 0x\(String(format: "%X", entry439))")
        log("  [+] reusing unique 8-arg munge32 target 0x\(String(format: "%X", mungerTarget)) (\(matchCount) matching sysent rows)")
        log("  [+] cave at 0x\(String(format: "%X", caveOff)) (0x\(String(format: "%X", caveBytes.count)) bytes)")

        // 6. Emit patches.
        emit(caveOff, caveBytes,
             patchID: "jb.kcall10.cave",
             description: "kcall10 ABI-correct cave (target + 7 args -> uint64 x0)")

        emit(entry439,
             encodeChainedAuthPtr(targetFoff: caveOff, nextVal: callNext,
                                  diversity: Self.sysent_pac_diversity, key: 0, addrDiv: 0),
             patchID: "jb.kcall10.sy_call",
             description: "sysent[439].sy_call = cave 0x\(String(format: "%X", caveOff)) (auth rebase, div=0xBCAD, next=\(callNext)) [kcall10]")

        emit(entry439 + 8,
             encodeChainedAuthPtr(targetFoff: mungerTarget, nextVal: mungeNext,
                                  diversity: mungeDiv, key: mungeKey, addrDiv: mungeAddrDiv),
             patchID: "jb.kcall10.sy_munge",
             description: "sysent[439].sy_arg_munge32 = 8-arg helper 0x\(String(format: "%X", mungerTarget)) [kcall10]")

        // sy_return_type (u32) + sy_narg (u16) + sy_arg_bytes (u16)
        var metadata = Data(count: 8)
        metadata.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: Self.kcall10_return_type.littleEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: Self.kcall10_narg.littleEndian, toByteOffset: 4, as: UInt16.self)
            ptr.storeBytes(of: Self.kcall10_arg_bytes.littleEndian, toByteOffset: 6, as: UInt16.self)
        }
        emit(entry439 + 16, metadata,
             patchID: "jb.kcall10.sysent_meta",
             description: "sysent[439].sy_return_type=7,sy_narg=8,sy_arg_bytes=0x20 [kcall10]")

        return true
    }

    // MARK: - Sysent Table Finder

    /// Find the sysent table base structurally — the longest run of valid 24-byte
    /// `struct sysent` rows in a DATA segment. No symbol or `_nosys` dependency:
    /// each row's `sy_call` is an arm64e chained auth-rebase pointer into executable
    /// memory and the `(sy_return_type, sy_narg, sy_arg_bytes)` trailer is sane, a
    /// shape that no unrelated data run reproduces for hundreds of entries. The base
    /// is wherever the longest such run begins (entries are back-to-back from there).
    private func findSysentTable() -> Int? {
        // Executable file-offset ranges that sy_call / sy_arg_munge32 point into.
        let execSegNames: Set = ["__TEXT_EXEC", "__TEXT_BOOT_EXEC"]
        var execRanges: [(Int, Int)] = []
        for seg in segments where execSegNames.contains(seg.name) && seg.fileSize > 0 {
            execRanges.append((Int(seg.fileOffset), Int(seg.fileOffset + seg.fileSize)))
        }
        if execRanges.isEmpty { execRanges = codeRanges.map { ($0.start, $0.end) } }
        func inExec(_ fo: Int) -> Bool { fo > 0 && execRanges.contains { fo >= $0.0 && fo < $0.1 } }

        func validEntry(_ o: Int) -> Bool {
            guard o + Self.sysent_entry_size <= buffer.count else { return false }
            guard inExec(decodeChainedPtr(buffer.readU64(at: o))) else { return false }
            let rt = buffer.data.loadLE(UInt32.self, at: o + 16)
            let narg = buffer.data.loadLE(UInt16.self, at: o + 20)
            let argBytes = buffer.data.loadLE(UInt16.self, at: o + 22)
            return rt <= 9 && narg <= 12 && argBytes <= 96
        }

        var bestBase = -1
        var bestLen = 0
        for seg in segments where seg.name.contains("DATA") && seg.fileSize > 0 {
            let sStart = Int(seg.fileOffset)
            let sEnd = min(sStart + Int(seg.fileSize), buffer.count)
            var off = sStart
            while off + Self.sysent_entry_size <= sEnd {
                if validEntry(off) {
                    let runStart = off
                    var n = 0
                    while off + Self.sysent_entry_size <= sEnd, validEntry(off) {
                        n += 1
                        off += Self.sysent_entry_size
                    }
                    if n > bestLen { bestLen = n; bestBase = runStart }
                } else {
                    off += 8 // entries are 8-byte aligned
                }
            }
        }

        // The real BSD syscall table has ~550 rows; require a decisively long run.
        guard bestLen >= 256, bestBase >= 0 else {
            log("  [-] no sysent-shaped table found (longest run \(bestLen))")
            return nil
        }
        log("  [+] sysent table base at foff 0x\(String(format: "%X", bestBase)) (\(bestLen) entries)")
        return bestBase
    }

    // MARK: - Munger Finder

    /// Find a reusable 8-arg munge32 helper with matching metadata.
    /// Returns (targetFoff, exemplarEntry, matchCount) or (-1, -1, 0).
    private func findMunge32ForNarg(
        sysEntOff: Int,
        narg: UInt16,
        argBytes: UInt16
    ) -> (Int, Int, Int) {
        var candidates: [Int: [Int]] = [:]
        for idx in 0 ..< Self.sysent_max_entries {
            let entry = sysEntOff + idx * Self.sysent_entry_size
            guard entry + Self.sysent_entry_size <= buffer.count else { break }
            let curNarg = buffer.data.loadLE(UInt16.self, at: entry + 20)
            let curArgBytes = buffer.data.loadLE(UInt16.self, at: entry + 22)
            guard curNarg == narg, curArgBytes == argBytes else { continue }
            let rawMunge = buffer.readU64(at: entry + 8)
            let target = decodeChainedPtr(rawMunge)
            guard target > 0 else { continue }
            candidates[target, default: []].append(entry)
        }
        guard !candidates.isEmpty else { return (-1, -1, 0) }
        guard candidates.count == 1 else {
            log("  [-] multiple distinct 8-arg munge32 helpers found: " +
                candidates.keys.sorted().map { "0x\(String(format: "%X", $0))" }.joined(separator: ", "))
            return (-1, -1, 0)
        }
        let (target, entries) = candidates.first!
        return (target, entries[0], entries.count)
    }

    // MARK: - kcall10 Cave Builder

    /// Build the ABI-correct kcall10 function body.
    ///
    /// Contract:
    ///   x0 = proc*
    ///   x1 = &uthread->uu_arg[0]  (uap pointer)
    ///   x2 = &uthread->uu_rval[0] (retval pointer)
    ///
    /// uap layout (8 qwords):
    ///   [0] target function pointer
    ///   [1..7] arg0..arg6
    ///
    /// Returns EINVAL (22) on null uap/retval/target, else stores X0 into retval
    /// and returns 0 with _SYSCALL_RET_UINT64_T.
    private func buildKcall10Cave() -> Data {
        var code: [Data] = []

        // pacibsp
        code.append(ARM64.pacibsp)
        // sub sp, sp, #0x30
        code.append(encodeU32k(0xD100_C3FF)) // sub sp, sp, #0x30
        // stp x21, x22, [sp]
        code.append(encodeU32k(0xA900_5BF5)) // stp x21, x22, [sp]
        // stp x19, x20, [sp, #0x10]
        code.append(encodeU32k(0xA901_53F3)) // stp x19, x20, [sp, #0x10]
        // stp x29, x30, [sp, #0x20]
        code.append(encodeU32k(0xA902_7BFD)) // stp x29, x30, [sp, #0x20]
        // add x29, sp, #0x20
        code.append(encodeU32k(0x9100_83FD)) // add x29, sp, #0x20
        // mov w19, #22  (EINVAL = 22 = 0x16)
        code.append(encodeU32k(0x5280_02D3)) // movz w19, #0x16
        // mov x20, x1  (save uap)
        code.append(encodeU32k(0xAA01_03F4)) // mov x20, x1
        // mov x21, x2  (save retval)
        code.append(encodeU32k(0xAA02_03F5)) // mov x21, x2
        // cbz x20, #0x30  (null uap → skip to exit, 12 instrs forward)
        code.append(encodeU32k(0xB400_0194)) // cbz x20, #+0x30
        // cbz x21, #0x2c  (null retval → skip to exit)
        code.append(encodeU32k(0xB400_0175)) // cbz x21, #+0x2c
        // ldr x16, [x20]  (target = uap[0])
        code.append(encodeU32k(0xF940_0290)) // ldr x16, [x20]
        // cbz x16, #0x24  (null target → skip, 9 instrs)
        code.append(encodeU32k(0xB400_0130)) // cbz x16, #+0x24
        // ldp x0, x1, [x20, #0x8]
        code.append(encodeU32k(0xA940_8680)) // ldp x0, x1, [x20, #0x8]
        // ldp x2, x3, [x20, #0x18]
        code.append(encodeU32k(0xA941_8E82)) // ldp x2, x3, [x20, #0x18]
        // ldp x4, x5, [x20, #0x28]
        code.append(encodeU32k(0xA942_9684)) // ldp x4, x5, [x20, #0x28]
        // ldr x6, [x20, #0x38]
        code.append(encodeU32k(0xF940_1E86)) // ldr x6, [x20, #0x38]
        // mov x7, xzr
        code.append(encodeU32k(0xAA1F_03E7)) // mov x7, xzr
        // blr x16
        code.append(encodeU32k(0xD63F_0200)) // blr x16
        // str x0, [x21]  (store result in retval)
        code.append(encodeU32k(0xF900_02A0)) // str x0, [x21]
        // mov w19, #0
        code.append(encodeU32k(0x5280_0013)) // movz w19, #0
        // mov w0, w19  (return value)
        code.append(encodeU32k(0x2A13_03E0)) // mov w0, w19
        // ldp x21, x22, [sp]
        code.append(encodeU32k(0xA940_5BF5)) // ldp x21, x22, [sp]
        // ldp x19, x20, [sp, #0x10]
        code.append(encodeU32k(0xA941_53F3)) // ldp x19, x20, [sp, #0x10]
        // ldp x29, x30, [sp, #0x20]
        code.append(encodeU32k(0xA942_7BFD)) // ldp x29, x30, [sp, #0x20]
        // add sp, sp, #0x30
        code.append(encodeU32k(0x9100_C3FF)) // add sp, sp, #0x30
        // retab
        code.append(ARM64.retab)

        return code.reduce(Data(), +)
    }

    // MARK: - Chain Pointer Helpers

    /// Encode an arm64e kernel cache auth-rebase chained fixup pointer.
    private func encodeChainedAuthPtr(
        targetFoff: Int,
        nextVal: UInt32,
        diversity: UInt32,
        key: UInt32,
        addrDiv: UInt32
    ) -> Data {
        let val: UInt64 =
            (UInt64(targetFoff) & 0x3FFF_FFFF) |
            (UInt64(diversity & 0xFFFF) << 32) |
            (UInt64(addrDiv & 1) << 48) |
            (UInt64(key & 3) << 49) |
            (UInt64(nextVal & 0xFFF) << 51) |
            (1 << 63)
        return withUnsafeBytes(of: val.littleEndian) { Data($0) }
    }

    private func extractChainNext(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 51) & 0xFFF)
    }

    private func extractChainDiversity(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 32) & 0xFFFF)
    }

    private func extractChainAddrDiv(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 48) & 1)
    }

    private func extractChainKey(_ raw: UInt64) -> UInt32 {
        UInt32((raw >> 49) & 3)
    }

    // MARK: - Encoding Helper

    private func encodeU32k(_ value: UInt32) -> Data {
        ARM64.encodeU32(value)
    }
}
