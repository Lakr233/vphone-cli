import Foundation

enum SystemAppsMethod: String, GuestMethod {
    case otaAppsStatus = "ota.apps.status"
    case otaAppsApply = "ota.apps.apply"
    case appsRemoveSystem = "apps.remove_system"
    case appsRestoreSystem = "apps.restore_system"
    case appsRemovedSystem = "apps.removed_system"

    var spec: MethodSpec {
        switch self {
        case .otaAppsStatus: MethodSpec(.optional("removed_bundle_ids", .array, "Bundle ids treated as deliberately removed; defaults to apps with a removal backup that are absent"), summary: "Preview which retained Apple apps the installed OTA payload would update, without changing anything.", result: [
                                            .required("apps", .array),
                                            .required("build", .string),
                                            .required("pending", .integer),
                                            .required("removed_bundle_ids", .array),
                                            .required("removed_pending", .array)])
        case .otaAppsApply:
            MethodSpec(.optional("removed_bundle_ids", .array, "Bundle ids treated as deliberately removed; defaults to apps with a removal backup that are absent"),
                       summary: "Update retained Apple app programs from the installed OTA payload, keeping removed apps removed.",
                       force: .always("update retained Apple app programs from the installed OTA"), result: [
                           .required("apps", .array),
                           .required("build", .string),
                           .required("pending", .integer),
                           .required("removed_bundle_ids", .array),
                           .required("removed_pending", .array)])
        case .appsRemoveSystem:
            MethodSpec(.required("bundle_ids", .array, "Non-empty list of Apple system app bundle ids, each starting with com.apple."),
                       .optional("backup", .boolean, "Back up each app container before removal so it can be restored", default: true),
                       .optional("respring", .boolean, "Restart SpringBoard afterwards to refresh the home screen", default: true),
                       summary: "Durably remove Apple removable system apps from the guest, backing each up first by default.",
                       force: .always("remove <bundle_ids>") { p in try "remove \(GuestAPI.systemAppsToRemove(p).joined(separator: ", "))" }, result: [
                           .required("backup_directory", .string).nullable(),
                           .optional("error", .string),
                           .required("failed", .integer),
                           .optional("message", .string),
                           .required("removed", .integer),
                           .required("respring", .object).nullable(),
                           .required("results", .array)])
        case .appsRestoreSystem:
            MethodSpec(.optional("bundle_ids", .array, "Bundle ids to restore; defaults to every app with a backup"),
                       .optional("respring", .boolean, "Restart SpringBoard afterwards to refresh the home screen", default: true),
                       summary: "Restore removed system apps from the backups apps.remove_system kept.",
                       force: .always("restore removed system apps") { p in
                           _ = try GuestAPI.systemAppIDs(p)
                           return "restore removed system apps"
                       }, result: [
                           .optional("error", .string),
                           .required("failed", .integer),
                           .optional("message", .string),
                           .required("respring", .object).nullable(),
                           .required("restored", .integer),
                           .required("results", .array)])
        case .appsRemovedSystem: MethodSpec(summary: "List the backups of removed system apps, with whether each is installed and restorable.", result: [
                .required("backups", .array),
                .required("directory", .string),
                .required("legacy_directory", .string),
                .required("legacy_other", .array),
                .required("other", .array)])
        }
    }
}
