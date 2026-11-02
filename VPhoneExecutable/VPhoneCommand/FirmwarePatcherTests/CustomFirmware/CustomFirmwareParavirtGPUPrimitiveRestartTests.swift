// CustomFirmwareParavirtGPUPrimitiveRestartTests.swift — the GPU driver's primitive restart override.
//
// Two halves. A synthetic Mach-O carries the serialiser method around command
// 0x91's setup, so resolution, the written word, idempotence and the refusals
// are checked anywhere. The real cloudOS 26.4 (23E5207q) driver is the
// reference for the bytes: patched, it must hash to what was installed in a
// guest where OpenGL ES draws reached the framebuffer.
//
// The real driver is looked up as in CustomFirmwareParavirtGPUIndexOffsetTests:
// `VPHONE_MACHO_PRISTINE`, or `ipsws/ref_extract/macho_pristine/`, with
// `VPHONE_MACHO_FIXTURE_OPTIONAL=1` to skip when it is absent.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

private typealias Patcher = CustomFirmwareParavirtGPUPrimitiveRestart

private enum RealDriver {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let pristineSHA256 = "29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc"
    static let patchedSHA256 = "1992ab682b537ba084c32a6f0f1511b42f5f010f8e8912e8fa6a4ab8a224d3dc"
    /// Both driver patches, in the installer's order: heap index offsets, then this.
    static let bothSHA256 = "870ba415b82c13373e681ed7f7ee16c0d03d8072af2de68f67beaa0d133996d8"

    static var pristine: URL? {
        let directory = ProcessInfo.processInfo.environment["VPHONE_MACHO_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/macho_pristine")
        let binary = directory.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily")
        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    static var runs: Bool {
        pristine != nil || ProcessInfo.processInfo.environment["VPHONE_MACHO_FIXTURE_OPTIONAL"] != "1"
    }

    static let missing: Comment = """
    the cloudOS 26.4 (23E5207q) AppleParavirtGPUMetalIOGPUFamily is required — put it at \
    ipsws/ref_extract/macho_pristine/, point VPHONE_MACHO_PRISTINE at its directory, or set \
    VPHONE_MACHO_FIXTURE_OPTIONAL=1 to skip
    """

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A one-section Mach-O whose `__TEXT,__text` holds the end of a previous
/// method, then the serialiser method: `pacibsp`, a few body words, and the
/// command 0x91 setup.
private struct SyntheticDriver {
    static let textOffset = 0x100
    static let textSize = 0x100
    static let previousReturn = textOffset + 0x20
    static let methodStart = previousReturn + 4
    static let bodyWords = 11

    var data: Data

    init(setup: Bool = true, prologue: Bool = true, bodyWords: Int = Self.bodyWords) {
        var file = Data(count: Self.textOffset + Self.textSize)
        func put(_ value: UInt32, at offset: Int) {
            file.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value))
        }
        func put64(_ value: UInt64, at offset: Int) {
            put(UInt32(truncatingIfNeeded: value), at: offset)
            put(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
        }
        func putName(_ name: String, at offset: Int) {
            file.replaceSubrange(offset ..< offset + name.utf8.count, with: Data(name.utf8))
        }
        put(0xFEED_FACF, at: 0) // MH_MAGIC_64
        put(0x0100_000C, at: 4) // CPU_TYPE_ARM64
        put(1, at: 16) // ncmds
        put(72 + 80, at: 20) // sizeofcmds
        let segment = 32
        put(0x19, at: segment) // LC_SEGMENT_64
        put(72 + 80, at: segment + 4)
        putName("__TEXT", at: segment + 8)
        put64(UInt64(Self.textOffset + Self.textSize), at: segment + 32) // vmsize
        put64(UInt64(Self.textOffset + Self.textSize), at: segment + 48) // filesize
        put(1, at: segment + 64) // nsects
        let section = segment + 72
        putName("__text", at: section)
        putName("__TEXT", at: section + 16)
        put64(UInt64(Self.textOffset), at: section + 32) // addr
        put64(UInt64(Self.textSize), at: section + 40) // size
        put(UInt32(Self.textOffset), at: section + 48) // offset

        for offset in stride(from: Self.textOffset, to: Self.textOffset + Self.textSize, by: 4) {
            put(0xD503_201F, at: offset) // nop
        }
        file.replaceSubrange(Self.previousReturn ..< Self.previousReturn + 4, with: ARM64.retab)
        if prologue {
            file.replaceSubrange(Self.methodStart ..< Self.methodStart + 4, with: ARM64.pacibsp)
        }
        if setup {
            let at = Self.methodStart + 4 * (bodyWords + 1)
            file.replaceSubrange(at ..< at + 8, with: CustomFirmwareParavirtGPUIndexOffset.setup(size: 0x08, command: 0x91))
        }
        data = file
    }
}

struct CustomFirmwareParavirtGPUPrimitiveRestartTests {
    @Test func `The method's pacibsp becomes ret`() throws {
        var driver = SyntheticDriver()
        let report = try Patcher.patch(&driver.data, log: nil)
        #expect(report == Patcher.Report(fileOffset: SyntheticDriver.methodStart, state: .patched))
        #expect(driver.data[SyntheticDriver.methodStart ..< SyntheticDriver.methodStart + 4] == ARM64.ret)
    }

    @Test func `A second run recognises its own output and writes nothing`() throws {
        var driver = SyntheticDriver()
        try Patcher.patch(&driver.data, log: nil)
        let once = driver.data
        let report = try Patcher.patch(&driver.data, log: nil)
        #expect(report.state == .alreadyPatched)
        #expect(driver.data == once)
    }

    @Test func `A driver without command 0x91 refuses and changes nothing`() throws {
        var driver = SyntheticDriver(setup: false)
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    @Test func `A method without a prologue before the setup refuses`() throws {
        var driver = SyntheticDriver(prologue: false)
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    @Test func `A prologue further away than a method's head refuses`() throws {
        var driver = SyntheticDriver(bodyWords: Patcher.maximumPrologue + 4)
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
    }

    // MARK: - Real driver

    @Test(.enabled(if: RealDriver.runs))
    func `The 23E5207q driver patches to the verified bytes, alone and with the heap index patch`() throws {
        let url = try #require(RealDriver.pristine, RealDriver.missing)
        let pristine = try Data(contentsOf: url)
        #expect(RealDriver.sha256(pristine) == RealDriver.pristineSHA256)

        var alone = pristine
        #expect(try Patcher.patch(&alone, log: nil) == Patcher.Report(fileOffset: 0x174B4, state: .patched))
        #expect(RealDriver.sha256(alone) == RealDriver.patchedSHA256)
        #expect(try Patcher.patch(&alone, log: nil).state == .alreadyPatched)

        var both = pristine
        try CustomFirmwareParavirtGPUIndexOffset.patch(&both, log: nil)
        try Patcher.patch(&both, log: nil)
        #expect(RealDriver.sha256(both) == RealDriver.bothSHA256)
    }
}
