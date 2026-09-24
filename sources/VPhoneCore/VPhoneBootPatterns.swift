import Foundation

// MARK: - VPhoneBootPatterns

/// Boot-log matching and device-identity normalization used by `vm create`.
public enum VPhoneBootPatterns {
    /// Kernel panic marker in the guest serial log.
    public static let panicRegex = #"(^|[^p])(panic|kernel panic|panic\.apple\.com|stackshot succeeded)"#

    /// Accept 1-16 ASCII hex digits, with an optional 0x prefix.
    public static func normalizeECID(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("0x") { value.removeFirst(2) }
        if value.hasPrefix("0X") { value.removeFirst(2) }
        guard !value.isEmpty, value.count <= 16, value.allSatisfy(isASCIIHexDigit) else {
            return nil
        }
        return String(repeating: "0", count: 16 - value.count) + value.uppercased()
    }

    /// ASCII-only hex digit check (`[0-9A-Fa-f]`) — deliberately narrower than
    /// `Character.isHexDigit`, which also accepts Unicode fullwidth digits
    /// that the shell's `[[ =~ ^[0-9A-Fa-f]{1,16}$ ]]` would reject.
    private static func isASCIIHexDigit(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return (0x30...0x39).contains(ascii) || (0x41...0x46).contains(ascii) || (0x61...0x66).contains(ascii)
    }

    // `parseHVVmmPresent` lived here: the string form of `sysctl -n
    // kern.hv_vmm_present`, trimmed and compared to "1". It went when its one
    // caller stopped spawning sysctl — `VPhoneCreateOrchestrator.isNestedVMHost`
    // reads the int with `sysctlbyname` now, so there is no text to parse.
}
