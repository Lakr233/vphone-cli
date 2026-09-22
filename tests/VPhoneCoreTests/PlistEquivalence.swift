import Foundation

/// Compares two property lists for *semantic* equality.
///
/// Byte equality is the wrong bar for the plists in this migration, and not
/// merely a strict one — it is unreachable. `plistlib.dump` and
/// `PropertyListEncoder` disagree about `<data>` line width, `<real>`
/// formatting, indentation and escaping, so matching bytes would mean
/// reimplementing plistlib's writer to no purpose. Nothing downstream hashes
/// or signs these files; every consumer parses them.
///
/// What does matter, and what this checks:
///
/// - **Type identity.** `Int` and `String` are not interchangeable. A version
///   number that becomes `"26"` instead of `26` parses fine and then fails
///   somewhere far away.
/// - **Array order.** `BuildIdentities` and `SystemRestoreImageFileSystems`
///   are ordered; position carries meaning.
/// - **`Data` contents**, byte for byte.
/// - **Exact key sets.** Neither extra keys nor missing ones.
///
/// Note `plutil -p` does not do this job: it parses and pretty-prints, so it
/// is neither a byte comparison nor a typed one.
enum PlistEquivalence {
    /// A difference, described by where it is rather than just that it exists.
    struct Difference: CustomStringConvertible, Equatable {
        /// Key path into the plist, e.g. `BuildIdentities[0].Info.DeviceClass`.
        let path: String
        let detail: String

        var description: String { "\(path.isEmpty ? "<root>" : path): \(detail)" }
    }

    static func differences(
        between lhs: Any,
        and rhs: Any,
        at path: String = ""
    ) -> [Difference] {
        // Dictionaries: compare key sets first so a missing key is reported as
        // a missing key, not as a mismatch at some deeper path.
        if let l = lhs as? [String: Any], let r = rhs as? [String: Any] {
            var found: [Difference] = []
            let onlyLeft = Set(l.keys).subtracting(r.keys).sorted()
            let onlyRight = Set(r.keys).subtracting(l.keys).sorted()
            if !onlyLeft.isEmpty {
                found.append(Difference(path: path, detail: "only on the left: \(onlyLeft.joined(separator: ", "))"))
            }
            if !onlyRight.isEmpty {
                found.append(Difference(path: path, detail: "only on the right: \(onlyRight.joined(separator: ", "))"))
            }
            for key in Set(l.keys).intersection(r.keys).sorted() {
                found += differences(
                    between: l[key]!, and: r[key]!,
                    at: path.isEmpty ? key : "\(path).\(key)"
                )
            }
            return found
        }

        if let l = lhs as? [Any], let r = rhs as? [Any] {
            guard l.count == r.count else {
                return [Difference(path: path, detail: "\(l.count) elements on the left, \(r.count) on the right")]
            }
            return (0..<l.count).flatMap {
                differences(between: l[$0], and: r[$0], at: "\(path)[\($0)]")
            }
        }

        // Scalars. NSNumber is checked before the rest because a plist bool and
        // a plist integer both arrive as NSNumber, and conflating them is
        // exactly the class of bug this is here to catch.
        if let l = lhs as? NSNumber, let r = rhs as? NSNumber {
            let lIsBool = CFGetTypeID(l) == CFBooleanGetTypeID()
            let rIsBool = CFGetTypeID(r) == CFBooleanGetTypeID()
            if lIsBool != rIsBool {
                return [Difference(
                    path: path,
                    detail: "one is a boolean and the other is a number (\(l) vs \(r))"
                )]
            }
            return l == r ? [] : [Difference(path: path, detail: "\(l) vs \(r)")]
        }

        if let l = lhs as? String, let r = rhs as? String {
            return l == r ? [] : [Difference(path: path, detail: "\"\(l)\" vs \"\(r)\"")]
        }

        if let l = lhs as? Data, let r = rhs as? Data {
            if l == r { return [] }
            return [Difference(
                path: path,
                detail: "data differs (\(l.count) vs \(r.count) bytes)"
            )]
        }

        if let l = lhs as? Date, let r = rhs as? Date {
            return l == r ? [] : [Difference(path: path, detail: "\(l) vs \(r)")]
        }

        return [Difference(
            path: path,
            detail: "different types: \(type(of: lhs)) vs \(type(of: rhs))"
        )]
    }

    /// Parse two plist files and report every semantic difference.
    static func differences(betweenFileAt lhs: URL, andFileAt rhs: URL) throws -> [Difference] {
        let left = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: lhs), format: nil
        )
        let right = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: rhs), format: nil
        )
        return differences(between: left, and: right)
    }
}
