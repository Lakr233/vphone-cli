@testable import VPhoneCore
import Foundation
import Testing

// Tests for `VPhoneBootPatterns` — the pure, device-independent pieces of the
// native `vm create` pipeline (`VPhoneCreateOrchestrator`, executable target).
// The orchestrator's live stages (DFU/restore/CFW/first-boot/boot-analysis)
// need a real device and are NOT exercised here; see the Task 2 report.
struct CreateOrchestratorTests {
    // MARK: - promptRegex / panicRegex (verbatim ports of setup_machine.sh's
    // BOOT_BASH_PROMPT_REGEX / BOOT_PANIC_REGEX)

    private func matches(_ pattern: String, _ line: String) throws -> Bool {
        let re = try NSRegularExpression(pattern: pattern)
        return re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    @Test func promptRegexMatchesIosbinpackBashPrompt() throws {
        #expect(try matches(VPhoneBootPatterns.promptRegex, "bash-3.2#"))
    }

    @Test func promptRegexMatchesRamdiskRootPrompt() throws {
        #expect(try matches(VPhoneBootPatterns.promptRegex, ":/ root#"))
    }

    @Test func promptRegexDoesNotMatchOrdinaryLogLine() throws {
        #expect(try !matches(VPhoneBootPatterns.promptRegex, "vphoned: connected, awaiting handshake"))
    }

    @Test func panicRegexMatchesKernelPanicLine() throws {
        #expect(try matches(VPhoneBootPatterns.panicRegex, "panic(cpu 0 caller 0xfffffff01234): test panic"))
    }

    @Test func panicRegexMatchesStackshotSucceeded() throws {
        #expect(try matches(VPhoneBootPatterns.panicRegex, "stackshot succeeded"))
    }

    @Test func panicRegexDoesNotMatchOrdinaryLogLine() throws {
        #expect(try !matches(VPhoneBootPatterns.panicRegex, "vphoned: connected, awaiting handshake"))
    }

    // MARK: - panicOrPromptRegex (mixed case-sensitivity, per
    // monitor_boot_log_until's `grep -Ei` panic vs. `grep -E` prompt)

    @Test func panicOrPromptRegexMatchesPanicCaseInsensitively() throws {
        #expect(try matches(VPhoneBootPatterns.panicOrPromptRegex, "PANIC(cpu 0 caller 0x0): uppercase panic"))
    }

    @Test func panicOrPromptRegexKeepsPromptCaseSensitive() throws {
        #expect(try matches(VPhoneBootPatterns.panicOrPromptRegex, "bash-3.2#"))
        #expect(try !matches(VPhoneBootPatterns.panicOrPromptRegex, "BASH-3.2#"))
    }

    // MARK: - normalizeECID (port of setup_machine.sh's normalize_ecid)

    @Test func normalizeECIDStripsPrefixAndPads() {
        #expect(VPhoneBootPatterns.normalizeECID("0xabc") == "0000000000000ABC")
    }

    @Test func normalizeECIDPassesThroughSixteenHexDigits() {
        #expect(VPhoneBootPatterns.normalizeECID("0011223344556677") == "0011223344556677")
    }

    @Test func normalizeECIDUppercasesLowerHex() {
        #expect(VPhoneBootPatterns.normalizeECID("0xdeadbeef") == "00000000DEADBEEF")
    }

    @Test func normalizeECIDRejectsNonHex() {
        #expect(VPhoneBootPatterns.normalizeECID("zzzz") == nil)
    }

    @Test func normalizeECIDRejectsOverlongInput() {
        #expect(VPhoneBootPatterns.normalizeECID("00112233445566778") == nil)  // 17 hex chars
    }

    @Test func normalizeECIDRejectsEmptyInput() {
        #expect(VPhoneBootPatterns.normalizeECID("") == nil)
        #expect(VPhoneBootPatterns.normalizeECID("0x") == nil)
    }

    // MARK: - parseHVVmmPresent (nested-VM host preflight)

    @Test func parseHVVmmPresentTrueWhenNested() {
        #expect(VPhoneBootPatterns.parseHVVmmPresent("1\n") == true)
    }

    @Test func parseHVVmmPresentFalseWhenNotNested() {
        #expect(VPhoneBootPatterns.parseHVVmmPresent("0") == false)
    }

    @Test func parseHVVmmPresentFalseWhenEmpty() {
        #expect(VPhoneBootPatterns.parseHVVmmPresent("") == false)
    }

    // MARK: - firstBootCommands (setup_machine.sh:344-361)

    @Test func firstBootCommandsMatchSetupMachineVerbatim() {
        #expect(VPhoneBootPatterns.firstBootCommands == [
            "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'",
            "cp /iosbinpack64/etc/profile /var/profile",
            "cp /iosbinpack64/etc/motd /var/motd",
            "mkdir -p /var/dropbear",
            "dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key",
            "dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key",
            "shutdown -h now",
        ])
    }
}
