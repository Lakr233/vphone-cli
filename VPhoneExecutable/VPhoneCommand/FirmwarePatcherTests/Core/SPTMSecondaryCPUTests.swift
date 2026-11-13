@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// The secondary CPU tunable in cloudOS 18's SPTM, on the instruction words of
/// its reset path and, when an IPSW in `ipsws/` carries one, on Apple's image.
@Suite("SPTM secondary CPU patch")
struct SPTMSecondaryCPUTests {
    // MARK: - Fixture

    /// The reset path of cloudOS 18.5's SPTM (22F76, `sptm.vresearch1.release`),
    /// from `mrs x6, MIDR_EL1` to the first instruction after the tunable.
    static let resetPath: [UInt32] = [
        0xD538_0006, // mrs  x6, MIDR_EL1
        0x927C_2CC2, // and  x2, x6, #0xfff0
        0xF100_005F, // cmp  x2, #0
        0x5400_0040, // b.eq apply
        0x1400_000C, // b    skip
        0xF946_4822, // ldr  x2, [x1, #0xc90]
        0xF2E0_0003, // movk x3, #0, lsl #48
        0xF2C0_0003, // movk x3, #0, lsl #32
        0xF2A0_0003, // movk x3, #0, lsl #16
        0xF280_4303, // movk x3, #0x218
        0xF863_6844, // ldr  x4, [x2, x3]
        0x9240_DC84, // and  x4, x4, #0xffffffffffffff
        0xD280_1645, // mov  x5, #0xb2
        0xD348_1CA5, // lsl  x5, x5, #56
        0xAA05_0084, // orr  x4, x4, x5
        0xF823_6844, // str  x4, [x2, x3]
        0xB0FF_FF74, // adrp x20, ...
    ]

    static let branchIndex = 3
    static let textAddress: UInt64 = 0xFFFF_FFF0_2707_4000
    static let textOffset = 0x4000

    static func code(_ words: [UInt32], padding: Int = 4) -> Data {
        var data = Data()
        for _ in 0 ..< padding {
            data.append(ARM64.nop)
        }
        for word in words {
            data.append(ARM64.encodeU32(word))
        }
        for _ in 0 ..< padding {
            data.append(ARM64.nop)
        }
        return data
    }

    /// A Mach-O with one segment and section, `__TEXT_EXEC,__text`, holding `code`.
    static func image(code: Data) -> Data {
        func name(_ text: String) -> Data {
            var bytes = Data(text.utf8)
            bytes.append(Data(count: 16 - bytes.count))
            return bytes
        }
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func u64(_ value: UInt64) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var data = Data()
        // mach_header_64: arm64e executable, one load command of 152 bytes.
        for value: UInt32 in [0xFEED_FACF, 0x0100_000C, 2, 2, 1, 152, 0, 0] {
            data.append(u32(value))
        }
        // LC_SEGMENT_64 with one section.
        data.append(u32(0x19))
        data.append(u32(152))
        data.append(name("__TEXT_EXEC"))
        data.append(u64(textAddress))
        data.append(u64(UInt64(code.count)))
        data.append(u64(UInt64(textOffset)))
        data.append(u64(UInt64(code.count)))
        for value: UInt32 in [5, 5, 1, 0] {
            data.append(u32(value))
        }
        data.append(name("__text"))
        data.append(name("__TEXT_EXEC"))
        data.append(u64(textAddress))
        data.append(u64(UInt64(code.count)))
        data.append(u32(UInt32(textOffset)))
        for value: UInt32 in [2, 0, 0, 0x8000_0400, 0, 0, 0] {
            data.append(u32(value))
        }
        data.append(Data(count: textOffset - data.count))
        data.append(code)
        return data
    }

    // MARK: - Matching

    @Test("The branch into the tunable is found on decoded operands")
    func findsBranch() {
        let instructions = ARM64Disassembler().disassemble(Self.code(Self.resetPath), at: Self.textAddress)
        let expected = Self.textAddress + UInt64((4 + Self.branchIndex) * 4)
        #expect(SPTMSecondaryCPUPatcher.tunableBranches(in: instructions) == [expected])
    }

