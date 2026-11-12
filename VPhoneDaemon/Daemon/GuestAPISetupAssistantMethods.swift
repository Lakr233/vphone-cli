import Foundation

enum SetupAssistantMethod: String, GuestMethod {
    case setupStatus = "setup.status"
    case setupSkip = "setup.skip"

    var spec: MethodSpec {
        switch self {
        case .setupStatus: MethodSpec(summary: "Report whether Setup Assistant is pending or running and the guest setup version.", result: [.required("current_version", .integer).nullable(),
                                               .required("data_migration_done", .boolean).nullable(),
                                               .required("pending", .boolean),
                                               .required("pid", .integer),
                                               .required("running", .boolean),
                                               .required("setup_done", .boolean),
                                               .required("setup_version", .integer).nullable()])
        case .setupSkip: MethodSpec(summary: "Mark Setup Assistant complete and restart SpringBoard, unless data migration is still running.", force: .always("skip Setup Assistant"), result: [.required("current_version", .integer).nullable(),
                                             .required("data_migration_done", .boolean).nullable(),
                                             .required("pending", .boolean),
                                             .required("pid", .integer),
                                             .required("respring", .object),
                                             .required("running", .boolean),
                                             .required("setup_done", .boolean),
                                             .required("setup_version", .integer).nullable()])
        }
    }
}
