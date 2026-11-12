import Foundation

enum EnvironmentMethod: String, GuestMethod {
    case environmentStatus = "environment.status"
    case environmentInstall = "environment.install"

    var spec: MethodSpec {
        switch self {
        case .environmentStatus: MethodSpec(summary: "List the vphone environment libraries, the staging directory and whether the root volume is read-only.", result: [
                .required("libraries", .array),
                .required("root_read_only", .boolean),
                .required("staging", .string)])
        case .environmentInstall: MethodSpec(.required("libraries", .array, "Staged libraries to install, each an object with name and sha256 (hex SHA-256 of the staged file)"), summary: "Install uploaded vphone environment libraries into the guest after verifying their SHA-256.", result: [
                                                 .required("installed", .array),
                                                 .required("reboot_required", .boolean),
                                                 .required("restarted_pids", .array),
                                                 .required("root_read_only", .boolean)])
        }
    }
}
