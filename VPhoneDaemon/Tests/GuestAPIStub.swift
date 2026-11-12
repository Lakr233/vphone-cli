import Foundation
enum GuestAPI {
    static func string(_ p: [String: Any], _ k: String) throws -> String { "" }
    static func killRequest(_ p: [String: Any]) throws -> (name: String, pid: Int) { ("", 0) }
    static func servicePaths(_ p: [String: Any]) throws -> [String] { [] }
    static func snapshotDeletion(_ p: [String: Any]) throws -> (mount: String, x: Int) { ("", 0) }
    static func systemAppIDs(_ p: [String: Any]) throws -> [String] { [] }
    static func systemAppsToRemove(_ p: [String: Any]) throws -> [String] { [] }
}
enum GuestPaging {
    static let defaultLimit = 200
    static let maxLimit = 1000
    static func apply(_ r: [String: Any], _ p: MethodSpec.Paged, _ q: [String: Any]) throws -> [String: Any] { r }
}
enum GuestProcessSpawnPolicy {
    static let outputLimit = 64 * 1024
}
