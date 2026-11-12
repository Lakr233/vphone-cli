import Foundation

// Prints "<method><tab><result cell>" for every method, sorted by name. The cell lists the result keys sorted by name
// as name:type[:null][?|~][*] (? optional, ~ hidden, * open), "-" when empty and "missing" when undeclared. Compiled
// by run-methods-tests.sh with GuestMethodSpec.swift, the GuestAPI*Methods.swift files, GuestAPIStub.swift and a
// generated file defining `kinds`. The cell grammar is the one DriftCheck.parseCell reads.
@main
struct MethodsHarness {
    static func main() {
        let rows = kinds.flatMap { $0.entries() }.map { name, spec in
            (name, cell(spec.result))
        }
        for (name, cell) in rows.sorted(by: { $0.0 < $1.0 }) { print("\(name)\t\(cell)") }
    }

    static func cell(_ result: [ResultKey]?) -> String {
        guard let result else { return "missing" }
        if result.isEmpty { return "-" }
        return result.sorted { $0.name < $1.name }.map { key in
            let presence = key.presence == .optional ? "?" : key.presence == .hidden ? "~" : ""
            return "\(key.name):\(key.type.rawValue)\(key.isNullable && key.type != .null ? ":null" : "")\(presence)\(key.isOpen ? "*" : "")"
        }.joined(separator: ",")
    }
}
