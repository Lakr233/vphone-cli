// KernelExperimentalPatcher.swift — Experimental kernel patcher orchestrator.
//
// Runs after KernelPatcher + KernelJailbreakPatcher for public JB firmware.
// The internal historical `.exp` variant uses the same patcher.
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
        parseMachO()
        buildADRPIndex()
        buildBLIndex()
        buildSymbolTable()
        findPanic()

        // Former EXP patch, now part of the public JB firmware pipeline.
        patchHvVmmRename()

        return patches
    }

    public func apply() throws -> Int {
        // `emit()` already wrote every record through to `buffer.data`.
        let records = try (patches.isEmpty ? findAll() : patches)
        return records.count
    }
}
