//
//  VPhoneSignFatSliceTests.swift
//  vphone-cli
//
//  Created by Phineas Guo on 2026/11/01.
//

import Foundation
import MachO
import Testing
@testable import VPhoneSign

@Suite("Legacy ARM slices in universal binaries")
struct VPhoneSignFatSliceTests {
    @Test(arguments: [false, true], [VPhoneSignOptions.Style.ldid, .appleAdHoc])
    func `mixed armv7 and arm64 files preserve armv7 and sign arm64`(
        legacyFirst: Bool,
        style: VPhoneSignOptions.Style,
    ) throws {
        let arm64 = try Data(contentsOf: VPhoneSignFixtures.url("hello-arm64"))
        let legacy = Self.armv7
        let images = legacyFirst ? [legacy, arm64] : [arm64, legacy]
        let input = Self.fat(images)
        let options = VPhoneSignOptions(identifier: "mixed", mergesExisting: true, style: style)

        let signed = try VPhoneSigner.sign(input, options: options)
        // lipo independently checks the table and extracts both slices.
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed")
        let extracted = directory.appendingPathComponent("arm64")
        let preserved = directory.appendingPathComponent("armv7")
        try signed.write(to: file)
        let info = try VPhoneSignFixtures.run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", file.path])
        #expect(info.status == 0, "\(info.error)")
        let expectedArchitectures = legacyFirst ? "armv7 arm64" : "arm64 armv7"
        #expect(String(decoding: info.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expectedArchitectures)
        let extract = try VPhoneSignFixtures.run(
            URL(fileURLWithPath: "/usr/bin/lipo"),
            [file.path, "-thin", "arm64", "-output", extracted.path],
        )
        #expect(extract.status == 0, "\(extract.error)")
        #expect(try Data(contentsOf: extracted) == VPhoneSigner.sign(arm64, options: options))
        let extractLegacy = try VPhoneSignFixtures.run(
            URL(fileURLWithPath: "/usr/bin/lipo"),
            [file.path, "-thin", "armv7", "-output", preserved.path],
        )
        #expect(extractLegacy.status == 0, "\(extractLegacy.error)")
        #expect(try Data(contentsOf: preserved) == legacy)
        #expect(try VPhoneSignBlobs(fileAt: extracted).slices[0][0] != nil)
        #expect(try VPhoneSigner.sign(signed, options: options) == signed)
    }

    @Test
    func `thin and fat files containing only armv7 are refused`() throws {
        for input in [Self.armv7, Self.fat([Self.armv7])] {
            #expect(throws: VPhoneSignError.self) {
                try VPhoneSigner.sign(input, options: .init(identifier: "legacy"))
            }
        }
    }

    @Test
    func `an out of bounds legacy slice is still refused`() throws {
        let arm64 = try Data(contentsOf: VPhoneSignFixtures.url("hello-arm64"))
        var input = Self.fat([Self.armv7, arm64])
        // First fat_arch.size, deliberately extending beyond the whole file.
        input.replaceSubrange(20 ..< 24, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: VPhoneSignError.self) {
            try VPhoneSigner.sign(input, options: .init(identifier: "bad"))
        }
    }

    @Test
    func `unknown and inconsistent legacy headers are refused`() throws {
        let arm64 = try Data(contentsOf: VPhoneSignFixtures.url("hello-arm64"))
        var wrongCPU = Self.armv7
        wrongCPU.storeLittleEndian(UInt32(CPU_TYPE_X86), at: 4)
        var badCommands = Self.armv7
        badCommands.storeLittleEndian(UInt32.max, at: 20)
        for legacy in [Data(Self.armv7.prefix(12)), wrongCPU, badCommands] {
            var input = Self.fat([legacy, arm64])
            // The container claims ARM even when the embedded header does not.
            input.replaceSubrange(8 ..< 12, with: [0, 0, 0, UInt8(CPU_TYPE_ARM)])
            #expect(throws: VPhoneSignError.self) {
                try VPhoneSigner.sign(input, options: .init(identifier: "bad"))
            }
        }
    }

    // MARK: - Container fixtures

    /// A synthetic ARM header with an opaque old signature to preserve.
    /// It is never signed or executed; the retained arm64 is a real fixture.
    private static var armv7: Data {
        var image = Data()
        for word: UInt32 in [MH_MAGIC, UInt32(CPU_TYPE_ARM), UInt32(CPU_SUBTYPE_ARM_V7), UInt32(MH_BUNDLE), 1, 16, 0] {
            withUnsafeBytes(of: word.littleEndian) { image.append(contentsOf: $0) }
        }
        for word: UInt32 in [UInt32(LC_CODE_SIGNATURE), 16, 44, 12] {
            withUnsafeBytes(of: word.littleEndian) { image.append(contentsOf: $0) }
        }
        image.append(Data("oldSignature".utf8))
        return image
    }

    private static func fat(_ images: [Data]) -> Data {
        var header = Data()
        header.appendBigEndian(FAT_MAGIC)
        header.appendBigEndian(UInt32(images.count))
        var body = Data()
        let headerSize = 8 + images.count * MemoryLayout<fat_arch>.size
        for image in images {
            let cpu: UInt32 = image.littleEndianValue(at: 4)
            let alignment: UInt32 = cpu == UInt32(CPU_TYPE_ARM) ? 12 : 14
            let offset = (headerSize + body.count).aligned(to: 1 << Int(alignment))
            body.append(Data(count: offset - headerSize - body.count))
            body.append(image)
            let subtype: UInt32 = image.littleEndianValue(at: 8)
            for field in [cpu, subtype, UInt32(offset), UInt32(image.count), alignment] {
                header.appendBigEndian(field)
            }
        }
        return header + body
    }
}
