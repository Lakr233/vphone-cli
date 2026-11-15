// PatcherProtocol.swift — Common protocol for all firmware patchers.

import Foundation

/// A firmware patcher that can find and apply patches to a binary buffer.
public protocol Patcher {
    /// The component name (e.g., "kernelcache", "ibss", "txm").
    var component: String { get }

    /// Whether to print verbose output.
    var verbose: Bool { get }

    /// Which patches the resolved preset turned on.
    ///
    /// Defaults to ``VPhonePatchGate/unrestricted``, so a patcher built directly
    /// applies everything it finds, exactly as it did before presets existed.
    var gate: VPhonePatchGate { get }

    /// Find all patch sites and return patch records (dry-run mode).
    func findAll() throws -> [PatchRecord]

    /// Apply all patches to the buffer. Returns the number of patches applied.
    @discardableResult
    func apply() throws -> Int
}

/// A patcher that owns the bytes it produced.
///
/// The pipeline reads a component's result through this rather than by
/// downcasting to each concrete patcher it happens to know. That is what lets a
/// patcher from a loaded `.vphonepatchset` contribute anything at all: the
/// pipeline has never heard of its type, and a patcher whose bytes it could not
/// read would apply its patches into a buffer nobody saves.
public protocol BufferedPatcher: Patcher {
    /// The component's bytes after ``Patcher/apply()``.
    var patchedData: Data { get }
}

// MARK: - Log sink

/// Where a patcher's verbose lines go. VPhonePatchKit imports only Foundation, so the
/// app points this at its reporting channel; the default is plain `print`.
public enum VPhonePatchLog {
    // Set once before patching starts, read afterwards; no lock needed.
    nonisolated(unsafe) public static var write: @Sendable (String) -> Void = { print($0) }
}

public extension Patcher {
    /// Log a message if verbose mode is enabled.
    func log(_ message: String) {
        if verbose {
            VPhonePatchLog.write(message)
        }
    }

    /// Every patch applies unless the patcher says otherwise.
    var gate: VPhonePatchGate {
        .unrestricted
    }

    /// Whether the site emitting `recordIdentifier` should be written.
    func gateAllows(_ recordIdentifier: String) -> Bool {
        gate.allowsReporting(record: recordIdentifier, component: component, verbose: verbose)
    }
}

public extension VPhonePatchGate {
    /// ``allows(record:)`` with the log line that explains the decision.
    ///
    /// The undeclared case is a manifest gap: the patch still applies, because
    /// dropping bytes over a missing declaration would change the firmware
    /// silently, and its warning prints whether or not verbose is on, so the gap
    /// shows up in an ordinary run.
    func allowsReporting(record recordIdentifier: String, component: String, verbose: Bool) -> Bool {
        if isUnrestricted {
            return true
        }
        if isUndeclared(record: recordIdentifier) {
            print("  [!] \(component): \(recordIdentifier) is declared by no patch set; applying it anyway")
            return true
        }
        if allows(record: recordIdentifier) {
            return true
        }
        if verbose {
            print("  [·] \(recordIdentifier): off in this preset")
        }
        return false
    }
}
