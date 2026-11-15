import Foundation
import Testing
@testable import VPhoneCoreKit

struct ConsoleScreenTests {
    private func baseline() -> VPhoneConsoleScreen {
        VPhoneConsoleScreen(title: "vphone-cli vm create demo",
                            pendingPhases: ["vm new", "fw prepare", "fw patch", "Restore phase"], startedAt: 0)
    }

    @Test func `decorations are stripped for display`() {
        #expect(VPhoneConsoleScreen.displayText("[*] Extracting cloudOS IPSW...") == "Extracting cloudOS IPSW")
        #expect(VPhoneConsoleScreen.displayText("- Merging App OS cryptex…") == "Merging App OS cryptex")
        #expect(VPhoneConsoleScreen.displayText("  [+] Injected vphoned") == "Injected vphoned")
        #expect(VPhoneConsoleScreen.displayText("plain text") == "plain text")
    }

    @Test func `finished phases collapse to one line with their summary`() {
        var s = baseline()
        s.phase("vm new", at: 0); s.line("created /x", .plain)
        s.phase("fw prepare", at: 2); s.line("[*] Extracting cloudOS IPSW...", .step)
        s.line("[+] Firmware prepared.", .done)
        s.phase("fw patch", at: 60)
        let f = s.frame(at: 61, width: 100, height: 40)
        #expect(f[1].hasPrefix(" ✓ vm new"))
        #expect(f[2].hasPrefix(" ✓ fw prepare") && f[2].contains("0:58") && f[2].contains("Firmware prepared."))
        #expect(!f.contains { $0.contains("Extracting cloudOS IPSW") })
        #expect(f.last == " ○ Restore phase")
    }

    @Test func `the active phase shows recent steps, the current one and a count`() {
        var s = baseline()
        s.phase("fw patch", at: 0)
        for (i, name) in ["a", "b", "c", "d", "e"].enumerated() { s.activity(name, done: i + 1, of: 13) }
        s.line("  [+] detail", .note)
        let f = s.frame(at: 5, width: 100, height: 40)
        let row = f.first { $0.contains("fw patch") }!
        #expect(row.contains("5/13"))
        #expect(f.contains("     ✓ b") && f.contains("     ✓ d") && !f.contains("     ✓ a"))
        #expect(f.contains { $0.hasSuffix(" e") } && f.contains("       detail"))
    }

    @Test func `a fraction is shown as a percentage`() {
        var s = baseline(); s.phase("Restore phase", at: 0)
        s.activity("upload filesystem", fraction: 0.32)
        #expect(s.frame(at: 1, width: 100, height: 40).contains { $0.contains("Restore phase") && $0.contains("32%") })
    }

    @Test func `a fraction that is not finite shows no bar and one out of range is clamped`() {
        func row(_ f: Double) -> String {
            var s = baseline(); s.phase("Restore phase", at: 0)
            s.activity("upload filesystem", fraction: f)
            return s.frame(at: 1, width: 100, height: 40).first { $0.contains("Restore phase") }!
        }
        for f in [Double.nan, .infinity, -.infinity] { #expect(!row(f).contains("░") && !row(f).contains("%")) }
        #expect(row(-0.5).hasSuffix(String(repeating: "░", count: 16) + " 0%"))
        #expect(row(1.7).hasSuffix(String(repeating: "█", count: 16) + " 100%"))
    }

    @Test func `a phase that was not announced appears when it starts`() {
        var s = VPhoneConsoleScreen(title: "t", pendingPhases: [], startedAt: 0)
        s.phase("Template build k", at: 0)
        #expect(s.frame(at: 1, width: 100, height: 40).contains { $0.contains("Template build k") })
    }

    @Test func `the Done marker closes the run instead of becoming a phase`() {
        var s = baseline(); s.phase("vm new", at: 0); s.phase("Done", at: 3); s.finish(failed: false, at: 3)
        let f = s.frame(at: 3, width: 100, height: 40)
        #expect(!f.contains { $0.contains("✓ Done") || $0.contains("○ Done") })
        #expect(f.last!.contains("Done in 0:03"))
    }

    @Test func `a failure marks the phase and keeps the last fifteen lines`() {
        var s = baseline(); s.phase("fw prepare", at: 0)
        for i in 0 ..< 20 { s.line("line \(i)", .plain) }
        s.line("[-] it broke", .failure)
        s.finish(failed: true, at: 4)
        let f = s.frame(at: 4, width: 100, height: 40)
        #expect(f.contains { $0.hasPrefix(" ✗ fw prepare") } && f.contains { $0.contains("it broke") })
        #expect(s.lastLines.count == 15 && s.lastLines.last == "[-] it broke")
    }

    @Test func `no line is wider than the terminal and the frame fits its height`() {
        var s = baseline(); s.phase("fw patch", at: 0)
        for i in 0 ..< 8 { s.activity(String(repeating: "x", count: 90) + "\(i)", done: i, of: 8) }
        let f = s.frame(at: 1, width: 40, height: 10)
        #expect(f.allSatisfy { $0.count <= 39 } && f.count <= 9)
    }
}
