import Foundation

// MARK: - Bootstrap packages status

/// Reads a `bootstrap.status` reply while `bootstrap.packages` runs.
///
/// The VM drops a silent guest at 120 s and the whole exchange at 180 s while
/// the guest carries on, and installing the packages takes far longer, so the
/// reply is usually lost and the status is the only signal left.
/// `packages` is the discriminator:
/// the Irisin install sets statuses without it, and reading one of those as
/// this call would end the wait on a stale reading.
enum VPhoneBootstrapPackagesStatus {
    enum Outcome: Equatable {
        case running
        case completed([String])
        /// vphoned declined the work and said why: Irisin's Apple TV package
        /// has no irisin-cli. The reason is a note, not a package name.
        case skipped(String)
        /// The guest's reason, empty when it gave none. The caller localizes
        /// the empty case; this type is built without the string table.
        case failed(String)
    }

    /// The reply to `bootstrap.packages`, when one arrives before the relay
    /// deadline. Every path that answers this quickly is a path that never
    /// reached the long work, so none of them appear in a status.
    static func outcome(forReply reply: [String: Any]) -> Outcome {
        if let skipped = reply["skipped"] as? String {
            return .skipped(skipped)
        }
        return .completed(reply["packages"] as? [String] ?? [])
    }

    /// `nil` when the status belongs to something other than this call.
    static func outcome(for status: [String: Any]) -> Outcome? {
        guard let packages = status["packages"] as? [String] else { return nil }
        switch status["phase"] as? String {
        case "completed":
            return .completed(packages)
        case "failed":
            return .failed(status["message"] as? String ?? "")
        default:
            // Including a phase this build does not know: the guest is still
            // working, and giving up would report a failure that never happened.
            return .running
        }
    }
}
