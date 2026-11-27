import CoreFoundation
import Foundation
import IcliKit

// MARK: - Verified foreground

/// The process that owns the interface an accessibility operation targets.
/// `==` compares the process, not how it was identified.
struct ForegroundApp: Equatable {
    let bundle: String
    let pid: Int
    let verified: Bool
    let source: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundle == rhs.bundle && lhs.pid == rhs.pid && lhs.verified == rhs.verified
    }
}

extension GuestAPI {
    static let springboardBundle = "com.apple.springboard"
    private static let springboardExecutable = "/System/Library/CoreServices/SpringBoard.app/SpringBoard"

    /// The foreground process for accessibility work. A verified result is
    /// used as reported. An unverified one is accepted only for SpringBoard's
    /// own UI (Home Screen, Lock Screen), when `frontmostApp()` reports it
    /// without a verified source; every other unverified result fails.
    static func verifiedForeground() throws -> ForegroundApp {
        let front = frontmostApp()
        let source = front["source"] as? String ?? ""
        guard let bundle = front["bundle_id"] as? String, !bundle.isEmpty else {
            throw IcliError.unavailable("Cannot verify the foreground application for accessibility input")
        }
        let verified = foregroundBoolean(front["verified"])
        let springboard = verified == false && bundle == springboardBundle
            && (source == "unavailable" || source == "springboard_query")
        guard verified == true || springboard else {
            throw IcliError.unavailable("Cannot verify the foreground application for accessibility input")
        }
        let pid = bundle == springboardBundle ? try springboardPID() : try appPID(bundle)
        return ForegroundApp(bundle: bundle, pid: pid, verified: verified == true, source: source)
    }

    private static let uniqueProcess = "Cannot verify a unique foreground process for accessibility input"

    /// `runningApps()` never lists SpringBoard, so its pid comes from the
    /// process list: the one row whose executable is SpringBoard's.
    private static func springboardPID() throws -> Int {
        let rows = (try? listProcesses(filter: "SpringBoard"))?["processes"] as? [[String: Any]] ?? []
        let matches = rows.filter { $0["executable"] as? String == springboardExecutable }
        guard matches.count == 1, let pid = matches[0]["pid"] as? Int, pid > 1 else {
            throw IcliError.unavailable(uniqueProcess)
        }
        return pid
    }

    private static func appPID(_ bundle: String) throws -> Int {
        guard let apps = try runningApps()["apps"] as? [[String: Any]] else {
            throw IcliError.unavailable("Cannot verify the foreground application for accessibility input")
        }
        let matches = apps.filter { $0["bundle_id"] as? String == bundle }
        guard matches.count == 1, let number = matches[0]["pid"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let pid = Int(exactly: number.doubleValue), pid > 1, pid <= Int(Int32.max)
        else { throw IcliError.unavailable(uniqueProcess) }
        return pid
    }

    private static func foregroundBoolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}
