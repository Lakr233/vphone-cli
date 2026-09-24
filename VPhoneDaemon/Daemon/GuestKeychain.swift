import Foundation
import IcliKit

/// Keep the existing vphoned response shape while IcliKit owns both Keychain
/// queries. Neither listing asks Security.framework for item data.
enum GuestKeychain {
    static func list(className: String?) throws -> [String: Any] {
        let requested = try libraryClass(className)
        var items: [[String: Any]] = []
        var diagnostics: [String] = []
        var succeeded = false

        do {
            let result = try listKeychain(
                className: requested,
                service: nil,
                account: nil,
                server: nil,
                group: nil,
                includeData: false,
            )
            let rows = result["items"] as? [[String: Any]] ?? []
            items += rows.map(adaptItem)
            diagnostics.append("Security: \(rows.count) accessible items")
            succeeded = true
        } catch {
            diagnostics.append("Security: \(error)")
        }

        if requested != "identity" {
            do {
                let result = try listKeychainDatabaseMetadata(className: requested)
                let rows = result["items"] as? [[String: Any]] ?? []
                items += rows.map(adaptItem)
                diagnostics.append("Database: \(rows.count) protected metadata rows")
                succeeded = true
            } catch {
                diagnostics.append("Database: \(error)")
            }
        }

        guard succeeded else {
            throw GuestAPIError.operationFailed(diagnostics.joined(separator: "; "))
        }
        if items.contains(where: { $0["source"] as? String == "security" }) {
            diagnostics.append("Accessible attributes may also appear as protected database rows")
        }
        return ["items": items, "count": items.count, "diag": diagnostics]
    }

    static func add(account: String, service: String, password: String) throws -> [String: Any] {
        // IcliKit returns item data on add; only status crosses the VM boundary.
        _ = try addKeychain(
            className: "generic_password",
            service: service,
            account: account,
            server: nil,
            label: "\(service) (\(account))",
            group: nil,
            data: password,
        )
        return ["ok": true, "status": 0]
    }

    static func delete(account: String, service: String) throws -> [String: Any] {
        let result = try deleteKeychain(
            className: "generic_password",
            service: service,
            account: account,
            server: nil,
            group: nil,
        )
        return ["ok": true, "removed": result["deleted"] as? Bool ?? false]
    }

    private static func libraryClass(_ className: String?) throws -> String? {
        switch className ?? "" {
        case "": nil
        case "genp", "generic_password", "generic": "generic_password"
        case "inet", "internet_password", "internet": "internet_password"
        case "cert", "certificate": "certificate"
        case "keys", "key": "key"
        case "idnt", "identity": "identity"
        default: throw GuestAPIError.invalidRequest("Unknown keychain class")
        }
    }

    private static func adaptItem(_ item: [String: Any]) -> [String: Any] {
        var adapted = item
        switch item["class"] as? String {
        case "generic_password": adapted["class"] = "genp"
        case "internet_password": adapted["class"] = "inet"
        case "certificate": adapted["class"] = "cert"
        case "key": adapted["class"] = "keys"
        case "identity": adapted["class"] = "idnt"
        default: break
        }
        if let group = item["group"] {
            adapted["accessGroup"] = group
        }
        if let rowID = item["rowid"] {
            adapted["_rowid"] = rowID
        }
        adapted["valueEncoding"] = "protected"
        adapted.removeValue(forKey: "data")
        return adapted
    }
}
