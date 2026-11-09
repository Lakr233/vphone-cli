import Foundation

enum VisionOSImmersionMethod: String, GuestMethod {
    case get = "visionos.immersion.get"
    case set = "visionos.immersion.set"

    var spec: MethodSpec {
        switch self {
        case .get: MethodSpec(summary: "Read the current visionOS immersion level from 0 to 1.", result: [.required("available", .boolean), .required("applied", .boolean), .required("level", .number)])
        case .set: MethodSpec(.required("level", .number, "Immersion level, 0 for none to 1 for full", min: 0, max: 1), summary: "Set the visionOS immersion level from 0 to 1.", result: [.required("available", .boolean), .required("applied", .boolean), .required("level", .number), .required("requested_level", .number)])
        }
    }
}
