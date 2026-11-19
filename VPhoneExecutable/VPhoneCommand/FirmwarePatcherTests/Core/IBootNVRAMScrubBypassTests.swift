@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// LLB's "upgrade" way around its NVRAM scrub, on a fragment shaped like
/// cloudOS 27.2 (24B115) `LLB.vresearch101.RELEASE`: the keep list's
/// stress-rack entry at 0x57C8 and the upgrade test at 0x5BFC.
@Suite("LLB NVRAM scrub bypass")
struct IBootNVRAMScrubBypassTests {
    /// Little-endian words, each checked against Capstone:
    ///
    ///     0x1000  adrp x8, #0x2000
    ///     0x1004  add  x8, x8, #0x10      ; "stress-rack" at 0x2010
    ///     0x1008  stp  xzr, xzr, [sp, #0x170]
    ///     0x100c  stp  x8, x8, [sp, #0x180]
    ///     0x1010  add  x8, x8, #0xc
    ///     0x1014  stp  x8, x3, [sp, #0x190]
    ///     ...
    ///     0x1100  cbz  x0, #0x1124        ; no boot-command: scrub
    ///     0x1104  adrp x4, #0x2000
    ///     0x1108  add  x4, x4, #0x100     ; "upgrade" at 0x2100
    ///     0x110c  nop                     ; the compare call's arguments and call
    ///     ...
    ///     0x1120  cbz  w0, #0x1200        ; "upgrade": skip the scrub
    ///     0x1124                          ; the scrub
    ///
    /// With `tableCopy`, a second "stress-rack" at 0x2000 comes first, loaded
    /// at 0x3800 (`adrp x9, #0x2000 ; add x9, x9, #0`) far from any test.
    static func image(keepList: Bool = true, scrubAfterTest: Bool = true, tableCopy: Bool = false) -> Data {
        var data = Data(count: 0x4000)
        func put(_ words: [UInt32], at offset: Int) {
            for (index, word) in words.enumerated() {
                withUnsafeBytes(of: word.littleEndian) { data.replaceSubrange(offset + index * 4 ..< offset + index * 4 + 4, with: $0) }
            }
        }
        if keepList {
            put([0xB000_0008, 0x9100_4108, 0xA917_7FFF, 0xA918_23E8, 0x9100_3108, 0xA919_0FE8], at: 0x1000)
        }
        let nop: UInt32 = 0xD503_201F
        let firstTest: UInt32 = scrubAfterTest ? 0xB400_0120 : 0xB400_0140 // cbz x0, #0x1124 / #0x1128
        put([firstTest, 0xB000_0004, 0x9104_0084, nop, nop, nop, nop, nop, 0x3400_0700], at: 0x1100)
        if tableCopy {
            put([0xF0FF_FFE9, 0x9100_0129], at: 0x3800)
            let bytes = Data("stress-rack".utf8) + Data([0])
            data.replaceSubrange(0x2000 ..< 0x2000 + bytes.count, with: bytes)
        }
        for (offset, text) in [(0x2010, "stress-rack"), (0x2100, "upgrade")] {
            let bytes = Data(text.utf8) + Data([0])
            data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
        return data
    }

    @Test func `every boot takes the upgrade path`() throws {
        let patcher = IBootPatcher(data: Self.image(), mode: .llb, verbose: false)
        patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.map(\.patchID) == ["llb-exp-nvram_scrub_bypass"])
        #expect(patcher.patches.map(\.fileOffset) == [0x1100])
        #expect(patcher.patches.map(\.patchedBytes) == [try #require(ARM64Encoder.encodeB(from: 0x1100, to: 0x1200))])
    }

    @Test func `a referenced table copy of the name does not hide the keep list`() {
        let patcher = IBootPatcher(data: Self.image(tableCopy: true), mode: .llb, verbose: false)
        patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.map(\.fileOffset) == [0x1100])
    }

    @Test func `an upgrade test without a keep list is left alone`() {
        let patcher = IBootPatcher(data: Self.image(keepList: false), mode: .llb, verbose: false)
        patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.isEmpty)
    }

    @Test func `a test whose miss does not fall into the scrub is left alone`() {
        let patcher = IBootPatcher(data: Self.image(scrubAfterTest: false), mode: .llb, verbose: false)
        patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.isEmpty)
    }

    @Test func `minimal and watchos keep the patch`() {
        #expect(FirmwareBootChainPatchSet.manifest.patches.map(\.identifier).contains("llb-exp-nvram_scrub_bypass"))
        #expect(FirmwarePatchSetCatalog.minimalBootChainPatches.contains("llb-exp-nvram_scrub_bypass"))
    }
}
