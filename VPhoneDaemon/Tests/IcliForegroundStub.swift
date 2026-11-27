import Foundation

// The IcliKit surface shared by every runner that compiles the daemon's
// verified-foreground check: the error type and the foreground and running
// application answers a test sets through SemanticInputWitness.
public enum IcliError: Error {
    case failed(String), unavailable(String)
    public var code: String { "unavailable" }
    public var message: String { switch self { case let .failed(s), let .unavailable(s): s } }
}

public enum SemanticInputWitness {
    nonisolated(unsafe) public static var foreground: [String: Any] = [:]
    nonisolated(unsafe) public static var apps: [[String: Any]] = []
    /// The process list `listProcesses` answers with; `nil` makes it throw.
    nonisolated(unsafe) public static var processes: [[String: Any]]? = []
    nonisolated(unsafe) public static var axPID = 42
    nonisolated(unsafe) public static var elements: [[String: Any]] = []
    nonisolated(unsafe) public static var truncated = false
    nonisolated(unsafe) public static var queriedWidths: [Double] = []
    nonisolated(unsafe) public static var afterQuery: (() -> Void)?
}
public func frontmostApp() -> [String: Any] { SemanticInputWitness.foreground }
public func runningApps() throws -> [String: Any] { ["apps": SemanticInputWitness.apps] }
// The real listProcesses is in IcliSystem, which IcliKit re-exports.
public func listProcesses(filter: String?) throws -> [String: Any] {
    guard let rows = SemanticInputWitness.processes else { throw IcliError.failed("process list unavailable") }
    return ["processes": rows, "count": rows.count]
}
