// KernelJBPatchThreadSetState.swift — optional Frida Stalker support for updating
// an existing thread's core registers without disabling unrelated Mach-port guards.

import Capstone

extension KernelJBPatcher {
    private struct ThreadSetStateEntitlementGate {
        let branchOff: Int
        let callTarget: Int
    }

    /// Remove only the entitlement-failure edge in thread_set_state_allowed()'s
    /// `FLAVOR_MODIFIES_CORE_CPU_REGISTERS` clause. The exception-handler and
    /// fatal-PAC debug-state clauses remain intact.
    @discardableResult
    func patchThreadSetStateCoreRegisters() -> Bool {
        log("\n[FRIDA] thread_set_state: allow core-register state for Stalker")

        guard let stringOff = buffer.findString("com.apple.private.thread-set-state") else {
            log("  [~] thread-set-state entitlement string not present; skipping")
            return true
        }

        let refs = findStringRefs(stringOff)
        let grouped = Dictionary(grouping: refs) { ref in
            findFunctionStart(ref.adrpOff)
        }

        var candidates: [ThreadSetStateEntitlementGate] = []
        for (functionStart, functionRefs) in grouped {
            guard functionStart != nil else { continue }
            let gates = functionRefs.compactMap(findThreadSetStateEntitlementGate).sorted {
                $0.branchOff < $1.branchOff
            }

            // Source order in thread_set_state_allowed(): exception-handler,
            // core-register, fatal-PAC debug-state. All three entitlement
            // failures converge on one guard-exception block.
            guard gates.count == 3,
                  Set(gates.map(\.callTarget)).count == 1,
                  let firstTarget = conditionalBranchTarget(at: gates[0].branchOff),
                  gates.dropFirst().allSatisfy({
                      conditionalBranchTarget(at: $0.branchOff) == firstTarget
                  })
            else { continue }

            candidates.append(gates[1])
        }

        guard candidates.count == 1, let gate = candidates.first else {
            log("  [~] core-register entitlement gate not present on this kernel; skipping")
            return true
        }

        emit(gate.branchOff, ARM64.nop,
             patchID: "kernelcache_frida.thread_set_state.core_register_entitlement",
             virtualAddress: fileOffsetToVA(gate.branchOff),
             description: "NOP thread_set_state core-register entitlement failure edge [--frida]")
        return true
    }

    /// Match `ADRP+ADD entitlement ; ... ; BL IOTaskHasEntitlement ; CBZ W0,deny`.
    private func findThreadSetStateEntitlementGate(
        _ ref: (adrpOff: Int, addOff: Int)
    ) -> ThreadSetStateEntitlementGate? {
        let scanEnd = min(buffer.count - 16, ref.addOff + 0x20)
        for callOff in stride(from: ref.addOff + 4, through: scanEnd, by: 4) {
            guard let call = disasAt(callOff), call.mnemonic == "bl",
                  let callOps = call.aarch64?.operands, callOps.count == 1,
                  callOps[0].type == AARCH64_OP_IMM
            else { continue }

            for branchOff in stride(from: callOff + 4, through: callOff + 12, by: 4) {
                guard let branch = disasAt(branchOff) else { break }
                if branch.mnemonic == "bl" { break }
                guard branch.mnemonic == "cbz",
                      let branchOps = branch.aarch64?.operands, branchOps.count == 2,
                      branchOps[0].type == AARCH64_OP_REG, branchOps[0].reg == AARCH64_REG_W0,
                      branchOps[1].type == AARCH64_OP_IMM
                else { continue }
                return ThreadSetStateEntitlementGate(
                    branchOff: branchOff,
                    callTarget: Int(callOps[0].imm)
                )
            }
        }
        return nil
    }

    private func conditionalBranchTarget(at off: Int) -> Int? {
        guard let branch = disasAt(off),
              let operands = branch.aarch64?.operands, operands.count == 2,
              operands[1].type == AARCH64_OP_IMM
        else { return nil }
        return Int(operands[1].imm)
    }
}
