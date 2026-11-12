import Foundation

enum ClockMethod: String, GuestMethod {
    case timeClock = "time.clock"

    var spec: MethodSpec {
        switch self {
        case .timeClock: MethodSpec(.optional("time", .number, "Mac time, seconds since 1970, above 978307200; the clock moves only if over 1 s off and automatic time is on"), .optional("automatic", .boolean, "Turn the guest automatic time setting on or off; applied before time"), summary: "Read the guest clock, sync it to the Mac time, or switch automatic time on or off.", result: [.required("automatic", .boolean).nullable(),
                                             .optional("changed", .boolean),
                                             .optional("offset", .number),
                                             .required("time", .number)])
        }
    }
}
