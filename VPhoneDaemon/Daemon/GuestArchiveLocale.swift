import xlocale

/// Icli's ZIP reader converts pathnames into the calling thread's codeset.
/// Keep this synchronous: the temporary locale must stay on the same thread.
enum GuestArchiveLocale {
    enum Failure: Error, CustomStringConvertible {
        case allocation, unavailable, selection

        var description: String {
            switch self {
            case .allocation: "Unable to allocate the IPA extraction locale."
            case .unavailable: "The UTF-8 locale required for IPA extraction is unavailable."
            case .selection: "Unable to select the IPA extraction locale."
            }
        }
    }

    static func withUTF8<T>(_ operation: () throws -> T) throws -> T {
        guard let previous = uselocale(nil), let copy = duplocale(previous) else {
            throw Failure.allocation
        }
        // Preserve every other locale category and avoid process-wide setlocale:
        // GuestAPI operations run concurrently on different worker threads.
        guard let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", copy) else {
            freelocale(copy)
            throw Failure.unavailable
        }
        guard uselocale(utf8) != nil else {
            freelocale(utf8)
            throw Failure.selection
        }
        defer {
            uselocale(previous)
            freelocale(utf8)
        }
        return try operation()
    }
}
