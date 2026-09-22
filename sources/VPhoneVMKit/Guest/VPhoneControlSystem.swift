import Foundation

extension VPhoneControl {
    // MARK: - URL

    func openURL(_ url: String) async throws {
        let (resp, _) = try await sendRequest(["t": "open_url", "url": url])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "failed to open URL"
            throw ControlError.guestError(msg)
        }
    }

    // MARK: - Settings

    func settingsGet(domain: String, key: String? = nil) async throws -> Any? {
        var req: [String: Any] = ["t": "settings_get", "domain": domain]
        if let key { req["key"] = key }
        let (resp, _) = try await sendRequest(req)
        return resp["value"]
    }

    func settingsSet(domain: String, key: String, value: Any, type: String? = nil) async throws {
        var req: [String: Any] = ["t": "settings_set", "domain": domain, "key": key, "value": value]
        if let type { req["type"] = type }
        _ = try await sendRequest(req)
    }

    func lowPowerMode(enabled: Bool) async throws {
        let (resp, _) = try await sendRequest(["t": "low_power_mode", "enabled": enabled])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            throw ControlError.guestError("low_power_mode: failed to set state on guest")
        }
    }

    // MARK: - Accessibility

    func accessibilityTree(depth: Int = -1) async throws -> [String: Any] {
        guard guestCaps.contains("accessibility_tree") else {
            throw ControlError.unsupportedCapability("accessibility_tree")
        }
        let (resp, _) = try await sendRequest(["t": "accessibility_tree", "depth": depth])
        return resp
    }
}
