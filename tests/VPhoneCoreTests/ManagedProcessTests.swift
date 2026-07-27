@testable import VPhoneCore
import Foundation
import Testing

struct ManagedProcessTests {
    @Test func waitsForOutputMatch() throws {
        // Emit a line after a short delay, then sleep; the matcher should catch it.
        let p = VPhoneManagedProcess(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "sleep 0.2; echo READY-NOW; sleep 2"], echo: false)
        try p.start()
        let r = p.waitForOutput(matching: "READY-NOW", timeout: 5)
        #expect(r == .matched)
        p.terminate()
    }

    @Test func reportsExitBeforeMatch() throws {
        let p = VPhoneManagedProcess(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "echo nope; exit 3"], echo: false)
        try p.start()
        let r = p.waitForOutput(matching: "WILL-NOT-APPEAR", timeout: 5)
        #expect(r == .exited(3))
    }

    @Test func timesOutWhenNoMatch() throws {
        let p = VPhoneManagedProcess(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "sleep 3"], echo: false)
        try p.start()
        let r = p.waitForOutput(matching: "NEVER", timeout: 0.5)
        #expect(r == .timedOut)
        p.terminate()
    }

    @Test func sendWritesToStdinAndDrivesTheChild() throws {
        // Child echoes a marker only after it reads a line from stdin.
        let p = VPhoneManagedProcess(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "read line; echo GOT:$line"], echo: false)
        try p.start()
        p.send("hello")
        let r = p.waitForOutput(matching: "GOT:hello", timeout: 5)
        #expect(r == .matched)
        #expect(p.waitUntilExit() == 0)
    }

    @Test func terminateForceKillsAResistantChild() throws {
        // Child IGNORES SIGINT and SIGTERM, so terminate() must escalate to SIGKILL
        // and waitUntilExit() must return (not hang).
        let p = VPhoneManagedProcess(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "trap '' INT TERM; while :; do sleep 1; done"], echo: false)
        try p.start()
        _ = p.waitForOutput(matching: "NEVER", timeout: 0.4)  // let it install the traps
        p.terminate()
        #expect(p.waitUntilExit() != 0)  // SIGKILL → nonzero/signal status, and it RETURNED
    }
}
