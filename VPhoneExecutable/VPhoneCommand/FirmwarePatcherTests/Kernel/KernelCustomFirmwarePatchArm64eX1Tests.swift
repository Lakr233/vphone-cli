@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("kernel-boot-arm64e_x1")
struct KernelCustomFirmwarePatchArm64eX1Tests {
    // vphone600 UUID 784F88D3-2AF5-3D4A-AB00-365607646E44 instruction fixtures.
    static let grade = Data(base64Encoded: "iNA41QjNQPkICUC5qQGAUh8FAHEpAZ8aHwQIcigBiBqJAYBSCUCgch8ACWsAAgBUiQGAUgkgoHIfAAlroQMAVB8JAHEgAgBUHwUAcSEDAFQoAYBSPwAAcQgBnxpJAYBSPwQAcSABiBrAA1/WPwQAcQECAFQIBQBRHwkAcaIBAFQAAYBSwANf1sEBADQ/BABxQAEAVD8IAHHBAABUXwwIcmgBgFIIFYgaAH2CCsADX9YAAIBSwANf1kABgFLAA1/WIAGAUsADX9Y=")!
    static let exec = Data(base64Encoded: "MQgGlOkDAKoJAgA0CAdAuYkBgFIJQKByHwEJayABAFSJAYBSCSCgch8BCWshAQBUCAtAuQhtABIfCQBxoQAAVIh6ABIEAAAUwAqAUjABABSIAgEyaEoAuQ==")!
    static let shared = Data(base64Encoded: "qM5FuQhtABIfCQBxYQMAVGhKQLkoA/g36JNDOSgXGDdgmkH5AB0AtLbN65f5AwCqwC//8ABAMJEfIAPVwC//8ADAMJEhBwCRAgCQUgMAgNIAS+2X+AMAqmGaQfkiBwCRvLbrl2hKQLkaMQxTWQCAUvgBALUEAAAUGQCAUmhKQLkaMQxT")!

    static func fixture(duplicateExec: Bool = false, cave: Bool = true) throws -> (KernelCustomFirmwarePatcher, Int, Int) {
        var block = grade + Data(repeating: 0xD4, count: 32)
        let execRelative = block.count
        block += exec
        if duplicateExec { block += Data(repeating: 0xD4, count: 32) + exec }
        block += Data(repeating: 0xD4, count: 0x300 - block.count)
        block += shared
        block += Data(repeating: 0xD4, count: 0x100)
        if cave { block += Data(repeating: 0, count: 64) }
        var (image, gradeOffset) = KernelCustomFirmwarePatchSharedRegionSizeTests.kernel(withBlock: Array(block))
        let execOffset = gradeOffset + execRelative
        image.replaceSubrange(execOffset ..< execOffset + 4, with: try #require(ARM64Encoder.encodeBL(from: execOffset, to: gradeOffset)))
        if duplicateExec {
            let other = execOffset + exec.count + 32
            image.replaceSubrange(other ..< other + 4, with: try #require(ARM64Encoder.encodeBL(from: other, to: gradeOffset)))
        }
        let patcher = KernelCustomFirmwarePatcher(data: image, verbose: false)
        patcher.parseMachO()
        patcher.buildBLIndex()
        return (patcher, gradeOffset, execOffset)
    }

    @Test func `widens only the grade and exec subtype comparisons`() throws {
        let (patcher, grade, exec) = try Self.fixture()
        #expect(patcher.patchArm64eX1Admission())
        #expect(patcher.patches.count == 6)
        let compares = [grade + 0x94, exec + 0x38, grade + 0x308]
        let decoder = ARM64Disassembler()
        for (offset, register) in zip(compares, [ARM64Register.w(1), .w(8), .w(8)]) {
            let branch = try #require(decoder.disassembleOne(in: patcher.patchedData, at: offset))
            #expect(branch.mnemonic == "b")
            let target = try #require(branch.detail?.operands.first?.imm)
            let trampoline = decoder.disassemble(in: patcher.patchedData, at: Int(target), count: 3)
            #expect(trampoline.map(\.mnemonic) == ["cmp", "ccmp", "b"])
            #expect(trampoline[0].detail?.operands.first?.reg == register)
            #expect(trampoline[0].detail?.operands.last?.imm == 12)
            #expect(trampoline[1].detail?.operands.first?.reg == register)
            #expect(trampoline[1].detail?.operands[1].imm == 2)
            #expect(trampoline[1].detail?.operands[2].imm == 6)
            #expect(trampoline[2].detail?.operands.first?.imm == Int64(offset + 4))
            #expect(patcher.patchedData[(offset + 4) ..< (offset + 20)] == patcher.buffer.original[(offset + 4) ..< (offset + 20)])
        }
        let written = Set(patcher.patches.flatMap { $0.fileOffset ..< $0.fileOffset + $0.patchedBytes.count })
        for position in patcher.patchedData.indices where !written.contains(position) {
            #expect(patcher.patchedData[position] == patcher.buffer.original[position])
        }
    }

    @Test func `ambiguous exec and missing cave leave the entire kernel unchanged`() throws {
        for (duplicate, cave) in [(true, true), (false, false)] {
            let (patcher, _, _) = try Self.fixture(duplicateExec: duplicate, cave: cave)
            #expect(!patcher.patchArm64eX1Admission())
            #expect(patcher.patches.isEmpty)
            #expect(patcher.patchedData == patcher.buffer.original)
        }
    }

    @Test func `rejects changed PAC ABI and flags paths before writing`() throws {
        let (original, grade, exec) = try Self.fixture()
        for offset in [grade + 0x9C, exec + 0x54, grade + 0x36C] {
            var image = original.buffer.original
            image.replaceSubrange(offset ..< offset + 4, with: ARM64.nop)
            let patcher = KernelCustomFirmwarePatcher(data: image, verbose: false)
            patcher.parseMachO()
            patcher.buildBLIndex()
            #expect(!patcher.patchArm64eX1Admission())
            #expect(patcher.patches.isEmpty)
            #expect(patcher.patchedData == image)
        }
    }

    @Test func `does not patch an already widened kernel again`() throws {
        let (original, _, _) = try Self.fixture()
        #expect(original.patchArm64eX1Admission())
        let patcher = KernelCustomFirmwarePatcher(data: original.patchedData, verbose: false)
        patcher.parseMachO()
        patcher.buildBLIndex()
        #expect(!patcher.patchArm64eX1Admission())
        #expect(patcher.patches.isEmpty)
    }

    @Test func `standard enables the complete X1 path only for its iOS gate`() throws {
        let identifiers = [
            "kernel-boot-arm64e_x1",
            FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining,
            FirmwareGuestSystemPatchSet.arm64eX1LaunchdBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1FsckBootstrap,
            FirmwareGuestSystemPatchSet.arm64eX1MountBootstrap,
        ]
        for base in ["26.4", "27.0.1", "28.0"] {
            let standard = try VPhonePatchPlan.resolve(preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled, iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"))
            for identifier in identifiers {
                #expect(standard.isEnabled(identifier) == base.hasPrefix("27."))
            }
        }
    }
}
