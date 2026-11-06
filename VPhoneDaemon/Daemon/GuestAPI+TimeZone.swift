import Foundation
import IcliKit

// MARK: - Time Zone

enum TimeZoneMethod: String, GuestMethod {
    case timeTimezone = "time.timezone"

    var spec: MethodSpec {
        switch self {
        case .timeTimezone: MethodSpec(.optional("identifier", .string), .optional("automatic", .boolean))
        }
    }
}

/// IcliKit owns the system time zone: tzlinkd moves the
/// `/var/db/timezone/localtime` link for a holder of `com.apple.tzlink.allow`,
/// and a set first turns timed's automatic time zone off through CoreTime,
/// which timed accepts only from a holder of `com.apple.timed`. Each answer is
/// `{identifier, automatic, seconds_from_gmt}`, plus `changed` after a set.
extension GuestAPI {
    static func executeTimeZone(_ m: TimeZoneMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .timeTimezone:
            if let identifier = optionalString(params, "identifier") {
                return try setTimeZone(identifier)
            }
            if let automatic = params["automatic"] as? Bool {
                return try setAutomaticTimeZone(automatic)
            }
            return try timeZone()
        }
    }
}
