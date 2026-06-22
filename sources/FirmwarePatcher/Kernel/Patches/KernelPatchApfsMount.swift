// KernelPatchApfsMount.swift — APFS mount/dev-role patches (patches 13, 14, 15, 16).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//                scripts/patchers/kernel_patch_apfs_graft.py (patch_handle_fsioc_graft)

import Capstone
import Foundation

extension KernelPatcher {
    // MARK: - Private Helpers

    /// Decode a BL instruction at `offset`. Returns the target file offset, or nil.
    private func apfsMountDecodeBL(at offset: Int) -> Int? {
        guard offset + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: offset)
        guard insn >> 26 == 0b100101 else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        return offset + Int(signedImm) * 4
    }

    /// Return true if the function at `funcOff` contains a RET within `maxBytes`.
    private func apfsMountIsLeaf(at funcOff: Int, maxBytes: Int = 0x20) -> Bool {
        let limit = min(funcOff + maxBytes, buffer.count)
        var scan = funcOff
        while scan + 4 <= limit {
            let insn = buffer.readU32(at: scan)
            if insn == ARM64.retU32 || insn == ARM64.retaaU32 || insn == ARM64.retabU32 {
                return true
            }
            scan += 4
        }
        return false
    }

    // MARK: - Patch 13: _apfs_vfsop_mount — cmp x0, x0

    /// Patch 13: Replace `cmp x0, Xm` with `cmp x0, x0` in _apfs_vfsop_mount.
    ///
    /// The target CMP follows the pattern: BL (returns current_thread in x0),
    /// ADRP + LDR + LDR (load kernel_task global), CMP x0, Xm, B.EQ.
    /// We require x0 as the first CMP operand to distinguish it from other CMPs.
    @discardableResult
    func patchApfsVfsopMountCmp() -> Bool {
        log("\n[13] _apfs_vfsop_mount: cmp x0,x0 (mount rw check)")

        let apfsRange = apfsTextRange()

        guard let strOff = buffer.findString("apfs_mount_upgrade_checks") else {
            log("  [-] 'apfs_mount_upgrade_checks' string not found")
            return false
        }

        let refs = findStringRefs(strOff, in: apfsRange)
        guard !refs.isEmpty else {
            log("  [-] no code refs to apfs_mount_upgrade_checks")
            return false
        }

        // Locate the function start of _apfs_mount_upgrade_checks.
        guard let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] function start not found for apfs_mount_upgrade_checks ref")
            return false
        }

        // Gather BL callers of that function.
        var callers = blIndex[funcStart] ?? []
        if callers.isEmpty {
            callers = blIndex[funcStart + 4] ?? []
        }
        if callers.isEmpty {
            // Manual scan for BL callers when not in index.
            for (rangeStart, rangeEnd) in codeRanges {
                var off = rangeStart
                while off + 4 <= rangeEnd {
                    if let target = apfsMountDecodeBL(at: off),
                       target >= funcStart, target <= funcStart + 4
                    {
                        callers.append(off)
                    }
                    off += 4
                }
            }
        }

        guard !callers.isEmpty else {
            log("  [-] no BL callers of _apfs_mount_upgrade_checks found")
            return false
        }

        for callerOff in callers {
            guard callerOff >= apfsRange.start, callerOff < apfsRange.end else { continue }

            let callerFuncStart = findFunctionStart(callerOff)
            let scanStart = callerFuncStart ?? max(callerOff - 0x800, apfsRange.start)
            let scanEnd = min(callerOff + 0x100, apfsRange.end)

            var scan = scanStart
            while scan + 4 <= scanEnd {
                guard let insn = disasm.disassembleOne(in: buffer.data, at: scan),
                      insn.mnemonic == "cmp",
                      let detail = insn.aarch64,
                      detail.operands.count >= 2
                else {
                    scan += 4; continue
                }

                let ops = detail.operands
                // Both operands must be registers.
                guard ops[0].type == AARCH64_OP_REG, ops[1].type == AARCH64_OP_REG else {
                    scan += 4; continue
                }
                // First operand must be x0 (return value from BL current_thread).
                guard ops[0].reg == AARCH64_REG_X0 else {
                    scan += 4; continue
                }
                // Skip CMP x0, x0 (already patched or trivially true).
                guard ops[0].reg != ops[1].reg else {
                    scan += 4; continue
                }

                let va = fileOffsetToVA(scan)
                emit(
                    scan,
                    ARM64.cmpX0X0,
                    patchID: "kernel.apfs_vfsop_mount.cmp_x0_x0",
                    virtualAddress: va,
                    description: "cmp x0,x0 (was \(insn.mnemonic) \(insn.operandString)) [_apfs_vfsop_mount]"
                )
                return true
            }
        }

        log("  [-] CMP x0,Xm not found near mount_upgrade_checks caller")
        return false
    }

    // MARK: - Patch 14: _apfs_mount_upgrade_checks — mov w0, #0

    /// Patch 14: Replace `tbnz w0, #0xe, ...` with `mov w0, #0`.
    ///
    /// Within the function a BL calls a small leaf flag-reading function, then
    /// TBNZ w0, #0xe branches to the error path. Replace TBNZ with mov w0,#0.
    @discardableResult
    func patchApfsMountUpgradeChecks() -> Bool {
        log("\n[14] _apfs_mount_upgrade_checks: mov w0,#0 (tbnz bypass)")

        let apfsRange = apfsTextRange()

        guard let strOff = buffer.findString("apfs_mount_upgrade_checks") else {
            log("  [-] 'apfs_mount_upgrade_checks' string not found")
            return false
        }

        let refs = findStringRefs(strOff, in: apfsRange)
        guard !refs.isEmpty else {
            log("  [-] no code refs to apfs_mount_upgrade_checks")
            return false
        }

        guard let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] function start not found")
            return false
        }

        let limit = min(funcStart + 0x200, buffer.count)
        var scan = funcStart
        while scan + 4 <= limit {
            // Stop at PACIBSP (new function boundary), but not at early returns.
            if scan > funcStart + 8, buffer.readU32(at: scan) == ARM64.pacibspU32 {
                break
            }

            guard let blTarget = apfsMountDecodeBL(at: scan) else {
                scan += 4; continue
            }
            // Target must be a small leaf function.
            guard apfsMountIsLeaf(at: blTarget) else {
                scan += 4; continue
            }

            // Next instruction must be TBNZ w0, #N (any bit).
            let nextOff = scan + 4
            guard nextOff + 4 <= buffer.count,
                  let nextInsn = disasm.disassembleOne(in: buffer.data, at: nextOff),
                  nextInsn.mnemonic == "tbnz",
                  let detail = nextInsn.aarch64,
                  !detail.operands.isEmpty,
                  detail.operands[0].type == AARCH64_OP_REG,
                  detail.operands[0].reg == AARCH64_REG_W0
            else {
                scan += 4; continue
            }

            let va = fileOffsetToVA(nextOff)
            emit(
                nextOff,
                ARM64.movW0_0,
                patchID: "kernel.apfs_mount_upgrade_checks.mov_w0_0",
                virtualAddress: va,
                description: "mov w0,#0 [_apfs_mount_upgrade_checks]"
            )
            return true
        }

        log("  [-] BL + TBNZ w0 pattern not found")
        return false
    }

    // MARK: - Patch 15: _handle_fsioc_graft — mov w0, #0

    /// Patch 15: Replace the BL to `validate_payload_and_manifest` with `mov w0, #0`
    /// inside `_handle_fsioc_graft`.
    @discardableResult
    func patchHandleFsiocGraft() -> Bool {
        log("\n[15] _handle_fsioc_graft: mov w0,#0 (validate BL)")

        let apfsRange = apfsTextRange()

        // Locate "handle_fsioc_graft" string (expect surrounding NUL bytes).
        guard let raw = "handle_fsioc_graft".data(using: .utf8) else { return false }
        var searchPattern = Data([0x00])
        searchPattern.append(raw)
        searchPattern.append(0x00)

        guard let patternRange = buffer.data.range(of: searchPattern) else {
            log("  [-] 'handle_fsioc_graft' string not found")
            return false
        }
        let fsiocStrOff = patternRange.lowerBound + 1 // skip leading NUL

        let fsiocRefs = findStringRefs(fsiocStrOff, in: apfsRange)
        guard !fsiocRefs.isEmpty else {
            log("  [-] no code refs to handle_fsioc_graft string")
            return false
        }

        guard let fsiocStart = findFunctionStart(fsiocRefs[0].adrpOff) else {
            log("  [-] _handle_fsioc_graft function start not found")
            return false
        }

        // Locate validate_payload_and_manifest function start.
        guard let valStrOff = buffer.findString("validate_payload_and_manifest") else {
            log("  [-] 'validate_payload_and_manifest' string not found")
            return false
        }

        let valRefs = findStringRefs(valStrOff, in: apfsRange)
        guard !valRefs.isEmpty else {
            log("  [-] no code refs to validate_payload_and_manifest")
            return false
        }

        guard let valFunc = findFunctionStart(valRefs[0].adrpOff) else {
            log("  [-] validate_payload_and_manifest function start not found")
            return false
        }

        // Scan _handle_fsioc_graft for BL targeting valFunc.
        let scanEnd = min(fsiocStart + 0x400, buffer.count)
        var scan = fsiocStart
        while scan + 4 <= scanEnd {
            if scan > fsiocStart + 8, buffer.readU32(at: scan) == ARM64.pacibspU32 {
                break
            }
            if isBL(at: scan, target: valFunc) {
                let va = fileOffsetToVA(scan)
                emit(
                    scan,
                    ARM64.movW0_0,
                    patchID: "kernel.handle_fsioc_graft.mov_w0_0",
                    virtualAddress: va,
                    description: "mov w0,#0 [_handle_fsioc_graft]"
                )
                return true
            }
            scan += 4
        }

        log("  [-] BL to validate_payload_and_manifest not found in _handle_fsioc_graft")
        return false
    }

    // MARK: - Patch 16: handle_get_dev_by_role — bypass entitlement gate

    /// Patch 16: NOP CBZ/CBNZ on X0/W0 that branch to entitlement-error blocks
    /// in `handle_get_dev_by_role`.
    ///
    /// Error blocks are identified by `mov w8, #0x332D` or `mov w8, #0x333B`
    /// within the first 0x30 bytes (known entitlement-gate line IDs).
    @discardableResult
    func patchHandleGetDevByRoleEntitlement() -> Bool {
        log("\n[16] handle_get_dev_by_role: bypass entitlement gate")

        let apfsRange = apfsTextRange()

        guard let strOff = buffer.findString("com.apple.apfs.get-dev-by-role") else {
            log("  [-] entitlement string not found")
            return false
        }

        let refs = findStringRefs(strOff, in: apfsRange)
        guard !refs.isEmpty else {
            log("  [-] no code refs to entitlement string")
            return false
        }

        // Scope to this routine: its deny blocks load both the message and the
        // `handle_get_dev_by_role` name; the name excludes the adjacent keybag handler.
        let msgRefs = stringRefSet(in: apfsRange, needles: [
            "%s:%d: %s This operation needs entitlement",
            "%s:%d: %s lookup takes place out of a volume group, but the source volume is in one",
        ])
        let nameRefs = stringRefSet(in: apfsRange, needles: ["handle_get_dev_by_role"])

        for ref in refs {
            guard let funcStart = findFunctionStart(ref.adrpOff) else { continue }
            let funcEnd = min(funcStart + 0x1200, buffer.count)

            var candidates: [(off: Int, target: Int)] = []

            var scan = funcStart
            while scan + 4 <= funcEnd {
                guard let insn = disasm.disassembleOne(in: buffer.data, at: scan),
                      insn.mnemonic == "cbz" || insn.mnemonic == "cbnz",
                      let detail = insn.aarch64,
                      detail.operands.count >= 2
                else {
                    scan += 4; continue
                }

                let ops = detail.operands
                guard ops[0].type == AARCH64_OP_REG,
                      ops[1].type == AARCH64_OP_IMM
                else {
                    scan += 4; continue
                }

                let reg = ops[0].reg
                guard reg == AARCH64_REG_X0 || reg == AARCH64_REG_W0 else {
                    scan += 4; continue
                }

                let target = Int(ops[1].imm)
                guard target > scan, target >= funcStart, target < funcEnd else {
                    scan += 4; continue
                }

                let span = target ..< min(target + 0x40, funcEnd)
                let inSpan = { (s: Set<Int>) in s.contains { span.contains($0) } }
                if inSpan(msgRefs), inSpan(nameRefs) {
                    if !candidates.contains(where: { $0.off == scan }) {
                        candidates.append((off: scan, target: target))
                    }
                }

                scan += 4
            }

            if !candidates.isEmpty {
                for cand in candidates {
                    let va = fileOffsetToVA(cand.off)
                    emit(
                        cand.off,
                        ARM64.nop,
                        patchID: "kernel.handle_get_dev_by_role.gate_\(String(format: "%X", cand.off))",
                        virtualAddress: va,
                        description: "NOP [handle_get_dev_by_role entitlement gate -> 0x\(String(format: "%X", cand.target))]"
                    )
                }
                return true
            }
        }

        log("  [-] handle_get_dev_by_role entitlement gate pattern not found")
        return false
    }

    /// ADRP+ADD reference offsets to `needles`. Anchors deny-block detection on stable
    /// panic strings instead of the per-version line IDs the old matcher pinned.
    private func stringRefSet(in range: (start: Int, end: Int), needles: [String]) -> Set<Int> {
        var refs = Set<Int>()
        for needle in needles {
            guard let strOff = buffer.findString(needle) else { continue }
            for ref in findStringRefs(strOff, in: range) { refs.insert(ref.adrpOff) }
        }
        return refs
    }

    // MARK: - Aggregate entry point

    /// Apply all APFS mount patches (13, 14, 15, 16).
    @discardableResult
    func patchApfsMount() -> Bool {
        let r13 = patchApfsVfsopMountCmp()
        let r14 = patchApfsMountUpgradeChecks()
        let r15 = patchHandleFsiocGraft()
        let r16 = patchHandleGetDevByRoleEntitlement()
        return r13 && r14 && r15 && r16
    }
}
