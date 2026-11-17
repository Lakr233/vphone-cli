@testable import FirmwarePatcher
import CryptoKit
import Foundation
import Testing
import VPhonePatchKit

/// The research board's SEPD dispatch, against Apple's SEP images when an IPSW
/// in `ipsws/` carries both boards', and the `PAYP` tail a rebuilt SEP keeps.
@Suite("SEP research board patch")
struct SEPResearchBoardTests {
    // MARK: - PAYP

    /// A container ending in a `PAYP` element; a long tail makes its DER
    /// lengths take two bytes.
    static func container(tailLength: Int) -> Data {
        let properties = Data([0x16, 0x04]) + Data("PAYP".utf8) + Data(repeating: 0x31, count: tailLength)
        func element(_ tag: UInt8, _ body: Data) -> Data {
            let count = body.count
            let length = count < 0x80 ? Data([UInt8(count)]) : Data([0x82, UInt8(count >> 8), UInt8(count & 0xFF)])
            return Data([tag]) + length + body
        }
        return Data(repeating: 0xAA, count: 32) + element(0xA0, element(0x30, properties))
    }

    @Test("The PAYP element is found by its DER length, with short or long lengths")
    func findsPAYPStart() {
        #expect(IM4PHandler.paypStart(in: Self.container(tailLength: 20)) == 32)
        #expect(IM4PHandler.paypStart(in: Self.container(tailLength: 300)) == 32)
        #expect(IM4PHandler.paypStart(in: Data(repeating: 0xAA, count: 32) + Data("PAYP".utf8)) == nil)
    }

    // MARK: - App Entries

    /// A root argument object whose SEPD entry puts its part offsets `distance`
    /// bytes before the name, with a Mach-O first part.
    static func rootObject(distance: Int) -> Data {
        var image = Data(count: 0x3000)
        image.replaceSubrange(0x100 ..< 0x111, with: Data("Built by legion2P".utf8))
        let name = 0x400
        image.replaceSubrange(name ..< name + 4, with: Data("SEPD".utf8))
        for (slot, value) in [0x1000, 0x800, 0x2000, 0x400].enumerated() {
            withUnsafeBytes(of: UInt64(value).littleEndian) { image.replaceSubrange(name - distance + slot * 8 ..< name - distance + slot * 8 + 8, with: $0) }
        }
        withUnsafeBytes(of: SEPResearchBoardPatcher.machOMagic64.littleEndian) { image.replaceSubrange(0x1000 ..< 0x1004, with: $0) }
        return image
    }

    @Test("An app's parts are found with the entry layout before and from cloudOS 27", arguments: SEPResearchBoardPatcher.entryDistances)
    func findsApplicationParts(distance: Int) throws {
        let app = try SEPResearchBoardPatcher.application(named: "SEPD", in: Self.rootObject(distance: distance))
        #expect(app.part1 == 0x1000 ..< 0x1800)
        #expect(app.part2 == 0x2000 ..< 0x2400)
    }

