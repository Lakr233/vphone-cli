import Foundation

enum VPhoneLocalization { static let bundle = Bundle.main }

@main
@MainActor
struct HomeViewDistanceTests {
    static func main() async {
        let store = Store()
        let model = VPhoneHomeViewDistanceModel { method, params in
            store.calls.append((method, params["mode"] as? String))
            if method == "homeview.distance.set", params["mode"] as? String == "automatic" {
                precondition(params["reset_environment"] as? Bool == true)
            }
            if store.unavailable { return ["available": false, "reason": "Native service unavailable"] }
            if method == "homeview.distance.set", !store.rejectsWrite { store.state = params["mode"] as! String }
            return ["available": true, "mode": store.state, "applied": !store.rejectsWrite,
                "level_of_detail": store.state == "near" ? 2 : store.state == "far" ? 0 : 1,
                "override_active": store.state != "automatic"]
        }
        await model.refresh()
        precondition(model.isAvailable && model.mode == .automatic && model.error == nil)
        for mode in VPhoneHomeViewDistanceModel.Mode.allCases {
            model.selection = mode
            await model.apply()
            precondition(model.mode == mode && model.error == nil && !model.isBusy)
            precondition(store.calls.last?.0 == "homeview.distance.set" && store.calls.last?.1 == mode.rawValue)
        }
        store.rejectsWrite = true
        model.selection = .near
        await model.apply()
        precondition(model.error != nil && model.mode == nil && !model.isAvailable)
        let refusedCount = store.calls.count
        await model.apply()
        precondition(store.calls.count == refusedCount)
        store.rejectsWrite = false
        await model.refresh()
        precondition(model.mode == .far && model.isAvailable && model.error == nil)
        store.unavailable = true
        await model.refresh()
        precondition(!model.isAvailable && model.mode == nil && model.error == "Native service unavailable")
        let count = store.calls.count
        await model.apply()
        precondition(store.calls.count == count)

        let malformed = VPhoneHomeViewDistanceModel { _, _ in ["available": true, "mode": "unknown"] }
        await malformed.refresh()
        precondition(!malformed.isAvailable && malformed.mode == nil && malformed.error != nil)
        let unowned = VPhoneHomeViewDistanceModel { _, _ in
            ["available": true, "mode": "unknown", "level_of_detail": 2, "override_active": NSNull()]
        }
        await unowned.refresh()
        precondition(unowned.isAvailable && unowned.mode == nil && unowned.error == nil)
        let stale = VPhoneHomeViewDistanceModel { _, _ in
            ["available": true, "mode": "near", "level_of_detail": 0, "override_active": true]
        }
        await stale.refresh()
        precondition(!stale.isAvailable && stale.mode == nil && stale.error != nil)
        let failed = VPhoneHomeViewDistanceModel { _, _ in throw NSError(domain: "test", code: 1) }
        await failed.refresh()
        precondition(!failed.isBusy && !failed.isAvailable && failed.error != nil)
        // Transport failure does not prove a write was rejected. The simulated
        // guest commits Near, then loses its reply; Refresh must discover Near.
        let uncertainStore = Store()
        let uncertain = VPhoneHomeViewDistanceModel { method, params in
            if method == "homeview.distance.set" {
                uncertainStore.state = params["mode"] as! String
                throw NSError(domain: "reply lost", code: 1)
            }
            return ["available": true, "mode": uncertainStore.state, "applied": false,
                "level_of_detail": uncertainStore.state == "near" ? 2 : 1,
                "override_active": uncertainStore.state != "automatic"]
        }
        await uncertain.refresh()
        uncertain.selection = .near
        await uncertain.apply()
        precondition(uncertain.mode == nil && !uncertain.isAvailable && uncertain.error != nil)
        await uncertain.refresh()
        precondition(uncertain.mode == .near && uncertain.isAvailable && uncertain.error == nil)
        let delayedStore = Store()
        let delayed = VPhoneHomeViewDistanceModel { _, _ in
            if delayedStore.calls.isEmpty {
                delayedStore.calls.append(("held read", nil))
                return await withCheckedContinuation { delayedStore.pending = $0 }
            }
            return ["available": true, "mode": "far", "level_of_detail": 0, "override_active": true]
        }
        let oldRead = Task { await delayed.refresh() }
        while delayedStore.pending == nil { await Task.yield() }
        delayed.disconnected()
        precondition(delayed.mode == nil && !delayed.isAvailable && !delayed.isBusy)
        await delayed.refresh()
        precondition(delayed.mode == .far)
        delayedStore.pending?.resume(returning:
            ["available": true, "mode": "near", "level_of_detail": 2, "override_active": true])
        await oldRead.value
        precondition(delayed.mode == .far && delayed.isAvailable && !delayed.isBusy)
        print("HomeView distance controls: readback, all modes, refusal, unavailable service and invalid replies passed")
    }
    @MainActor
    final class Store {
        var calls: [(String, String?)] = []
        var state = "automatic"
        var rejectsWrite = false
        var unavailable = false
        var pending: CheckedContinuation<[String: Any], Never>?
    }

}
