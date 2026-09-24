// KernelExperimentalPatcher.swift — Experimental kernel patcher orchestrator.
//
// Runs after KernelPatcher + KernelJailbreakPatcher for the `.exp` firmware variant
// only. JB and other variants are NOT affected by patches owned here.
//
// Current contents:
//   - patchHvVmmRename (Part A + Part B): rename the kern.hv_vmm_present
//     sysctl OID cstring AND mangle every kernel-internal caller. See
//     EXPPatches/KernelExperimentalPatchHvVmmRename.swift for the implementation.

import Foundation

/// Experimental kernel patcher.
///
/// Inherits the JB infrastructure (symbol table, ADRP/BL indices, branch
/// encoders, code-cave finder, string-anchored function finders, etc.) from
/// `KernelJailbreakPatcherBase` so EXP-specific patches can use the same helpers
/// as JB ones without duplicating them.
public final class KernelExperimentalPatcher: KernelJailbreakPatcherBase, Patcher {
    public let component = "kernelcache_exp"

    public func findAll() throws -> [PatchRecord] {
        try parseMachO()
        buildADRPIndex()
        buildBLIndex()
        buildSymbolTable()
        findPanic()

        // Experimental patches (EXP variant only)
        patchHvVmmRename()

        return patches
    }

    public func apply() throws -> Int {
        // `emit()` already wrote every record through to `buffer.data`.
        let records = try (patches.isEmpty ? findAll() : patches)
        return records.count
    }
}
