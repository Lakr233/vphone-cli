// KernelExcGuardTests.swift — Which callee kernel-boot-thread_guard_violation patches.
//
// set_exception_behavior_violation below is the cloudOS 26.1 (23B85)
// kernelcache.research.vphone600 function byte for byte (foff 0xB04178), the
// kernel's own words, with only its BLs re-encoded for the synthetic layout.
// That kernel boots iOS 18.6.2, so the iOS 18 gate applies the patch to it. It
// raises the guard on the current thread seven instructions after
// `mrs x0, tpidr_el1`, and later calls get_threadtask(current_thread()) for
// send_set_exception_telemetry right after a second `mrs x0, tpidr_el1`.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("kernel-boot-thread_guard_violation")
struct KernelExcGuardTests {
    // MARK: - Synthetic kernel

    static let anchor = "com.apple.security.only-one-exception-port"

    /// Offsets inside `__TEXT_EXEC`.
    static let callerOffset = 0x000
    static let violationOffset = 0x100
    static let guardOffset = 0x300 // thread_guard_violation
    static let taskOffset = 0x400 // get_threadtask
    static let otherOffset = 0x500

    enum Callee { case guardViolation, threadTask, other }

    /// cloudOS 26.1 set_exception_behavior_violation; BL words are placeholders.
    static let violation26: [(UInt32, Callee?)] = [
        (0xD503_237F, nil), // pacibsp
        (0xA9BC_5FF8, nil), // stp x24, x23, [sp, #-0x40]!
        (0xA901_57F6, nil), // stp x22, x21, [sp, #0x10]
        (0xA902_4FF4, nil), // stp x20, x19, [sp, #0x20]
        (0xA903_7BFD, nil), // stp x29, x30, [sp, #0x30]
        (0x9100_C3FD, nil), // add x29, sp, #0x30
        (0xAA00_03F4, nil), // mov x20, x0
        (0xD0FF_DBD7, nil), // adrp x23, thid_should_crash@page
        (0x396D_42E8, nil), // ldrb w8, [x23, #0xb50]
        (0x2A01_03F3, nil), // mov w19, w1
        (0x3600_0128, nil), // tbz w8, #0, +0x24
        (0xD538_D080, nil), // mrs x0, tpidr_el1
        (0x2A02_03E8, nil), // mov w8, w2
        (0xD2C0_00C9, nil), // mov x9, #0x600000000
        (0xF2E4_0009, nil), // movk x9, #0x2000, lsl #48
        (0xAA09_0101, nil), // orr x1, x8, x9
        (0xAA13_03E2, nil), // mov x2, x19
        (0x5280_0023, nil), // mov w3, #1
        (0, .guardViolation), // bl thread_guard_violation
        (0x9000_E488, nil), // adrp x8, ...
        (0xF941_7101, nil), // ldr x1, [x8, #0x2e0]
        (0x5280_0600, nil), // mov w0, #0x30
        (0x5290_0082, nil), // mov w2, #0x8004
        (0, .other), // bl kalloc_type
        (0xAA00_03F5, nil), // mov x21, x0
        (0xF940_0816, nil), // ldr x22, [x0, #0x10]
        (0xD538_D080, nil), // mrs x0, tpidr_el1
        (0, .threadTask), // bl get_threadtask
        (0xAA16_03E1, nil), // mov x1, x22
        (0x5280_0222, nil), // mov w2, #0x11
        (0, .other), // bl strlcpy
        (0xD65F_0FFF, nil), // retab
    ]

    /// The iOS 18 research kernel shape: the guard call follows its MRS.
    static let violation18: [(UInt32, Callee?)] = [
        (0xD503_237F, nil), // pacibsp
        (0xD538_D080, nil), // mrs x0, tpidr_el1
        (0xAA13_03E1, nil), // mov x1, x19
        (0xAA14_03E2, nil), // mov x2, x20
        (0x5280_0023, nil), // mov w3, #1
        (0, .guardViolation), // bl thread_guard_violation
        (0xD65F_0FFF, nil), // retab
    ]

