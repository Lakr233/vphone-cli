// PatcherProtocol.swift — Common protocol for all firmware patchers.

import Foundation

/// A firmware patcher that can find and apply patches to a binary buffer.
public protocol Patcher {
    /// The component name (e.g., "kernelcache", "ibss", "txm").
    var component: String { get }

    /// Whether to print verbose output.
    var verbose: Bool { get }

    /// Find all patch sites and return patch records (dry-run mode).
    func findAll() throws -> [PatchRecord]

    /// Apply all patches to the buffer. Returns the number of patches applied.
    @discardableResult
    func apply() throws -> Int
}

extension Patcher {
    /// Log a message if verbose mode is enabled.
    func log(_ message: String) {
        if verbose {
            print(message)
        }
    }
}
