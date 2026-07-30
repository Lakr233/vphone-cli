import Foundation

// MARK: - VPhoneBootPatterns

/// Boot-log regex patterns and device-identity normalization, ported VERBATIM
/// from `scripts/setup_machine.sh` so the native `vm create` orchestrator
/// (`VPhoneCreateOrchestrator`, executable target) matches the proven shell
/// choreography exactly. Lives in VPhoneCore (rather than alongside the
/// orchestrator) purely so `VPhoneCoreTests` can unit-test these pure,
/// device-independent pieces — the orchestrator itself needs `FirmwarePatcher`
/// and can't live in VPhoneCore without creating a package dependency cycle
/// (FirmwarePatcher already depends on VPhoneCore).
public enum VPhoneBootPatterns {
    /// `BOOT_BASH_PROMPT_REGEX` (setup_machine.sh:39) — the iosbinpack bash
    /// prompt, or a ramdisk/root shell prompt.
    public static let promptRegex = #"bash-[0-9]+(\.[0-9]+)+#|:/[^ ]* root#"#

    /// `BOOT_PANIC_REGEX` (setup_machine.sh:40).
    public static let panicRegex = #"(^|[^p])(panic|kernel panic|panic\.apple\.com|stackshot succeeded)"#

    /// `monitor_boot_log_until` (setup_machine.sh:363-388) checks panic and
    /// prompt with DIFFERENT case sensitivity — `grep -Eiq "$BOOT_PANIC_REGEX"`
    /// (case-insensitive) vs. `grep -Eq "$BOOT_BASH_PROMPT_REGEX"` (case-
    /// sensitive). A single `NSRegularExpression` has one global case-folding
    /// setting, so the panic half is wrapped in an ICU scoped inline modifier
    /// (`(?i:...)`) to fold ONLY that half, leaving the prompt half exactly as
    /// case-sensitive as the shell's plain `grep -E`.
    public static let panicOrPromptRegex = "(?i:\(panicRegex))|\(promptRegex)"

    /// `send_first_boot_commands` (setup_machine.sh:344-361) — verbatim order,
    /// including the exact PATH string (setup_machine.sh:348).
    public static let firstBootCommands: [String] = [
        "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'",
        "cp /iosbinpack64/etc/profile /var/profile",
        "cp /iosbinpack64/etc/motd /var/motd",
        "mkdir -p /var/dropbear",
        "dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key",
        "dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key",
        "shutdown -h now",
    ]

    /// Port of `normalize_ecid` (setup_machine.sh:80-86): strip one leading
    /// `0x` and one leading `0X` (matching the shell's two sequential `#0x`/
    /// `#0X` strips), require 1-16 ASCII hex digits, uppercase, and left-pad
    /// with zeros to 16 characters. `nil` for anything that isn't valid hex —
    /// the shell's `return 1` from the `[[ =~ ]]` guard.
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

    /// Pure parse of `sysctl -n kern.hv_vmm_present` output — `"1"` means the
    /// host is itself an Apple VM (nested), where Virtualization.framework
    /// PV=3 guest boot is unavailable. Mirrors the `boot_host_preflight.sh`
    /// gate `make boot` applied before native `vm create` replaced it.
    public static func parseHVVmmPresent(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