    @Test("An entry without a Mach-O first part is refused")
    func refusesEntryWithoutMachO() {
        #expect(throws: PatcherError.self) {
            try SEPResearchBoardPatcher.application(named: "SEPD", in: Self.rootObject(distance: 0x70))
        }
    }

    /// A research board SEP payload (decoded IM4P), e.g. cloudOS 27.2's, which
    /// has no vphone600 SEP beside it. Xcode passes TEST_RUNNER_SEP_RESEARCH_PAYLOAD
    /// to the test process as SEP_RESEARCH_PAYLOAD.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEP_RESEARCH_PAYLOAD"] != nil))
    func patchesResearchPayload() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEP_RESEARCH_PAYLOAD"])
        let research = try Data(contentsOf: URL(fileURLWithPath: path))
        let shared = try Self.inspect(research, operation: SEPResearchBoardPatcher.sharedOperation)
        let patcher = SEPResearchBoardPatcher(data: research, verbose: false)
        _ = try patcher.findAll()
        try patcher.apply()
        let after = try Self.inspect(patcher.patchedData, operation: SEPResearchBoardPatcher.redirectedOperation)
        #expect(after.entry == shared.entry)
        #expect(after.hmacValid != false)
    }

    // MARK: - Apple's Images

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let researchEntry = "Firmware/all_flash/sep-firmware.vresearch101.RELEASE.im4p"
    static let vphoneEntry = "Firmware/all_flash/sep-firmware.vphone600.RELEASE.im4p"

    static var pairedIPSWs: [URL] {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: repoRoot.appending(path: "ipsws"),
            includingPropertiesForKeys: nil,
        )) ?? []
        return candidates.filter { candidate in
            guard candidate.pathExtension == "ipsw" else { return false }
            let listing = (try? CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-l", candidate.path, researchEntry, vphoneEntry]))?.output ?? ""
            return listing.contains(researchEntry) && listing.contains(vphoneEntry)
        }
    }

    /// SEPD's dispatch entry for `operation`, and whether its stored FIPS HMAC
    /// is the one of its `__text` (nil before cloudOS 26.4, whose SEPD has none).
    static func inspect(_ image: Data, operation: Int) throws -> (entry: Data, hmacValid: Bool?) {
        let image = Data(image)
        let app = try SEPResearchBoardPatcher.application(named: "SEPD", in: image)
        let sepd = Data(image[app.part1]) + Data(image[app.part2])
        let sections = MachOParser.parseSections(from: sepd)
        let text = try #require(sections["__TEXT,__text"])
        let table = try SEPResearchBoardPatcher.dispatchTable(in: sepd, text: text)
        let entry = sepd[table.offset + operation * 4 ..< table.offset + operation * 4 + 4]
        let textBytes = sepd[Int(text.fileOffset) ..< Int(text.fileOffset) + Int(text.size)]
        let code = Data(HMAC<SHA256>.authenticationCode(for: textBytes, using: SymmetricKey(data: Data(count: 32))))
        let hmacValid = sections["__TEXT,__fipspost_hmac"].map { code == sepd[Int($0.fileOffset) ..< Int($0.fileOffset) + 32] }
        return (Data(entry), hmacValid)
    }

    @Test(
        "The research board's SEPD answers operation 0x31 as vphone600's does, with a valid FIPS HMAC",
        .enabled(if: !pairedIPSWs.isEmpty, "needs a cloudOS IPSW with both SEP images in ipsws/"),
    )
    func matchesVPhone600() throws {
        for ipsw in Self.pairedIPSWs {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-o", "-j", ipsw.path, Self.researchEntry, Self.vphoneEntry, "-d", directory.path])
            try #require(result.status == 0)
            let researchURL = directory.appending(path: "sep-firmware.vresearch101.RELEASE.im4p")
            let (research, container) = try IM4PHandler.load(contentsOf: researchURL)
            let vphone = try IM4PHandler.load(contentsOf: directory.appending(path: "sep-firmware.vphone600.RELEASE.im4p")).payload

            // vphone600's SEP already answers that way: nothing to write.
            #expect(try SEPResearchBoardPatcher(data: vphone, verbose: false).findAll().isEmpty)

            let patcher = SEPResearchBoardPatcher(data: research, verbose: false)
            let records = try patcher.findAll()
            let hasHMAC = try Self.inspect(research, operation: 0).hmacValid != nil
            #expect(records.map(\.patchID) == [FirmwareResearchBoardPatchSet.sepDispatch + ".table"]
                + (hasHMAC ? [FirmwareResearchBoardPatchSet.sepDispatch + ".fips_hmac"] : []))
            try patcher.apply()
            let patched = try Self.inspect(patcher.patchedData, operation: SEPResearchBoardPatcher.redirectedOperation)
            let shared = try Self.inspect(research, operation: SEPResearchBoardPatcher.sharedOperation)
            #expect(patched.entry == shared.entry, "\(ipsw.lastPathComponent)")
            #expect(patched.hmacValid != false, "\(ipsw.lastPathComponent)")
            #expect(try SEPResearchBoardPatcher(data: patcher.patchedData, verbose: false).findAll().isEmpty)

            // The rebuilt container keeps the arms/tz0s load properties.
            let saved = directory.appending(path: "saved.im4p")
            try IM4PHandler.save(patchedData: patcher.patchedData, originalIM4P: container, to: saved)
            let original = try Data(contentsOf: researchURL)
            let rebuilt = try Data(contentsOf: saved)
            let originalTail = original[try #require(IM4PHandler.paypStart(in: original))...]
            let rebuiltTail = rebuilt[try #require(IM4PHandler.paypStart(in: rebuilt))...]
            #expect(originalTail == rebuiltTail)
            #expect(try IM4PHandler.load(contentsOf: saved).payload == patcher.patchedData)
        }
    }
}
