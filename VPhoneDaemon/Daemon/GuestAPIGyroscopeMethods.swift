import Foundation

enum GyroscopeMethod: String, GuestMethod {
    case motionGyroscopeGet = "motion.gyroscope.get"
    case motionGyroscopeSet = "motion.gyroscope.set"
    case motionGyroscopeClear = "motion.gyroscope.clear"

    var spec: MethodSpec {
        switch self {
        case .motionGyroscopeGet: MethodSpec(summary: "Read the simulated gyroscope rotation rates in rad/s and whether it is enabled.", result: [.required("enabled", .boolean),
                                                      .required("provider", .object).nullable(),
                                                      .required("provider_running", .any),
                                                      .required("units", .string),
                                                      .required("x", .number),
                                                      .required("y", .number),
                                                      .required("z", .number)])
        case .motionGyroscopeSet: MethodSpec(.required("x", .number, "Rotation rate about x in rad/s", min: -1000, max: 1000), .required("y", .number, "Rotation rate about y in rad/s", min: -1000, max: 1000), .required("z", .number, "Rotation rate about z in rad/s", min: -1000, max: 1000), .optional("enabled", .boolean, "Whether the simulated gyroscope is active", default: true), summary: "Set the simulated gyroscope rotation rates (rad/s) that motion sensors report.", result: [.required("enabled", .boolean),
                                                      .required("provider", .object).nullable(),
                                                      .required("provider_running", .any),
                                                      .required("units", .string),
                                                      .required("x", .number),
                                                      .required("y", .number),
                                                      .required("z", .number)])
        case .motionGyroscopeClear: MethodSpec(summary: "Turn off the simulated gyroscope and reset its rates to zero.", result: [.required("enabled", .boolean),
                                                        .required("provider", .object).nullable(),
                                                        .required("provider_running", .any),
                                                        .required("units", .string),
                                                        .required("x", .number),
                                                        .required("y", .number),
                                                        .required("z", .number)])
        }
    }
}
