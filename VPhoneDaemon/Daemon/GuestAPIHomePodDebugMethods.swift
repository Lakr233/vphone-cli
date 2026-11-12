import Foundation

enum HomePodDebugMethod: String, GuestMethod {
    case homepodDebugCatalog = "homepod.debug.catalog"
    case homepodDebugCall = "homepod.debug.call"

    var spec: MethodSpec {
        switch self {
        case .homepodDebugCatalog: MethodSpec(summary: "List the SoundBoard debug operations, animations and phases that homepod.debug.call accepts.", result: [.required("animations", .array),
                                                       .required("available", .boolean),
                                                       .required("interface", .string),
                                                       .required("operations", .array),
                                                       .required("phases", .array)])
        case .homepodDebugCall: MethodSpec(.required("operation", .string, "SoundBoard debug operation name from homepod.debug.catalog"), .required("arguments", .object, "Arguments object for the operation; use an empty object for none"), summary: "Invoke one SoundBoard debug operation from the fixed catalog and return its result.", result: [.required("operation", .string),
                                                    .optional("submitted", .boolean),
                                                    .optional("value", .any).open().nullable()])
        }
    }
}
