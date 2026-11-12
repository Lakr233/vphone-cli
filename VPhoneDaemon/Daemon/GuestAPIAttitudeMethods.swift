import Foundation

enum AttitudeMethod: String, GuestMethod {
    case motionAttitudeGet = "motion.attitude.get"
    case motionAttitudeSet = "motion.attitude.set"
    case motionAttitudeClear = "motion.attitude.clear"

    var spec: MethodSpec {
        switch self {
        case .motionAttitudeGet: MethodSpec(summary: "Read the simulated device attitude (roll, pitch, yaw in degrees) and whether it is enabled.", result: [.required("enabled", .boolean),
                                                     .required("pitch", .number),
                                                     .required("provider_installed", .integer),
                                                     .required("reference_frame", .string),
                                                     .required("roll", .number),
                                                     .required("units", .string),
                                                     .required("yaw", .number)])
        case .motionAttitudeSet: MethodSpec(.required("roll", .number, "Roll in degrees", min: -180, max: 180), .required("pitch", .number, "Pitch in degrees", min: -90, max: 90), .required("yaw", .number, "Yaw in degrees", min: -180, max: 180), .optional("enabled", .boolean, "Whether the simulated attitude is active", default: true), summary: "Set the simulated device attitude (roll, pitch, yaw in degrees) that motion sensors report.", result: [.required("enabled", .boolean),
                                                     .required("pitch", .number),
                                                     .required("provider_installed", .integer),
                                                     .required("reference_frame", .string),
                                                     .required("roll", .number),
                                                     .required("units", .string),
                                                     .required("yaw", .number)])
        case .motionAttitudeClear: MethodSpec(summary: "Turn off the simulated device attitude and reset its angles to zero.", result: [.required("enabled", .boolean),
                                                       .required("pitch", .number),
                                                       .required("provider_installed", .integer),
                                                       .required("reference_frame", .string),
                                                       .required("roll", .number),
                                                       .required("units", .string),
                                                       .required("yaw", .number)])
        }
    }
}
