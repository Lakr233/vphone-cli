// KernelEXPPatcher.swift — Experimental kernel patcher orchestrator.
//
// Runs after KernelPatcher + KernelJBPatcher for the `.exp` firmware variant
// only. JB and other variants are NOT affected by patches owned here.
//
// Current contents:
//   - patchHvVmmRename (Part A + Part B): rename the kern.hv_vmm_present
//     sysctl OID cstring AND mangle every kernel-internal caller. See
//     EXPPatches/KernelEXPPatchHvVmmRename.swift for the implementation.

import Foundation

/// Experimental kernel patcher.
///
/// Inherits the JB infrastructure (symbol table, ADRP/BL indices, branch
/// encoders, code-cave finder, string-anchored function finders, etc.) from
/// `KernelJBPatcherBase` so EXP-specific patches can use the same helpers
/// as JB ones without duplicating them.
public final class KernelEXPPatcher: KernelJBPatcherBase, Patcher {
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
        let records = try (patches.isEmpty ? findAll() : patches)
        for record in records {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        return records.count
    }
}
