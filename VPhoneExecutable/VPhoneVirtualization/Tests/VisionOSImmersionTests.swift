import Foundation

enum VPhoneLocalization { static let bundle = Bundle.main }

@main
@MainActor
struct VisionOSImmersionTests {
    static func main() async throws {
        let store = Store()
        let model = VPhoneVisionOSImmersionModel { method, params in
            precondition(Set(params.keys) == ["level"])
            store.calls.append((method, params["level"] as! Double))
            if store.reject { throw Refused() }
        }
        precondition(!model.isVisible && !model.isEnabled)
        try await model.setLevel(.full)
        precondition(store.calls.isEmpty)
        model.updateConnection(connected: true, capabilities: ["touch"])
        precondition(!model.isVisible && !model.isEnabled)
        try await model.setLevel(.full)
        precondition(store.calls.isEmpty)
        model.updateConnection(connected: false, capabilities: ["visionos_immersion"])
        precondition(model.isVisible && !model.isEnabled)
        try await model.setLevel(.full)
        precondition(store.calls.isEmpty)

        model.updateConnection(connected: true, capabilities: ["visionos_immersion"])
        for level in VPhoneVisionOSImmersionModel.Level.allCases {
            try await model.setLevel(level)
            precondition(store.calls.last?.0 == "visionos.immersion.set")
            precondition(store.calls.last?.1 == level.rawValue)
            precondition(model.isEnabled && !model.isBusy)
        }
        precondition(store.calls.map(\.1) == [0, 0.5, 1])
        store.reject = true
        do {
            try await model.setLevel(.half)
            preconditionFailure("A current request's failure must reach the menu alert")
        } catch is Refused {}
        precondition(model.isEnabled && !model.isBusy)

        let delayedStore = Store()
        let delayed = VPhoneVisionOSImmersionModel { method, params in
            delayedStore.calls.append((method, params["level"] as! Double))
            try await withCheckedThrowingContinuation { delayedStore.pending.append($0) }
        }
        delayed.updateConnection(connected: true, capabilities: ["visionos_immersion"])
        let oldRequest = Task { try await delayed.setLevel(.full) }
        while delayedStore.pending.isEmpty { await Task.yield() }
        precondition(delayed.isVisible && delayed.isBusy && !delayed.isEnabled)
        try await delayed.setLevel(.half)
        precondition(delayedStore.calls.count == 1)
        delayed.updateConnection(connected: false, capabilities: [])
        precondition(!delayed.isVisible && !delayed.isEnabled && !delayed.isBusy)
        delayed.updateConnection(connected: true, capabilities: ["visionos_immersion"])
        let newRequest = Task { try await delayed.setLevel(.half) }
        while delayedStore.pending.count < 2 { await Task.yield() }
        delayedStore.pending[0].resume(throwing: Refused())
        try await oldRequest.value
        precondition(delayed.isBusy && !delayed.isEnabled)
        delayedStore.pending[1].resume()
        try await newRequest.value
        precondition(delayed.isEnabled && !delayed.isBusy)
        delayed.updateConnection(connected: true, capabilities: ["apps"])
        precondition(!delayed.isVisible && !delayed.isEnabled)
        print("visionOS immersion: capability gating, exact RPC levels, failure, duplicate suppression and reconnect isolation passed")
    }

    struct Refused: Error {}

    @MainActor
    final class Store {
        var calls: [(String, Double)] = []
        var reject = false
        var pending: [CheckedContinuation<Void, any Error>] = []
    }
}
