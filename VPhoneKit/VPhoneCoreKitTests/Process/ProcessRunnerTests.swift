import Foundation
import Testing
@testable import VPhoneCoreKit

struct ProcessRunnerTests {
    @Test func `captures stdout and zero exit`() throws {
        let r = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/bin/echo"), ["hello", "world"])
        #expect(r.exitCode == 0)
        #expect(r.succeeded)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test func `captures nonzero exit`() throws {
        // `/usr/bin/false` exits 1 with no output.
        let r = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/false"), [])
        #expect(r.exitCode == 1)
        #expect(!r.succeeded)
    }

    @Test func `passes cwd`() throws {
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/pwd"),
            [],
            cwd: URL(fileURLWithPath: "/tmp"),
        )
        // /tmp is a symlink to /private/tmp on macOS; accept either.
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out == "/tmp" || out == "/private/tmp")
    }

    @Test func `drains both pipes concurrently without deadlock`() throws {
        // Child writes 100 KB to stderr BEFORE any stdout; a sequential
        // "read stdout fully first" drain would deadlock at the ~64 KB stderr
        // pipe buffer. Concurrent draining must complete without hanging.
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "yes E | head -c 100000 1>&2; yes X | head -c 100000"],
        )
        #expect(r.exitCode == 0)
        #expect(r.stdout.utf8.count == 100_000)
        #expect(r.stderr.utf8.count == 100_000)
    }

    @Test func `run streaming returns exit code`() throws {
        #expect(try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/usr/bin/true"), []) == 0)
        #expect(try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/usr/bin/false"), []) == 1)
    }

    @Test func `run streaming echo false still returns exit code`() throws {
        // Child writes to stdout but echo:false discards it; exit code still propagates.
        #expect(try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo noise; exit 0"], echo: false,
        ) == 0)
        #expect(try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo noise >&2; exit 7"], echo: false,
        ) == 7)
    }
}
