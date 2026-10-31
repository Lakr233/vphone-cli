/// Read-only completion policy. Apple TV uses its TV setup version and
/// completion flag; iPhone and HomePod retain the existing iOS-version policy.
struct GuestSetupAssistantState {
    static func usesTVPolicy(machine: String) -> Bool { machine.hasPrefix("AppleTV") }

    static func usesHomeViewPolicy(machine: String) -> Bool { machine.hasPrefix("HomeAccessory") }

    let setupDone: Bool
    let version: Int?
    let currentVersion: Int?
    let requiresTVCompletion: Bool
    let tvCompleted: Bool

    var requiresHomeViewCompletion = false
    var forceNoBuddy = false

    var pending: Bool {
        if requiresHomeViewCompletion { return !setupDone && !forceNoBuddy }
        guard setupDone else { return true }
        if requiresTVCompletion && (currentVersion == nil || !tvCompleted) { return true }
        if let currentVersion, (version ?? 0) < currentVersion { return true }
        return false
    }
}
