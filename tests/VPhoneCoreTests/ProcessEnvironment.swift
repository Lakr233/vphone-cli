import Foundation

/// A lock around `VPHONE_ROOT` and `VPHONE_LIBRARY_ROOT`, because the
/// environment is process-global and `.serialized` is not.
///
/// `ResourcesTests` and `LibraryTests` both drive those two variables, and both
/// carry `.serialized` — which orders each suite's own tests and does nothing
/// about the two suites running against each other. So `LibraryTests`'
/// `unsetenv("VPHONE_ROOT")` would land in the middle of
/// `ResourcesTests.userDataRootHonorsVPHONERoot`, whose next three
/// `#expect`s then compared a `~/.vphone` path against `/tmp/vphone-test-root`.
/// That is the intermittent failure `ResourcesTests`' own header describes as
/// "roughly one run in ten" and believed `.serialized` had fixed; it survived,
/// because the other half of the race is in a different file.
///
/// Taking this lock for the whole of a test body — reads included, not just
/// writes — is what actually serialises them, and restoring the previous value
/// rather than unsetting means a test that runs under an inherited
/// `VPHONE_ROOT` leaves it as it found it.
enum ProcessEnvironment {
    private static let lock = NSLock()

    /// Run `body` with `overrides` applied, with nothing else touching these
    /// variables, and with whatever was there before put back afterwards. A
    /// `nil` value unsets.
    static func withOverrides(
        _ overrides: [String: String?],
        _ body: () throws -> Void,
    ) rethrows {
        lock.lock()
        defer { lock.unlock() }

        let previous = overrides.keys.reduce(into: [String: String?]()) { saved, key in
            saved[key] = ProcessInfo.processInfo.environment[key]
        }
        defer { for (key, value) in previous {
            apply(key, value)
        } }

        for (key, value) in overrides {
            apply(key, value)
        }
        try body()
    }

    /// Hold the lock without changing anything — for a test that only reads the
    /// ambient environment and must not see another suite's override.
    static func withStableEnvironment(_ body: () throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        try body()
    }

    private static func apply(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
