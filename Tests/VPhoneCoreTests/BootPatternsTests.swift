import Foundation
import Testing
@testable import VPhoneCore

/// Tests for `VPhoneBootPatterns` — the pure, device-independent pieces of the
/// native `vm create` pipeline (`VPhoneVirtualMachineCreator`, executable target).
/// The orchestrator's live stages (DFU/restore/CFW/boot check) require a VM.
struct BootPatternsTests {
    // MARK: - first-boot panic markers

    private func matches(_ pattern: String, _ line: String) throws -> Bool {
        let re = try NSRegularExpression(pattern: pattern)
        return re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    @Test func `panic regex matches kernel panic line`() throws {
        #expect(try matches(VPhoneBootPatterns.panicRegex, "panic(cpu 0 caller 0xfffffff01234): test panic"))
    }

    @Test func `panic regex matches stackshot succeeded`() throws {
        #expect(try matches(VPhoneBootPatterns.panicRegex, "stackshot succeeded"))
    }

    @Test func `panic regex does not match ordinary log line`() throws {
        #expect(try !matches(VPhoneBootPatterns.panicRegex, "vphoned: connected, awaiting handshake"))
    }

    // MARK: - normalizeECID (port of setup_machine.sh's normalize_ecid)

    @Test func `normalize ECID strips prefix and pads`() {
        #expect(VPhoneBootPatterns.normalizeECID("0xabc") == "0000000000000ABC")
    }

    @Test func `normalize ECID passes through sixteen hex digits`() {
        #expect(VPhoneBootPatterns.normalizeECID("0011223344556677") == "0011223344556677")
    }

    @Test func `normalize ECID uppercases lower hex`() {
        #expect(VPhoneBootPatterns.normalizeECID("0xdeadbeef") == "00000000DEADBEEF")
    }

    @Test func `normalize ECID rejects non hex`() {
        #expect(VPhoneBootPatterns.normalizeECID("zzzz") == nil)
    }

    @Test func `normalize ECID rejects overlong input`() {
        #expect(VPhoneBootPatterns.normalizeECID("00112233445566778") == nil) // 17 hex chars
    }

    @Test func `normalize ECID rejects empty input`() {
        #expect(VPhoneBootPatterns.normalizeECID("") == nil)
        #expect(VPhoneBootPatterns.normalizeECID("0x") == nil)
    }

    // The three parseHVVmmPresent cases that were here tested a string parse of
    // `sysctl -n kern.hv_vmm_present`. The nested-host check reads the int
    // through `sysctlbyname` now, so the parse — and its tests — are gone.
}
