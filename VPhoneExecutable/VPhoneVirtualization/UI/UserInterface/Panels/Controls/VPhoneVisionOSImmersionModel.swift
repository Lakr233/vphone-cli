import Foundation

/// A virtual Digital Crown action. Successful requests are acknowledgements,
/// not observations of the headset's current immersion level.
@MainActor
final class VPhoneVisionOSImmersionModel {
    enum Level: Double, CaseIterable {
        case passthrough = 0
        case half = 0.5
        case full = 1

        var title: String {
            switch self {
            case .passthrough: String(localized: "Passthrough", bundle: VPhoneLocalization.bundle)
            case .half: String(localized: "Half Immersion (50%)", bundle: VPhoneLocalization.bundle)
            case .full: String(localized: "Full Environment", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    typealias Request = @MainActor (String, [String: Any]) async throws -> Void
    private let request: Request
    private var connectionGeneration: UInt64 = 0
    private(set) var isVisible = false
    private(set) var isConnected = false
    private(set) var isBusy = false
    var isEnabled: Bool { isVisible && isConnected && !isBusy }

    init(request: @escaping Request) { self.request = request }

    func updateConnection(connected: Bool, capabilities: [String]) {
        connectionGeneration &+= 1
        isVisible = capabilities.contains("visionos_immersion")
        isConnected = connected
        isBusy = false
    }

    func setLevel(_ level: Level) async throws {
        guard isEnabled else { return }
        let generation = connectionGeneration
        isBusy = true
        defer { if generation == connectionGeneration { isBusy = false } }
        do {
            try await request("visionos.immersion.set", ["level": level.rawValue])
        } catch {
            // A reply from the previous agent connection cannot describe the
            // newly connected guest, including whether its action failed.
            guard generation == connectionGeneration else { return }
            throw error
        }
    }
}
