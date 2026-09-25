import Foundation

/// Methods beyond the original surface live in one file per area. Each area
/// returns nil for a method it does not own, so the first match answers.
extension GuestAPI {
    static func executeExtended(method: String, params: [String: Any]) throws -> [String: Any]? {
        let areas: [(String, [String: Any]) throws -> [String: Any]?] = [
            executeDevice,
            executeInput,
            executeInterface,
            executeProcess,
            executeService,
            executeLog,
            executeAppDetail,
            executeFileTool,
            executeEnvironment,
        ]
        for area in areas {
            if let result = try area(method, params) {
                return result
            }
        }
        return nil
    }
}
