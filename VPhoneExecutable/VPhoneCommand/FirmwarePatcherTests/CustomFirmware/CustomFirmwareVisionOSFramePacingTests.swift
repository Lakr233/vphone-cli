import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

private typealias Pacing = CustomFirmwareVisionOSFramePacing

/// Relocatable, signed native-function fixture. Instruction words were checked
/// with Xcode's arm64 assembler; branch destinations are generated below.
private struct PacingFixture {
    var data: Data
    let textOffset: Int
    let textAddress: UInt64
    var siteOffset: Int { textOffset + 28 }
    static let signatureOffset = 0xA00
    static let hashOffset = signatureOffset + 0x80

    init(textOffset: Int = 0x200, textAddress: UInt64 = 0x100004000, duplicate: Bool = false) {
        self.textOffset = textOffset
        self.textAddress = textAddress
        var bytes = Data(count: 0xB00)
        func put(_ value: UInt32, _ at: Int) { bytes.replaceSubrange(at..<at + 4, with: ARM64.encodeU32(value)) }
        func put64(_ value: UInt64, _ at: Int) {
            put(UInt32(truncatingIfNeeded: value), at); put(UInt32(truncatingIfNeeded: value >> 32), at + 4)
        }
        func name(_ value: String, _ at: Int) { bytes.replaceSubrange(at..<at + value.utf8.count, with: Data(value.utf8)) }
        func big(_ value: UInt32, _ at: Int) { put(value.byteSwapped, at) }
        put(0xFEED_FACF, 0); put(0x0100_000C, 4); put(2, 12); put(3, 16); put(192, 20)
        put(0x19, 32); put(152, 36); name("__TEXT", 40)
        put64(textAddress - UInt64(textOffset), 56); put64(0xA00, 64); put64(0xA00, 80); put(1, 96)
        name("__text", 104); name("__TEXT", 120); put64(textAddress, 136)
        put64(0x200, 144); put(UInt32(textOffset), 152)
        put(2, 184); put(24, 188); put(0x800, 192); put(3, 196); put(0x850, 200); put(0x180, 204)
        put(0x1D, 208); put(16, 212); put(UInt32(Self.signatureOffset), 216); put(0x100, 220)
        let sequence: [UInt32] = [
            0xF9407680, 0xEB000108, 0, 0x9E620100, 0xA94F2289, 0x9E620101,
            0x1E611800, 0x9E68000A, 0x4E080D40, 0x9B0A7D08, 0x3CCD8281,
            0x4EE08420, 0x3C8D8280, 0x8B000100, 0x8B080128, 0xA90EA280, 0, 0xD65F03C0,
        ]
        let count = duplicate ? 2 : 1
        let status = textAddress + UInt64(sequence.count * 4 * count), wait = status + 4
        for n in 0..<count {
            let base = textOffset + n * sequence.count * 4
            for (i, word) in sequence.enumerated() { put(word, base + i * 4) }
            bytes.replaceSubrange(base + 8..<base + 12,
                                  with: ARM64Encoder.encodeBCond(from: base + 8, to: base + 64, condition: .ls)!)
            bytes.replaceSubrange(base + 64..<base + 68,
                                  with: ARM64Encoder.encodeBL(from: base + 64, to: textOffset + Int(wait - textAddress))!)
        }
        let end = textOffset + sequence.count * 4 * count
        put(0xD65F03C0, end); put(0xD65F03C0, end + 4)
        var stringIndex = 1
        let names = [Pacing.dequeueSymbol, Pacing.statusSymbol, "_mach_wait_until"]
        for (i, address) in [textAddress, status, wait].enumerated() {
            let entry = 0x800 + i * 16
            put(UInt32(stringIndex), entry); bytes[entry + 4] = 0x0E; bytes[entry + 5] = 1
            put64(address, entry + 8); name(names[i], 0x850 + stringIndex); stringIndex += names[i].utf8.count + 1
        }
        big(0xFADE0CC0, 0xA00); big(0x100, 0xA04); big(1, 0xA08); big(0, 0xA0C); big(0x20, 0xA10)
        big(0xFADE0C02, 0xA20); big(0x80, 0xA24); big(0x20001, 0xA28)
        big(0x60, 0xA30); big(44, 0xA34); big(1, 0xA3C); big(0xA00, 0xA40)
        bytes[0xA44] = 32; bytes[0xA45] = 2; bytes[0xA47] = 12
        name("com.apple.wakeboardd", 0xA4C)
        bytes.replaceSubrange(Self.hashOffset..<Self.hashOffset + 32, with: Data(SHA256.hash(data: bytes.prefix(0xA00))))
        data = bytes
    }
}

