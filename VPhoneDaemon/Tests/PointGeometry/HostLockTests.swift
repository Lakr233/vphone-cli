import Foundation

enum ControlError: Error { case guestError(String) }
@MainActor final class VPhoneGuestControl {
    var calls: [String] = []
    var locked: Any = true
    var fail = false
    func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        calls.append(method)
        guard method == "device.snapshot", !fail else { throw ControlError.guestError("geometry unavailable or RPC failed") }
        return ["lock": ["locked": locked]]
    }
    func sendRequest(_ request: [String: Any]) async throws -> ([String: Any], Data) {
        throw ControlError.guestError("unexpected legacy request")
    }
}

// The runner joins this file to the actual production extension so its private
// polling function can be exercised without changing the production visibility.
extension VPhoneGuestControl {
    func checkLock(until deadline: ContinuousClock.Instant) async throws -> Bool {
        try await waitForLockScreen(until: deadline)
    }
}

@main @MainActor enum HostLockTests {
    static func main() async throws {
        let control = VPhoneGuestControl()
        // device.screen would fail with orientation 0. Independent lock state
        // remains available, without making a geometry or capture request.
        let locked = try await control.checkLock(until: .now + .seconds(5))
        precondition(locked && control.calls == ["device.snapshot"])
        control.calls = []
        let expired = try await control.checkLock(until: .now - .seconds(1))
        precondition(!expired && control.calls.isEmpty)
        control.locked = NSNumber(value: 1)
        let numeric = try await control.checkLock(until: .now + .milliseconds(5))
        precondition(!numeric && control.calls == ["device.snapshot"])
        control.calls = []
        control.fail = true
        do {
            _ = try await control.checkLock(until: .now + .seconds(2))
            preconditionFailure("RPC error was hidden")
        } catch ControlError.guestError {}
        precondition(control.calls == ["device.snapshot"])
        control.calls = []
        let task = Task { try await control.checkLock(until: .now + .seconds(5)) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancellation was hidden") }
        catch is CancellationError {}
        precondition(control.calls.isEmpty)
        print("Geometry-independent lock polling, timeout, error and cancellation checks passed")
    }
}
