import Foundation

// MARK: - Harness

/// Checks how a `bootstrap.status` reply is read while `bootstrap.packages`
/// runs. The VM gives up relaying the request after 180 s while the guest
/// carries on, so the reply is often lost and the status is all there is.
/// `run-bootstrap-packages-status-tests.sh` builds this file with the source.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL line \(line): \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL line \(line): \(message) — expected \(expected), got \(actual)")
    }
}

@main
enum BootstrapPackagesStatusTests {
    static func main() {
        thisCall()
        notThisCall()
        failureMessages()
        directReply()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    /// The statuses installPackages actually sets: "packages" while
    /// irisin-cli runs, then "completed" or "failed".
    static func thisCall() {
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "packages", "packages": ["owngoal-bootstrap-vphone"]]),
            .running,
            "the packages phase is still running",
        )
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "completed", "packages": ["owngoal-bootstrap-vphone"]]),
            .completed(["owngoal-bootstrap-vphone"]),
            "completed carries the installed packages",
        )
        // A phase this build does not know must not end the wait: the guest
        // is still working, and giving up would report a false failure.
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "unknown-future-phase", "packages": [String]()]),
            .running,
            "an unrecognised phase keeps waiting",
        )
    }

    /// `packages` is the discriminator: an Irisin-install status has none, and
    /// treating one as ours would end the wait on a stale reading.
    static func notThisCall() {
        expect(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "completed"]) == nil,
            "a completed install status is not this call",
        )
        expect(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "downloading", "downloaded_bytes": 1]) == nil,
            "a download status is not this call",
        )
        expect(
            VPhoneBootstrapPackagesStatus.outcome(for: [:]) == nil,
            "an empty status is not this call",
        )
    }

    static func failureMessages() {
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "failed", "packages": [String](), "message": "boom"]),
            .failed("boom"),
            "a failure carries the guest's message",
        )
        // A failure with no message is still a failure. The reason comes
        // through empty rather than carrying English: the caller localizes it,
        // since this type is built without the localization table.
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(for: ["phase": "failed", "packages": [String]()]),
            .failed(""),
            "a failure with no message is still a failure",
        )
    }

    /// The reply that arrives before the relay deadline. Apple TV answers
    /// this way: Irisin's tvOS package has no irisin-cli, so vphoned declines
    /// the work and says why. Reading that reason as a package name would put
    /// "Installed Irisin's Apple TV package has no irisin-cli." on screen.
    static func directReply() {
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(forReply: [
                "packages": [String](),
                "skipped": "Irisin's Apple TV package has no irisin-cli",
            ]),
            .skipped("Irisin's Apple TV package has no irisin-cli"),
            "a skipped reply is a note, not an installed package",
        )
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(forReply: ["packages": ["owngoal-bootstrap-vphone"]]),
            .completed(["owngoal-bootstrap-vphone"]),
            "an ordinary reply carries the installed packages",
        )
        expectEqual(
            VPhoneBootstrapPackagesStatus.outcome(forReply: [:]),
            .completed([]),
            "a reply naming no packages is still a success",
        )
    }
}
