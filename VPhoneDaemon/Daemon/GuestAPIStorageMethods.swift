import Foundation

enum StorageMethod: String, GuestMethod {
    case apfsSnapshots = "apfs.snapshots"
    case apfsSnapshotDelete = "apfs.snapshot.delete"

    var spec: MethodSpec {
        switch self {
        case .apfsSnapshots: MethodSpec(.optional("mount", .string, "Absolute mount point of the APFS volume", default: "/"), summary: "List the APFS snapshot names on a guest volume.", result: [.required("mount", .string), .required("snapshots", .array)])
        case .apfsSnapshotDelete:
            MethodSpec(.optional("mount", .string, "Absolute mount point of the APFS volume", default: "/"),
                       .optional("name", .string, "Exact snapshot name to delete; must start with orig-fs.disabled.rn- and extend it; not with prefix"),
                       .optional("prefix", .string, "Delete snapshots with this name prefix, which must start with orig-fs.disabled.rn-; not with name"),
                       summary: "Delete the orig-fs.disabled.rn-* APFS snapshots CFW install leaves behind, freeing trimmed disk space.",
                       force: .always("delete APFS snapshots on <mount>") { p in try "delete APFS snapshots on \(GuestAPI.snapshotDeletion(p).mount)" }, result: [
                           .required("after", .array),
                           .required("already_deleted", .array),
                           .required("before", .array),
                           .required("deleted", .array),
                           .required("mount", .string),
                           .required("remaining", .array)])
        }
    }
}