    @Test("A reset path without the indexed read and write back is left alone")
    func ignoresOtherMIDRChecks() {
        var words = Self.resetPath
        // The same MIDR check guarding a block that touches no register.
        for index in 5 ..< 16 {
            words[index] = 0xD503_201F
        }
        let instructions = ARM64Disassembler().disassemble(Self.code(words), at: Self.textAddress)
        #expect(SPTMSecondaryCPUPatcher.tunableBranches(in: instructions).isEmpty)
    }

    // MARK: - Patching

    @Test("The branch becomes a nop, once")
    func patchesBranch() throws {
        let image = Self.image(code: Self.code(Self.resetPath))
        let patcher = SPTMSecondaryCPUPatcher(data: image, verbose: false)
        let records = try patcher.findAll()
        let offset = Self.textOffset + (4 + Self.branchIndex) * 4
        #expect(records.map(\.patchID) == [SPTMSecondaryCPUPatcher.patchIdentifier])
        #expect(records.first?.fileOffset == offset)
        #expect(records.first?.originalBytes == ARM64.encodeU32(Self.resetPath[Self.branchIndex]))
        #expect(try patcher.apply() == 1)

        var expected = image
        expected.replaceSubrange(offset ..< offset + 4, with: ARM64.nop)
        #expect(patcher.patchedData == expected)
        // Patched before, or an SPTM without the tunable: nothing to write.
        #expect(try SPTMSecondaryCPUPatcher(data: patcher.patchedData, verbose: false).findAll().isEmpty)
    }

    @Test("A blocked patch writes nothing")
    func respectsGate() throws {
        let image = Self.image(code: Self.code(Self.resetPath))
        let patcher = SPTMSecondaryCPUPatcher(data: image, verbose: false)
        patcher.gate = VPhonePatchGate(declared: [SPTMSecondaryCPUPatcher.patchIdentifier], enabled: [])
        #expect(try patcher.apply() == 0)
        #expect(patcher.patchedData == image)
    }

    // MARK: - Apple's Images

    static let entry = "Firmware/sptm.vresearch1.release.im4p"

    static var ipsws: [URL] {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: CustomFirmwarePatchFixtures.repoRoot.appending(path: "ipsws"),
            includingPropertiesForKeys: nil,
        )) ?? []
        return candidates.filter { candidate in
            guard candidate.pathExtension == "ipsw" else { return false }
            let listing = (try? CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-l", candidate.path, entry]))?.output ?? ""
            return listing.contains(entry)
        }
    }

    @Test(
        "Apple's cloudOS 18 SPTM takes the patch once, and later ones none",
        .enabled(if: !ipsws.isEmpty, "needs a cloudOS IPSW in ipsws/"),
    )
    func patchesAppleImages() throws {
        for ipsw in Self.ipsws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-o", "-j", ipsw.path, Self.entry, "-d", directory.path])
            try #require(result.status == 0)
            let url = directory.appending(path: "sptm.vresearch1.release.im4p")
            let (payload, container) = try IM4PHandler.load(contentsOf: url)

            let patcher = SPTMSecondaryCPUPatcher(data: payload, verbose: false)
            let records = try patcher.findAll()
            // cloudOS 18 carries the tunable; later releases do not.
            let manifest = try CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-p", ipsw.path, "BuildManifest.plist"]).output
            let plist = try PropertyListSerialization.propertyList(from: Data(manifest.utf8), format: nil) as? [String: Any]
            let version = try #require(plist?["ProductVersion"] as? String)
            #expect(records.count == (version.hasPrefix("18.") ? 1 : 0), "\(ipsw.lastPathComponent) (\(version))")
            try patcher.apply()
            #expect(try SPTMSecondaryCPUPatcher(data: patcher.patchedData, verbose: false).findAll().isEmpty)

            let saved = directory.appending(path: "saved.im4p")
            try IM4PHandler.save(patchedData: patcher.patchedData, originalIM4P: container, to: saved)
            #expect(try IM4PHandler.load(contentsOf: saved).payload == patcher.patchedData)
            // iBoot panics on an SPTM without its PAYP segment properties.
            let original = try Data(contentsOf: url)
            let rebuilt = try Data(contentsOf: saved)
            let originalTail = original[try #require(IM4PHandler.paypStart(in: original))...]
            let rebuiltTail = rebuilt[try #require(IM4PHandler.paypStart(in: rebuilt))...]
            #expect(originalTail == rebuiltTail, "\(ipsw.lastPathComponent)")
        }
    }
}
