@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("EXP CPU topology")
struct KernelExperimentalPatchCpuTopologyTests {
    // The raw kernelcache is operator supplied, never redistributed.
    static var fixture: String? { ProcessInfo.processInfo.environment["VPHONE_CPUTOP_KERNEL"] }

    private func prepared(_ data: Data) -> KernelExperimentalPatcher {
        let patcher = KernelExperimentalPatcher(data: data)
        patcher.parseMachO()
        patcher.buildADRPIndex()
        return patcher
    }

    /// Every replaced instruction decodes to what the patch promised: six
    /// constants, two stores, and two branches into a cave whose two exits
    /// land where the case's own `b out` went.
    private func assertReplacements(_ patcher: KernelExperimentalPatcher, count: UInt16) throws {
        let decoder = ARM64Disassembler()
        let records = patcher.patches.filter { $0.patchID == "kernel-exp-cpu_topology" }
        let caves = records.filter { $0.patchedBytes.count == 16 }
        let sites = records.filter { $0.patchedBytes.count == 4 }
        #expect(caves.count == 1)
        #expect(sites.count == 10)
        let cave = try #require(caves.first)
        let code = decoder.disassemble(cave.patchedBytes, at: UInt64(cave.fileOffset))
        #expect(code.map(\.mnemonic) == ["add", "b", "add", "b"])
        var constants = 0, stores = 0, jumps = 0
        var exits: Set<Int64> = []
        for record in sites {
            let original = try #require(decoder.disassemble(record.originalBytes, at: UInt64(record.fileOffset)).first)
            let patched = try #require(decoder.disassemble(record.patchedBytes, at: UInt64(record.fileOffset)).first)
            let ops = try #require(patched.detail?.operands)
            switch patched.mnemonic {
            case "mov":
                #expect(["ldr", "add"].contains(original.mnemonic) && ops[1].imm == Int64(count))
                constants += 1
            case "str":
                #expect(original.mnemonic == "add" && ops[0].reg == ARM64Register.w(9) && ops[1].mem.base == .sp)
                stores += 1
            case "b":
                // The displaced instruction was the case's `b out`; its target is kept.
                #expect(original.mnemonic == "b")
                exits.insert(original.detail?.operands.first?.imm ?? -1)
                #expect([Int64(cave.fileOffset), Int64(cave.fileOffset + 8)].contains(ops[0].imm))
                jumps += 1
            default:
                Issue.record("unexpected replacement \(patched.mnemonic) at \(record.fileOffset)")
            }
        }
        #expect(constants == 6)
        #expect(stores == 2)
        #expect(jumps == 2)
        // Both cave exits go where the original branches went.
        let targets = Set(code.compactMap { $0.mnemonic == "b" ? $0.detail?.operands.first?.imm : nil })
        #expect(targets == exits)
        #expect(exits.count == 1)
    }

    @Test(.enabled(if: fixture != nil))
    func `the six count sources are replaced with a constant, idempotently`() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.fixture)))
        let patcher = prepared(data)
        #expect(patcher.patchCpuTopology())
        try assertReplacements(patcher, count: KernelExperimentalPatcher.phoneCoreCount)

        let second = prepared(patcher.patchedData)
        #expect(!second.patchCpuTopology())
        #expect(second.patches.isEmpty)
    }

    @Test(.enabled(if: fixture != nil))
    func `a non-kernel buffer is refused`() throws {
        let patcher = KernelExperimentalPatcher(data: Data(repeating: 0, count: 0x2000))
        #expect(!patcher.patchCpuTopology())
        #expect(patcher.patches.isEmpty)
    }
}

@Suite("EXP hv_vmm_present hide")
struct KernelExperimentalPatchHvVmmHideTests {
    static var fixture: String? { ProcessInfo.processInfo.environment["VPHONE_CPUTOP_KERNEL"] }

    private func prepared(_ data: Data) -> KernelExperimentalPatcher {
        let patcher = KernelExperimentalPatcher(data: data)
        patcher.parseMachO()
        patcher.buildADRPIndex()
        return patcher
    }

    @Test(.enabled(if: fixture != nil))
    func `the handler branches to a trampoline that returns ENOENT to a named caller`() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.fixture)))
        let patcher = prepared(data)
        #expect(patcher.patchHvVmmHideFromUser())

        let records = patcher.patches.filter { $0.patchID == "kernel-exp-hv_vmm.user" }
        #expect(records.count == 2)
        let decoder = ARM64Disassembler()
        let hook = try #require(records.first { $0.patchedBytes.count == 4 })
        let cave = try #require(records.first { $0.patchedBytes.count == 36 })
        let hookWord = try #require(decoder.disassemble(hook.patchedBytes, at: UInt64(hook.fileOffset)).first)
        #expect(hookWord.mnemonic == "b" && hookWord.detail?.operands.first?.imm == Int64(cave.fileOffset))

        let code = decoder.disassemble(cave.patchedBytes, at: UInt64(cave.fileOffset))
        #expect(code.map(\.mnemonic) == ["ldr", "cbnz", "str", "b", "mov", "ldp", "ldp", "add", "retab"])
        let ldr = try #require(code[0].detail?.operands)
        #expect(ldr[0].reg == ARM64Register.x(8) && ldr[1].mem.base == ARM64Register.x(19) && ldr[1].mem.disp == 0)
        let cbnz = try #require(code[1].detail?.operands)
        #expect(cbnz[0].reg == ARM64Register.x(8) && cbnz[1].imm == Int64(cave.fileOffset + 16))
        let back = try #require(code[3].detail?.operands)
        #expect(back[0].imm == Int64(hook.fileOffset + 4))
        let enoent = try #require(code[4].detail?.operands)
        #expect(enoent[1].imm == 2)

        let second = prepared(patcher.patchedData)
        #expect(!second.patchHvVmmHideFromUser())
        #expect(second.patches.isEmpty)
    }
}
