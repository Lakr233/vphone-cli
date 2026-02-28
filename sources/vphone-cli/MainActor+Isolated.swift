import Foundation

extension MainActor {
    /// Synchronously execute a block on the main actor.
    /// If already on main thread, runs inline. Otherwise blocks until main thread is available.
    nonisolated static func isolated<T: Sendable>(
        _ block: @MainActor @escaping () throws -> T
    ) rethrows -> T {
        try DispatchQueue.main.asyncAndWait {
            try block()
        }
    }
}
