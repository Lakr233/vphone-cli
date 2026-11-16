import Foundation

enum DeviceIdentityMethod: String, GuestMethod {
    case udidGet = "udid.get"
    case udidSet = "udid.set"
    case udidClear = "udid.clear"

    var spec: MethodSpec {
        switch self {
        case .udidGet: MethodSpec(area: .device, access: .read, summary: "Read the UDID override the guest reports to provisioning checks and the host, or null if none.", result: [.required("path", .string).nullable(), .required("udid", .string).nullable()])
        case .udidSet: MethodSpec(.required("udid", .string, "UDID to present, stored as sent with no format check"), area: .device, access: .mutating, summary: "Set the guest UDID override, restart UDID-reading daemons and re-enumerate USB so the host sees it.", result: [.required("path", .string).nullable(), .required("restarted_pids", .array), .required("udid", .string).nullable(), .required("usb_reenumerated", .boolean), .required("usb_serial", .string)])
        case .udidClear: MethodSpec(area: .device, access: .mutating, summary: "Remove the UDID override so the guest reports its own, restarting daemons and re-enumerating USB.", result: [.required("path", .string).nullable(), .required("restarted_pids", .array), .required("udid", .null), .required("usb_reenumerated", .boolean), .required("usb_serial", .string)])
        }
    }
}
