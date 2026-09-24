import Foundation

extension VPhoneControl {
    // MARK: - Keychain Operations

    struct KeychainResult {
        let items: [[String: Any]]
        let diagnostics: [String]
    }

    func listKeychainItems() async throws -> KeychainResult {
        let req: [String: Any] = ["t": "keychain_list"]
        let (resp, _) = try await sendRequest(req)
        guard let items = resp["items"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing items in keychain response")
        }
        let diag = resp["diag"] as? [String] ?? []
        return KeychainResult(items: items, diagnostics: diag)
    }

    func addKeychainItem(
        account: String = "vphone-test",
        service: String = "vphone",
        password: String = "testpass123"
    ) async throws {
        let req: [String: Any] = [
            "t": "keychain_add", "account": account, "service": service, "password": password,
        ]
        let (resp, _) = try await sendRequest(req)
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "unknown error"
            throw ControlError.protocolError("keychain_add: \(msg)")
        }
    }
}
