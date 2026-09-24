import Foundation

extension VPhoneControl {
    // MARK: - App Management

    struct AppInfo {
        let bundleId: String
        let name: String
        let version: String
        let type: String
        let state: String
        let pid: Int
        let path: String
    }

    func appList(filter: String = "all") async throws -> [AppInfo] {
        let (resp, _) = try await sendRequest(["t": "app_list", "filter": filter])
        guard let apps = resp["apps"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing apps in response")
        }
        return apps.map { app in
            AppInfo(
                bundleId: app["bundle_id"] as? String ?? "",
                name: app["name"] as? String ?? "",
                version: app["version"] as? String ?? "",
                type: app["type"] as? String ?? "",
                state: app["state"] as? String ?? "",
                pid: app["pid"] as? Int ?? 0,
                path: app["path"] as? String ?? ""
            )
        }
    }

    func appLaunch(bundleId: String, url: String? = nil) async throws -> Int {
        var req: [String: Any] = ["t": "app_launch", "bundle_id": bundleId]
        if let url { req["url"] = url }
        let (resp, _) = try await sendRequest(req)
        return resp["pid"] as? Int ?? 0
    }

    func appTerminate(bundleId: String) async throws {
        _ = try await sendRequest(["t": "app_terminate", "bundle_id": bundleId])
    }

    func appForeground() async throws -> (bundleId: String, name: String, pid: Int) {
        let (resp, _) = try await sendRequest(["t": "app_foreground"])
        return (
            bundleId: resp["bundle_id"] as? String ?? "",
            name: resp["name"] as? String ?? "",
            pid: resp["pid"] as? Int ?? 0
        )
    }
}
