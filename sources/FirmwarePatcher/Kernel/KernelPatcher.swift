// KernelPatcher.swift — Regular kernel patcher orchestrator (26 patches).
//
// Historical note: this file replaces the old Python firmware patcher implementation.
// Each patch method is defined as an extension in its own file under Patches/.

import Foundation

/// Regular kernel patcher for iOS prelinked kernelcaches.
///
/// Patches are applied in the same order as the Python reference implementation.
/// Each patch method is an extension in a separate file under `Kernel/Patches/`.
public final class KernelPatcher: KernelPatcherBase, Patcher {
    public let component = "kernelcache"

    // MARK: - Find All

    public func findAll() throws -> [PatchRecord] {
        patches = []

        // Parse Mach-O structure and build indices
        parseMachO()
        buildADRPIndex()
        buildBLIndex()
        findPanic()

        // Apply patches in order (matching Python find_all)
        patchApfsRootSnapshot() // 1
        patchApfsSealBroken() // 2
        patchBsdInitRootvp() // 3
        patchLaunchConstraints() // 4-5
        patchDebugger() // 6-7
        patchPostValidationNOP() // 8
        patchPostValidationCMP() // 9
        patchDyldPolicy() // 10-11
        patchApfsGraft() // 12
        patchApfsMount() // 13-15
        patchSandbox() // 16-25
        patchExcGuardBehavior() // 26

        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        let records = try (patches.isEmpty ? findAll() : patches)
        guard !records.isEmpty else {
            log("  [!] No kernel patches found")
            return 0
        }
        let count = applyPatches()
        log("\n  [\(count) kernel patches applied]")
        return count
    }
}
