import Foundation

// MARK: - VPhoneRestoreIdentity

/// How a device is named on the command line: a hex ECID and an optional UDID.
///
/// Both functions reproduce `scripts/pymobiledevice3_bridge.py` exactly —
/// `parse_ecid` and `normalize_udid` — because the same strings come out of a
/// bundle's `udid-prediction.txt`, out of `make restore*`, and off users'
/// shell histories.
public enum VPhoneRestoreIdentity {
    // MARK: ECID

    /// Python's `parse_ecid`.
    ///
    /// - `nil` and `""` are "no ECID given", not an error — the caller then
    ///   targets whatever single device is attached.
    /// - A `0x` prefix is optional and case-insensitive.
    /// - A value that is nothing but the prefix, or nothing but whitespace, is
    ///   `.ecidEmpty`.
    /// - A non-hex character anywhere is `.ecidInvalid`, reporting the value as
    ///   it was typed.
    public static func parseECID(_ value: String?) throws -> UInt64? {
        // `if not value` in Python: None and "" both mean "unset". A value of
        // only whitespace is NOT caught here — it is truthy in Python — and
        // falls through to the empty check below, which is the intent.
        guard let value, !value.isEmpty else { return nil }

        var raw = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if raw.hasPrefix("0x") { raw = raw.dropFirst(2) }

        guard !raw.isEmpty else { throw VPhoneRestoreBackendError.ecidEmpty }
        guard raw.allSatisfy(\.isHexDigitASCII) else {
            throw VPhoneRestoreBackendError.ecidInvalid(value)
        }
        guard raw.count <= 16, let parsed = UInt64(raw, radix: 16) else {
            throw VPhoneRestoreBackendError.ecidTooLarge(value)
        }
        return parsed
    }

    /// The `%016X` form an ECID is written in everywhere in this project — in
    /// a bundle's `udid-prediction.txt`, in a UDID's second half, and in the
    /// `.shsh` filename.
    public static func formatECID(_ ecid: UInt64) -> String {
        String(format: "%016llX", ecid)
    }

    // MARK: UDID

    /// Python's `normalize_udid`, plus the emptiness test its callers then did.
    ///
    /// Python returned `""` for `""` and every call site immediately treated
    /// that as falsy — `if udid_normalized and serial != udid_normalized` — so
    /// an empty UDID meant "match any device". Collapsing it to `nil` here says
    /// the same thing once, at the only place that can still get it wrong.
    ///
    /// The upper-casing is not cosmetic: a UDID read back from usbmuxd or from
    /// `udid-prediction.txt` is upper-case hex, and a lower-case `--udid` would
    /// otherwise match nothing.
    public static func normalizeUDID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Character

private extension Character {
    /// `c not in "0123456789abcdef"`, on a value already lower-cased.
    ///
    /// Not `isHexDigit`: that is true for the full-width and Arabic-Indic digit
    /// forms too, and `UInt64(_:radix:)` would then reject what this accepted.
    var isHexDigitASCII: Bool {
        guard let ascii = asciiValue else { return false }
        return (0x30...0x39).contains(ascii) || (0x61...0x66).contains(ascii)
    }
}
