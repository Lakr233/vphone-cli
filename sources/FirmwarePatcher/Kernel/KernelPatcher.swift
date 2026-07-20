// KernelPatcher.swift — Regular kernel patcher orchestrator.
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

    /// When true, includes dev-only kernel patches (e.g. EXC_GUARD disable).
    public var isDev: Bool = false

    /// When true, apply the EXC_GUARD (Mach port guard) disable even on
    /// non-dev variants. Needed on every base: iOS 18's older userland
    /// (runningboardd/SpringBoard) trips a Mach port guard "flavor 10" that
    /// crash-loops the UI, and on 26.x bases any app calling
    /// task_swap_exception_ports() (crash-reporting SDKs: Bugly, Crashlytics,
    /// KSCrash, ...) trips a SET_EXCEPTION_BEHAVIOR guard violation that the
    /// research kernel enforces fatally (upstream issue #291 / PR #297).
    public var applyExcGuard: Bool = false

    public convenience init(data: Data, verbose: Bool = true, isDev: Bool, applyExcGuard: Bool = false) {
        self.init(data: data, verbose: verbose)
        self.isDev = isDev
        self.applyExcGuard = applyExcGuard
    }

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

        // EXC_GUARD (Mach port guard) disable — applied on the dev variant
        // always, and on regular/jb/exp via applyExcGuard (see its doc comment).
        if isDev || applyExcGuard {
            patchExcGuardBehavior() // 26
        }

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
