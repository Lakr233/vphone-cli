import Foundation

struct VPhoneKeychainItem: Identifiable, Hashable {
    let id: String
    let itemClass: String
    let account: String
    let service: String
    let label: String
    let accessGroup: String
    let protection: String
    let server: String
    let value: String
    let valueEncoding: String
    let valueSize: Int
    let created: Date?
    let modified: Date?

    var displayClass: String {
        switch itemClass {
        case "genp": "Password"
        case "inet": "Internet"
        case "cert": "Certificate"
        case "keys": "Key"
        case "idnt": "Identity"
        default: itemClass
        }
    }

    var classIcon: String {
        switch itemClass {
        case "genp": "key.fill"
        case "inet": "globe"
        case "cert": "checkmark.seal.fill"
        case "keys": "lock.fill"
        case "idnt": "person.badge.key.fill"
        default: "questionmark.circle"
        }
    }

    var displayValue: String {
        if value.isEmpty { return "-" }
        if valueEncoding == "base64" {
            return "[\(ByteCountFormatter.string(fromByteCount: Int64(valueSize), countStyle: .file)) binary]"
        }
        return value
    }

    var displayName: String {
        if !label.isEmpty { return label }
        if !account.isEmpty { return account }
        if !service.isEmpty { return service }
        if !server.isEmpty { return server }
        return "(unnamed)"
    }

    var protectionDescription: String {
        switch protection {
        case "ak": "WhenUnlocked"
        case "ck": "AfterFirstUnlock"
        case "dk": "Always"
        case "aku": "WhenUnlocked (ThisDevice)"
        case "cku": "AfterFirstUnlock (ThisDevice)"
        case "dku": "Always (ThisDevice)"
        case "akpu": "WhenPasscodeSet (ThisDevice)"
        default: protection
        }
    }

    var displayDate: String {
        if let modified {
            return Self.dateFormatter.string(from: modified)
        }
        if let created {
            return Self.dateFormatter.string(from: created)
        }
        return "-"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let sqliteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

extension VPhoneKeychainItem {
    init?(index: Int, entry: [String: Any]) {
        guard let cls = entry["class"] as? String else { return nil }

        itemClass = cls
        account = entry["account"] as? String ?? ""
        service = entry["service"] as? String ?? ""
        label = entry["label"] as? String ?? ""
        accessGroup = entry["accessGroup"] as? String ?? ""
        protection = entry["protection"] as? String ?? ""
        server = entry["server"] as? String ?? ""
        value = entry["value"] as? String ?? ""
        valueEncoding = entry["valueEncoding"] as? String ?? ""
        valueSize = (entry["valueSize"] as? NSNumber)?.intValue ?? 0

        if let ts = entry["created"] as? Double {
            created = Date(timeIntervalSince1970: ts)
        } else if let ts = entry["created"] as? NSNumber {
            created = Date(timeIntervalSince1970: ts.doubleValue)
        } else if let str = entry["createdStr"] as? String {
            created = Self.sqliteDateFormatter.date(from: str)
        } else {
            created = nil
        }

        if let ts = entry["modified"] as? Double {
            modified = Date(timeIntervalSince1970: ts)
        } else if let ts = entry["modified"] as? NSNumber {
            modified = Date(timeIntervalSince1970: ts.doubleValue)
        } else if let str = entry["modifiedStr"] as? String {
            modified = Self.sqliteDateFormatter.date(from: str)
        } else {
            modified = nil
        }

        let rowid = (entry["_rowid"] as? NSNumber)?.intValue ?? index
        id = "\(cls)-\(rowid)"
    }
}