struct CustomFirmwareVisionOSFramePacingTests {
    @Test func `Only the conversion and its page hash change and reruns are identical`() throws {
        var fixture = PacingFixture()
        let original = fixture.data
        let report = try Pacing.patch(&fixture.data)
        #expect(report.outcome == .patched && report.site.fileOffset == fixture.siteOffset)
        #expect(report.site.virtualAddress == fixture.textAddress + 28)
        #expect(report.records.count == 1 && report.records[0].patchID == Pacing.patchID)
        #expect(report.rehashedSlots.count == 1)
        let allowed = [fixture.siteOffset..<fixture.siteOffset + 4, PacingFixture.hashOffset..<PacingFixture.hashOffset + 32]
        #expect(original.indices.allSatisfy { i in
            original[i] == fixture.data[i] || allowed.contains(where: { $0.contains(i) })
        })
        let once = fixture.data
        #expect(try Pacing.patch(&fixture.data).outcome == .alreadyPatched)
        #expect(fixture.data == once)
    }

    @Test func `The symbol anchor follows relocated code and dry run preserves bytes`() throws {
        var fixture = PacingFixture(textOffset: 0x380, textAddress: 0x180008000)
        let before = fixture.data
        let report = try Pacing.patch(&fixture.data, dryRun: true)
        #expect(report.outcome == .wouldPatch && report.site.fileOffset == fixture.siteOffset)
        #expect(fixture.data == before)
        #expect(try Pacing.patch(&fixture.data).outcome == .patched)
    }

    @Test func `Changed divisor and branch and duplicate matches refuse atomically`() throws {
        for delta in [-4, -20] {
            var fixture = PacingFixture()
            fixture.data.replaceSubrange(fixture.siteOffset + delta..<fixture.siteOffset + delta + 4, with: ARM64.nop)
            let before = fixture.data
            #expect(throws: PatcherError.self) { try Pacing.patch(&fixture.data) }
            #expect(fixture.data == before)
        }
        var fixture = PacingFixture(duplicate: true)
        let before = fixture.data
        #expect(throws: PatcherError.self) { try Pacing.patch(&fixture.data) }
        #expect(fixture.data == before)
    }

    @Test func `Invalid signatures and already patched code with stale hashes refuse`() throws {
        for mutation in 0..<3 {
            var fixture = PacingFixture()
            if mutation == 0 { fixture.data[0xA00] = 0 }
            else if mutation == 1 { fixture.data[0xA45] = 1 }
            else {
                fixture.data.replaceSubrange(fixture.siteOffset..<fixture.siteOffset + 4,
                                             with: try #require(ARM64Encoder.encodeFcvtzsXFromD(rd: 10, rn: 0)))
            }
            let before = fixture.data
            #expect(throws: PatcherError.self) { try Pacing.patch(&fixture.data) }
            #expect(fixture.data == before)
        }
    }

    @Test func `Predicting one period ahead sustains every tick with a small submit tail`() {
        func simulate(round: (Double) -> Int) -> (frames: Int, skipped: Int) {
            let period = 1000
            var target = 0, now = 0, frames = 0, skipped = 0
            while now < 60 * period {
                target += period // Native dequeue first advances to the next tick.
                if now > target {
                    let count = round(Double(now - target) / Double(period))
                    target += count * period
                    skipped += count
                }
                // rt_thread_main predicts the following presentation. The
                // native submit waits for it, then takes one unit to return.
                now = target + period + 1
                frames += 1
            }
            return (frames, skipped)
        }
        let stock = simulate { Int(ceil($0)) }, fixed = simulate { Int($0) }
        #expect(stock.frames == 30 && stock.skipped == 29)
        #expect(fixed.frames == 59 && fixed.skipped == 0) // One initial prediction period.
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_VISIONOS_WAKEBOARDD"] != nil))
    func `Native wakeboardd matches the independently assembled candidate`() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_VISIONOS_WAKEBOARDD"])
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        func sha(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        #expect(sha(data) == "44e96dbda3c51af29fb1209211778f820b23727e1d362e864cdfc0455df734a5")
        #expect(try Pacing.patch(&data).site.fileOffset == 0x9493C)
        #expect(sha(data) == "08929ba699ef14db5f4d24b4be381a75f89aeedd737446953843b18aeb900123")
        #expect(try Pacing.patch(&data).outcome == .alreadyPatched)
    }
}
