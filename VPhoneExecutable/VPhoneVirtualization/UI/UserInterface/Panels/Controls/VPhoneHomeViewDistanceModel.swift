import Foundation
import Observation

/// The guest owns the distance-to-detail mapping. No arbitrary metre values
/// are invented for a sensor whose calibration is specific to the hardware.
@MainActor
@Observable
final class VPhoneHomeViewDistanceModel {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic, near, standard, far
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic", bundle: VPhoneLocalization.bundle)
            case .near: String(localized: "Near", bundle: VPhoneLocalization.bundle)
            case .standard: String(localized: "Standard Detail", bundle: VPhoneLocalization.bundle)
            case .far: String(localized: "Far", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    typealias Request = @MainActor (String, [String: Any]) async throws -> [String: Any]
    @ObservationIgnored private let request: Request
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    var selection = Mode.standard
    private(set) var mode: Mode?
    private(set) var isAvailable = false
    private(set) var isBusy = false
    private(set) var error: String?

    init(request: @escaping Request) { self.request = request }

    func disconnected() {
        connectionGeneration &+= 1
        mode = nil
        isAvailable = false
        isBusy = false
        error = nil
    }

    func refresh() async {
        guard !isBusy else { return }
        let generation = connectionGeneration
        isBusy = true
        defer { if generation == connectionGeneration { isBusy = false } }
        do {
            let value = try await request("homeview.distance.get", [:])
            guard generation == connectionGeneration else { return }
            try receive(value)
            if let mode { selection = mode }
            error = nil
        } catch {
            guard generation == connectionGeneration else { return }
            isAvailable = false
            mode = nil
            self.error = String(describing: error)
        }
    }

    func apply() async {
        guard isAvailable, !isBusy else { return }
        let generation = connectionGeneration
        let wanted = selection
        isBusy = true
        defer { if generation == connectionGeneration { isBusy = false } }
        do {
            var params: [String: Any] = ["mode": wanted.rawValue]
            if wanted == .automatic { params["reset_environment"] = true }
            let value = try await request("homeview.distance.set", params)
            guard generation == connectionGeneration else { return }
            guard value["applied"] as? Bool == true else {
                throw DistanceError("The guest did not confirm the distance change.")
            }
            try receive(value)
            guard mode == wanted else { throw DistanceError("The guest reported a different distance override.") }
            error = nil
        } catch {
            guard generation == connectionGeneration else { return }
            // A lost reply can follow a committed native write. Refresh before
            // presenting a current mode or allowing another mutation.
            mode = nil
            isAvailable = false
            self.error = String(describing: error)
        }
    }

    private func receive(_ value: [String: Any]) throws {
        guard value["available"] as? Bool == true else {
            throw DistanceError(value["reason"] as? String ?? "Distance simulation is unavailable in this guest environment.")
        }
        guard let detail = value["level_of_detail"] as? Int, (0 ... 2).contains(detail),
              let raw = value["mode"] as? String else {
            throw DistanceError("The guest returned an invalid distance state.")
        }
        // Effective detail alone does not identify the active override. A newly
        // connected daemon must not label another client's state Automatic.
        if raw == "unknown", value["override_active"] is NSNull {
            mode = nil
            isAvailable = true
            return
        }
        guard let received = Mode(rawValue: raw),
              let overridden = value["override_active"] as? Bool,
              overridden == (received != .automatic) else {
            throw DistanceError("The guest returned inconsistent distance state.")
        }
        let expected: Int? = switch received {
        case .automatic: nil
        case .near: 2
        case .standard: 1
        case .far: 0
        }
        if let expected, detail != expected {
            throw DistanceError("The guest has not applied the requested distance detail level.")
        }
        mode = received
        isAvailable = true
    }

    private struct DistanceError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
