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
            let rows = try rows(from: result, operation: "Security")
            items += rows.map(adaptItem)
            diagnostics.append("Security: \(rows.count) accessible items")
            succeeded = true
        } catch {
            diagnostics.append("Security: \(error)")
        }

        if requested != "identity" {
            do {
                let result = try listKeychainDatabaseMetadata(className: requested)
                let rows = try rows(from: result, operation: "Database")
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

    /// Reads one item's value. Only the Security.framework side holds data, so
    /// a row that only exists as protected database metadata cannot answer.
    static func get(_ identity: Identity) throws -> [String: Any] {
        let result = try getKeychain(
            className: identity.className,
            service: identity.service,
            account: identity.account,
            server: identity.server,
            group: identity.group,
        )
        let items = try rows(from: result, operation: "Security")
        guard let item = items.first else {
            throw GuestAPIError.notFound("Keychain item not found")
        }
        return ["ok": true, "value": item["data"] as? String ?? ""]
    }

    /// Replaces one item's value. The new value crosses the VM boundary as
    /// text and is stored as its UTF-8 bytes.
    static func update(_ identity: Identity, value: String) throws -> [String: Any] {
        guard let account = identity.account, !account.isEmpty else {
            throw GuestAPIError.invalidRequest("account is required", hint: "Pass a non-empty account")
        }
        // IcliKit reads the item back after updating; only status crosses the
        // VM boundary.
        _ = try updateKeychain(
            className: identity.className,
            service: identity.service,
            account: account,
            server: identity.server,
            group: identity.group,
            data: value,
        )
        return ["ok": true]
    }

    static func delete(_ identity: Identity) throws -> [String: Any] {
        let result = try deleteKeychain(
            className: identity.className,
            service: identity.service,
            account: identity.account,
            server: identity.server,
            group: identity.group,
        )
        return ["ok": true, "removed": result["deleted"] as? Bool ?? false]
    }

    /// The attributes that name one item for Security.framework. An empty
    /// attribute is left out of the query, so an identity that carries none
    /// would match every item in its class and is refused.
    struct Identity {
        let className: String
        let account: String?
        let service: String?
        let server: String?
        let group: String?

        init(_ params: [String: Any]) throws {
            guard let resolved = try libraryClass(params["class"] as? String ?? "genp") else {
                throw GuestAPIError.invalidRequest("class is required", hint: "class is genp, inet, cert, key or idnt")
            }
            className = resolved
            account = Self.attribute(params, "account")
            service = Self.attribute(params, "service")
            server = Self.attribute(params, "server")
            group = Self.attribute(params, "group") ?? Self.attribute(params, "accessGroup")
            guard account != nil || service != nil || server != nil else {
                throw GuestAPIError.invalidRequest("account, service, or server is required", hint: "Pass at least one of account, service or server")
            }
        }

        private static func attribute(_ params: [String: Any], _ key: String) -> String? {
            guard let value = params[key] as? String, !value.isEmpty else { return nil }
            return value
        }
    }

    private static func libraryClass(_ className: String?) throws -> String? {
        switch className ?? "" {
        case "": nil
        case "genp", "generic_password", "generic": "generic_password"
        case "inet", "internet_password", "internet": "internet_password"
        case "cert", "certificate": "certificate"
        case "keys", "key": "key"
        case "idnt", "identity": "identity"
        default: throw GuestAPIError.invalidRequest("Unknown keychain class", hint: "class is genp, inet, cert, key or idnt")
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
        // A listing never carries item data. An accessible row can be read one
        // at a time with `keychain.get`; a database row stays encrypted.
        adapted["valueEncoding"] = item["source"] as? String == "security" ? "hidden" : "protected"
        adapted.removeValue(forKey: "data")
        return adapted
    }

    /// Validate the response envelope instead of silently treating a malformed
    /// keychain response as an empty listing.
    private static func rows(
        from result: [String: Any],
        operation: String,
    ) throws -> [[String: Any]] {
        guard let raw = result["items"] else {
            throw GuestAPIError.operationFailed("\(operation) keychain response has no items")
        }
        guard let rows = raw as? [[String: Any]] else {
            throw GuestAPIError.operationFailed("\(operation) keychain response has invalid items")
        }
        return rows
    }
}
