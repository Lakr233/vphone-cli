@testable import FirmwarePatcher
import Foundation
import Testing

struct TXMGlobalCodeSignBypassTests {
    @Test func patchesUniquePageEnforcementLoop() throws {
        let fixture = makeTXMPageEnforcementFixture()
        let patcher = TXMDevPatcher(data: fixture.data, verbose: false)

        try patcher.patchPageEnforcementGlobalBypass()

        let record = try #require(patcher.patches.last)
        #expect(record.patchID == "txm_jb.page_enforcement_global_bypass")
        #expect(record.fileOffset == fixture.patchOffset)
        #expect(record.originalBytes == Data([0x69, 0x0A, 0x00, 0x35]))
        #expect(record.patchedBytes == ARM64.nop)
        #expect(record.beforeDisasm.hasPrefix("cbnz w9,"))
        #expect(record.afterDisasm == "nop ")
    }

    @Test func rejectsMissingPageEnforcementString() {
        let fixture = makeTXMPageEnforcementFixture(includeAnchor: false)
        let patcher = TXMDevPatcher(data: fixture.data, verbose: false)

        let error = caughtPatcherError {
            try patcher.patchPageEnforcementGlobalBypass()
        }
        #expect(error == "not-found")
    }

    @Test func rejectsNearMissWithWrongErrorRegister() {
        var fixture = makeTXMPageEnforcementFixture()
        fixture.data.writeU32ForTest(at: fixture.patchOffset, value: 0x3500_0A68) // cbnz w8, error
        let patcher = TXMDevPatcher(data: fixture.data, verbose: false)

        let error = caughtPatcherError {
            try patcher.patchPageEnforcementGlobalBypass()
        }
        #expect(error == "not-found")
    }

    @Test func rejectsMultiplePageEnforcementLoops() {
        let fixture = makeTXMPageEnforcementFixture(secondCandidate: true)
        let patcher = TXMDevPatcher(data: fixture.data, verbose: false)

        let error = caughtPatcherError {
            try patcher.patchPageEnforcementGlobalBypass()
        }
        #expect(error == "multiple:2")
    }

    @Test func ignoresMatchingLoopOutsideAnchoredFunction() throws {
        let fixture = makeTXMPageEnforcementFixture(unrelatedCandidate: true)
        let patcher = TXMDevPatcher(data: fixture.data, verbose: false)

        try patcher.patchPageEnforcementGlobalBypass()

        #expect(patcher.patches.count == 1)
        #expect(patcher.patches[0].fileOffset == fixture.patchOffset)
    }
}

private struct TXMPageEnforcementFixture {
    var data: Data
    let patchOffset: Int
}

private func makeTXMPageEnforcementFixture(
    includeAnchor: Bool = true,
    secondCandidate: Bool = false,
    unrelatedCandidate: Bool = false
) -> TXMPageEnforcementFixture {
    var data = Data(repeating: 0, count: 0x1000)
    let functionStart = 0x100
    let firstCandidate = 0x200
    let anchorReference = 0x400
    let stringOffset = 0x900

    data.replaceSubrange(functionStart ..< functionStart + 4, with: ARM64.pacibsp)
    writePageEnforcementLoop(to: &data, at: firstCandidate)
    if secondCandidate {
        writePageEnforcementLoop(to: &data, at: 0x280)
    }

    if includeAnchor {
        let anchor = Data("page enforcement failed (%u | %u): (%p | %u) --> %u | 0x%016llX\0".utf8)
        data.replaceSubrange(stringOffset ..< stringOffset + anchor.count, with: anchor)
        data.replaceSubrange(
            anchorReference ..< anchorReference + 4,
            with: ARM64Encoder.encodeADRP(rd: 0, pc: UInt64(anchorReference), target: UInt64(stringOffset))!
        )
        data.replaceSubrange(
            anchorReference + 4 ..< anchorReference + 8,
            with: ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: UInt32(stringOffset & 0xFFF))!
        )
    }

    data.replaceSubrange(0x500 ..< 0x504, with: ARM64.pacibsp)
    if unrelatedCandidate {
        data.replaceSubrange(0x600 ..< 0x604, with: ARM64.pacibsp)
        writePageEnforcementLoop(to: &data, at: 0x680)
        data.replaceSubrange(0x880 ..< 0x884, with: ARM64.pacibsp)
    }
    return TXMPageEnforcementFixture(data: data, patchOffset: firstCandidate + 16)
}

private func writePageEnforcementLoop(to data: inout Data, at offset: Int) {
    let words: [UInt32] = [
        0x9400_0000, // bl helper
        0x2A00_03E1, // mov w1, w0
        0xD348_FC28, // lsr x8, x1, #8
        0xD348_3C29, // ubfx x9, x1, #8, #8
        0x3500_0A69, // cbnz w9, error
        0xB940_57E4, // ldr w4, [sp, #0x54]
        0x8B04_02F7, // add x23, x23, x4
        0x1100_075A, // add w26, w26, #1
        0xB940_3FE9, // ldr w9, [sp, #0x3c]
        0x6B09_035F, // cmp w26, w9
        0xAA19_03E9, // mov x9, x25
        0x54FF_FD63, // b.lo loop body
    ]
    for (index, word) in words.enumerated() {
        data.writeU32ForTest(at: offset + index * 4, value: word)
    }
}

private extension Data {
    mutating func writeU32ForTest(at offset: Int, value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { bytes in
            replaceSubrange(offset ..< offset + 4, with: bytes)
        }
    }
}

private func caughtPatcherError(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "none"
    } catch let error as PatcherError {
        return switch error {
        case .patchSiteNotFound:
            "not-found"
        case let .multipleMatchesFound(_, count):
            "multiple:\(count)"
        default:
            "other"
        }
    } catch {
        return "wrong-type"
    }
}
