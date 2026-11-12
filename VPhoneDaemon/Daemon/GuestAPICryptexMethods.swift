import Foundation

enum CryptexMethod: String, GuestMethod {
    case cryptexList = "cryptex.list"
    case cryptexInstall = "cryptex.install"
    case cryptexUninstall = "cryptex.uninstall"

    var spec: MethodSpec {
        switch self {
        case .cryptexList: MethodSpec(summary: "List installed cryptexes and those vphoned installs again after a reboot; trusted darwinOS guests only.", result: [.required("output", .string), .required("persisted", .array)])
        case .cryptexInstall: MethodSpec(.required("path", .string, "Guest path of an uploaded .cxbd directory under /var/mobile/Documents/vphone-cryptexes"),
                                         .required("variant", .string, "The cryptex variant it was created with"),
                                         .optional("persist", .boolean, "Have vphoned install it again each time it starts after a reboot", default: false),
                                         summary: "Personalize an uploaded .cxbd with Apple's signing server and install it; trusted darwinOS guests only.",
                                         result: [.required("personalized", .string), .required("output", .string)])
        case .cryptexUninstall: MethodSpec(.required("identifier", .string, "Identifier of an installed cryptex, as cryptex.list shows it"),
                                           summary: "Uninstall a cryptex; trusted darwinOS guests only (capability cryptex).",
                                           result: [.required("output", .string)])
        }
    }
}
