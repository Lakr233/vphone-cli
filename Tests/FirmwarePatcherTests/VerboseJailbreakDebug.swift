@testable import FirmwarePatcher
import Foundation
import Testing

struct VerboseJailbreakDebug {
    @Test func `debug failing patches`() throws {
        let baseDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ipsws/patch_refactor_input")
        let data = try Data(contentsOf: baseDir.appendingPathComponent("raw_payloads/kernelcache.bin"))
        let patcher = KernelJailbreakPatcher(data: data, verbose: true)

        // Initialize patcher state (same as findAll() but without running patches)
        try patcher.parseMachO()
        patcher.buildADRPIndex()
        patcher.buildBLIndex()
        patcher.buildSymbolTable()
        patcher.findPanic()

        print("=== HOOK CRED LABEL ===")
        let r1 = patcher.patchHookCredLabelUpdateExecve()
        print("Result: \(r1)")

        print("\n=== TASK CONVERSION ===")
        let r2 = patcher.patchTaskConversionEvalInternal()
        print("Result: \(r2)")

        print("\n=== BSD INIT AUTH ===")
        let r3 = patcher.patchBsdInitAuth()
        print("Result: \(r3)")

        print("\n=== IOUC MACF ===")
        let r4 = patcher.patchIoucFailedMacf()
        print("Result: \(r4)")
    }
}
