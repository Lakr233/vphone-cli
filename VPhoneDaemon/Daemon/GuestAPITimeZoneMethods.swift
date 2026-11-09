import Foundation

enum TimeZoneMethod: String, GuestMethod {
    case timeTimezone = "time.timezone"

    var spec: MethodSpec {
        switch self {
        case .timeTimezone: MethodSpec(.optional("identifier", .string, "IANA time zone identifier such as America/New_York; sets it and turns automatic time zone off"), .optional("automatic", .boolean, "Turn automatic time zone on or off; ignored when identifier is given"), summary: "Read or set the guest time zone, or switch automatic time zone on or off.", result: [.required("automatic", .boolean).nullable(),
                                                .optional("changed", .boolean),
                                                .required("identifier", .string).nullable(),
                                                .required("seconds_from_gmt", .integer).nullable()])
        }
    }
}
