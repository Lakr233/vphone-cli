@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// LLB's "upgrade" way around its NVRAM scrub, on a fragment shaped like
/// cloudOS 27.2 (24B115) `LLB.vresearch101.RELEASE`.
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
    ///     0x10f0  adrp x0, #0x2000
    ///     0x10f4  add  x0, x0, #0x200     ; "boot-command" at 0x2200
    ///     0x10f8  nop
    ///     0x10fc  bl   #0x3000            ; the lookup
    ///     0x1100  cbz  x0, #0x1124        ; no boot-command: scrub
    ///     0x1104  adrp x4, #0x2000
    ///     0x1108  add  x4, x4, #0x100     ; "upgrade" at 0x2100
    ///     0x110c  nop                     ; the compare's other arguments
    ///     ...
    ///     0x111c  bl   #0x3000            ; the compare
    ///     0x1120  cbz  w0, #0x1200        ; "upgrade": skip the scrub
    ///     0x1124                          ; the scrub
    ///
    /// `secondSite` repeats the keep list at 0x1700 and the test at 0x1800.
    /// With `tableCopy`, a second "stress-rack" at 0x2000 comes first, loaded
    /// at 0x3800 (`adrp x9, #0x2000 ; add x9, x9, #0`) far from any test.
    struct Shape {
        var keepList = true
        var scrubAfterTest = true
        var tableCopy = false
        var secondSite = false
        /// The register the first `cbz` tests; the lookup returns x0.
        var testedRegister: UInt32 = 0
        /// The lookup: `bl` (0x94…) or `blr x8`.
        var lookupIsCall = true
        /// The name the lookup is given.
        var lookupName = "boot-command"
    }

    static func image(_ shape: Shape = Shape()) -> Data {
        var data = Data(count: 0x4000)
        func put(_ words: [UInt32], at offset: Int) {
            for (index, word) in words.enumerated() {
                withUnsafeBytes(of: word.littleEndian) { data.replaceSubrange(offset + index * 4 ..< offset + index * 4 + 4, with: $0) }
            }
        }
        func string(_ text: String, at offset: Int) {
            let bytes = Data(text.utf8) + Data([0])
            data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        }
        let nop: UInt32 = 0xD503_201F
        let keepList: [UInt32] = [0xB000_0008, 0x9100_4108, 0xA917_7FFF, 0xA918_23E8, 0x9100_3108, 0xA919_0FE8]
        // cbz xN, #+0x24 / #+0x28: the scrub right after the second test, or not.
        let firstTest: UInt32 = (shape.scrubAfterTest ? 0xB400_0120 : 0xB400_0140) | shape.testedRegister
        let blrX8: UInt32 = 0xD63F_0100
        func site(lookup: UInt32, compare: UInt32) -> [UInt32] {
            [0xB000_0000, 0x9108_0000, nop, shape.lookupIsCall ? lookup : blrX8,
             firstTest, 0xB000_0004, 0x9104_0084, nop, nop, nop, nop, compare, 0x3400_0700]
        }
        if shape.keepList {
            put(keepList, at: 0x1000)
        }
        // bl #0x3000 from 0x10fc and from 0x111c.
        put(site(lookup: 0x9400_07C1, compare: 0x9400_07B9), at: 0x10F0)
        if shape.secondSite {
            put(keepList, at: 0x1700)
            // bl #0x3000 from 0x17fc and from 0x181c.
            put(site(lookup: 0x9400_0601, compare: 0x9400_05F9), at: 0x17F0)
        }
        if shape.tableCopy {
            put([0xF0FF_FFE9, 0x9100_0129], at: 0x3800)
            string("stress-rack", at: 0x2000)
        }
        string("stress-rack", at: 0x2010)
        string("upgrade", at: 0x2100)
        string(shape.lookupName, at: 0x2200)
        return data
    }

    static func patcher(_ shape: Shape = Shape(), selected: Bool = true) -> IBootPatcher {
        let patcher = IBootPatcher(data: image(shape), mode: .llb, verbose: false)
        patcher.gate = VPhonePatchGate(declared: ["llb-exp-nvram_scrub_bypass"], enabled: selected ? ["llb-exp-nvram_scrub_bypass"] : [])
        return patcher
    }

    @Test func `every boot takes the upgrade path`() throws {
        let patcher = Self.patcher()
        try patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.map(\.patchID) == ["llb-exp-nvram_scrub_bypass"])
        #expect(patcher.patches.map(\.fileOffset) == [0x1100])
        #expect(patcher.patches.map(\.patchedBytes) == [try #require(ARM64Encoder.encodeB(from: 0x1100, to: 0x1200))])
    }

    @Test func `a referenced table copy of the name does not hide the keep list`() throws {
        let patcher = Self.patcher(Shape(tableCopy: true))
        try patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.map(\.fileOffset) == [0x1100])
    }

    @Test func `a second site is refused`() {
        let patcher = Self.patcher(Shape(secondSite: true))
        #expect(patcher.nvramScrubUpgradeTests().map(\.test) == [0x1100, 0x1800])
        #expect(throws: IBootPatcher.NVRAMScrubBypassMiss.self) { try patcher.patchNVRAMScrubBypass() }
        #expect(patcher.patches.isEmpty)
    }

    @Test(arguments: [
        Shape(keepList: false),
        Shape(scrubAfterTest: false),
        Shape(testedRegister: 1),
        Shape(lookupIsCall: false),
        Shape(lookupName: "boot-volume"),
    ])
    func `a selected patch without its site fails`(shape: Shape) {
        let patcher = Self.patcher(shape)
        #expect(patcher.nvramScrubUpgradeTests().isEmpty)
        #expect(throws: IBootPatcher.NVRAMScrubBypassMiss.self) { try patcher.patchNVRAMScrubBypass() }
        #expect(patcher.patches.isEmpty)
    }

    @Test func `an unselected patch without its site is only logged`() throws {
        let patcher = Self.patcher(Shape(keepList: false), selected: false)
        try patcher.patchNVRAMScrubBypass()
        #expect(patcher.patches.isEmpty)
    }

    @Test func `findAll fails a selected patch's miss`() {
        let patcher = Self.patcher(Shape(keepList: false))
        #expect(throws: IBootPatcher.NVRAMScrubBypassMiss.self) { try patcher.findAll() }
    }

    /// Every `*.bin` in `LLB_SCRUB_DIR` (unwrapped `LLB.vresearch101.*.im4p`
    /// payloads) has exactly one site.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LLB_SCRUB_DIR"] != nil))
    func `every real LLB has one site`() throws {
        let folder = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["LLB_SCRUB_DIR"]))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!files.isEmpty)
        for file in files {
            let patcher = IBootPatcher(data: try Data(contentsOf: file), mode: .llb, verbose: false)
            let sites = patcher.nvramScrubUpgradeTests()
            print("\(file.lastPathComponent): " + sites.map { String(format: "test 0x%X done 0x%X", $0.test, $0.done) }.joined(separator: ", "))
            #expect(sites.count == 1, "\(file.lastPathComponent)")
        }
    }

    @Test func `minimal and watchos take the patch`() {
        let id = "llb-exp-nvram_scrub_bypass"
        #expect(FirmwareBootChainPatchSet.manifest.patches.map(\.identifier).contains(id))
        #expect(FirmwarePatchSetCatalog.keptNVRAMPatches == [id])
        #expect(!FirmwarePatchSetCatalog.minimalBootChainPatches.contains(id))
        #expect(FirmwarePatchSetCatalog.minimalPreset.selection.namedIdentifiers.contains(id))
        #expect(FirmwarePatchSetCatalog.watchOSPreset.selection.namedIdentifiers.contains(id))
    }
}