    /// A minimal arm64 kernel with one `__TEXT_EXEC` segment: a caller that
    /// loads the anchor string and calls `violation`, the violation function,
    /// and three callees that only return. The anchor string sits after the
    /// segment.
    static func kernel(violation: [(UInt32, Callee?)]) -> (data: Data, textStart: Int) {
        let textStart = 0x1000
        let textSize = 0x1000
        let stringOffset = textStart + textSize + 0x100
        var bytes = [UInt8](repeating: 0, count: stringOffset + 0x100)

        func put(_ data: Data?, at offset: Int) {
            guard let data else { return }
            bytes.replaceSubrange(offset ..< offset + data.count, with: data)
        }
        func put(_ word: UInt32, at offset: Int) {
            withUnsafeBytes(of: word.littleEndian) { bytes.replaceSubrange(offset ..< offset + 4, with: $0) }
        }

        // Mach-O header and LC_SEGMENT_64 __TEXT_EXEC.
        var header = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append32(0xFEED_FACF)
        append32(0x0100_000C)
        append32(2)
        append32(2)
        append32(1)
        append32(72)
        append32(0)
        append32(0)
        append32(0x19)
        append32(72)
        var segname = Data("__TEXT_EXEC".utf8)
        segname.append(contentsOf: [UInt8](repeating: 0, count: 16 - segname.count))
        header.append(segname)
        append64(0xFFFF_FE00_0700_4000 + UInt64(textStart))
        append64(UInt64(textSize))
        append64(UInt64(textStart))
        append64(UInt64(textSize))
        append32(5)
        append32(5)
        append32(0)
        append32(0)
        put(header, at: 0)

        // Caller: adrp/add of the anchor, then a BL to the violation function.
        let caller = textStart + callerOffset
        put(ARM64.pacibspU32, at: caller)
        put(ARM64Encoder.encodeADRP(rd: 8, pc: UInt64(caller + 4), target: UInt64(stringOffset)), at: caller + 4)
        put(ARM64Encoder.encodeAddImm12(rd: 8, rn: 8, imm12: UInt32(stringOffset & 0xFFF)), at: caller + 8)
        put(ARM64Encoder.encodeBL(from: caller + 12, to: textStart + violationOffset), at: caller + 12)
        put(ARM64.retabU32, at: caller + 16)

        // The violation function.
        for (index, (word, callee)) in violation.enumerated() {
            let offset = textStart + violationOffset + 4 * index
            switch callee {
            case nil: put(word, at: offset)
            case .guardViolation: put(ARM64Encoder.encodeBL(from: offset, to: textStart + guardOffset), at: offset)
            case .threadTask: put(ARM64Encoder.encodeBL(from: offset, to: textStart + taskOffset), at: offset)
            case .other: put(ARM64Encoder.encodeBL(from: offset, to: textStart + otherOffset), at: offset)
            }
        }

        // Callees that only return.
        for offset in [guardOffset, taskOffset, otherOffset] {
            put(ARM64.pacibspU32, at: textStart + offset)
            put(ARM64.retabU32, at: textStart + offset + 4)
        }

        bytes.replaceSubrange(stringOffset ..< stringOffset + anchor.utf8.count, with: Array(anchor.utf8))
        return (Data(bytes), textStart)
    }

    static func patcher(_ data: Data) -> KernelPatcher {
        let patcher = KernelPatcher(data: data, verbose: false)
        patcher.parseMachO()
        patcher.buildADRPIndex()
        patcher.buildBLIndex()
        return patcher
    }

    // MARK: - The locator

    @Test func `patches the guard call, not get_threadtask, on the cloudOS 26.1 shape`() throws {
        let (data, textStart) = Self.kernel(violation: Self.violation26)
        let patcher = Self.patcher(data)

        #expect(patcher.patchExcGuardBehavior())
        #expect(patcher.patches.count == 1)
        let patch = try #require(patcher.patches.first)
        #expect(patch.patchID == "kernel-boot-thread_guard_violation")
        #expect(patch.fileOffset == textStart + Self.guardOffset)
        #expect(patch.patchedBytes == ARM64.ret)
    }

    @Test func `keeps the iOS 18 kernel shape`() throws {
        let (data, textStart) = Self.kernel(violation: Self.violation18)
        let patcher = Self.patcher(data)

        #expect(patcher.patchExcGuardBehavior())
        let patch = try #require(patcher.patches.first)
        #expect(patch.fileOffset == textStart + Self.guardOffset)
    }

    @Test func `the guard type is matched exactly`() {
        let disasm = ARM64Disassembler()
        func decode(_ word: UInt32) -> ARM64Instruction? {
            withUnsafeBytes(of: word.littleEndian) { disasm.disassembleOne(Data($0), at: 0) }
        }
        #expect(decode(0xF2E4_0009).map(KernelPatcher.setsMachPortGuardType) == true) // movk x9, #0x2000, lsl #48
        #expect(decode(0xF2FA_A0F1).map(KernelPatcher.setsMachPortGuardType) == false) // movk x17, #0xd507, lsl #48
        #expect(decode(0xF2C4_0009).map(KernelPatcher.setsMachPortGuardType) == false) // movk x9, #0x2000, lsl #32
    }

    // MARK: - The real kernel

    /// Gated on `VPHONE_VP600_KERNEL`, a machine-local kernelcache.*.vphone600
    /// (IM4P or raw). The patched function must be the one that raises
    /// AST_GUARD (0x1000) on the thread, as thread_guard_violation does.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["VPHONE_VP600_KERNEL"] != nil,
        "VPHONE_VP600_KERNEL is not set; point it at a kernelcache.*.vphone600 to run",
    ))
    func `patches thread_guard_violation in a real vphone600 kernel`() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_VP600_KERNEL"])
        let (payload, _) = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path))
        let patcher = Self.patcher(payload)

        #expect(patcher.patchExcGuardBehavior())
        let patch = try #require(patcher.patches.first { $0.patchID == "kernel-boot-thread_guard_violation" })
        let body = ARM64Disassembler().disassemble(in: payload, at: patch.fileOffset, count: 64)
        let setsASTGuard = body.contains { insn in
            guard insn.mnemonic == "mov", let ops = insn.detail?.operands, ops.count == 2 else { return false }
            return ops[1].type == .immediate && ops[1].imm == 0x1000
        } && body.contains { $0.mnemonic.hasPrefix("ldset") }
        #expect(setsASTGuard)
    }
}
