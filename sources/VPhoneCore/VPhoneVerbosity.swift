/// CLI output verbosity. Higher levels are supersets of lower ones.
///
/// The guest VM serial console is deliberately NOT part of this ladder:
/// `vm launch` always streams it, `vm create` never does — neither depends
/// on the verbosity level.
public enum VPhoneVerbosity: Int, Comparable, Sendable {
    case quiet = 0    // tool banners + [*]/[+] markers only
    case info = 1     // + wrapped-subprocess stdout + pmd3 restore log (INFO, colorful)
    case debug = 2    // + pmd3 DEBUG logs (deeper restore detail)
    case trace = 3    // + vphone-cli internal trace (spawned argv/env, managed-process events)

    public static func < (lhs: VPhoneVerbosity, rhs: VPhoneVerbosity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Map a repeated `-v` count (0…N) to a level, clamped to `.trace`.
    public init(count: Int) {
        self = VPhoneVerbosity(rawValue: min(max(count, 0), 3)) ?? .trace
    }

    public var showsToolDetail: Bool { self >= .info }
    public var tracesInternals: Bool { self >= .trace }
}
