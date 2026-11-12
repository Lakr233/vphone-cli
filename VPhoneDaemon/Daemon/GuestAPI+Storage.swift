import Darwin
import Foundation
import IcliSystem
import VphonedNative

// MARK: - APFS Snapshots

/// `apfs.snapshots` lists a volume's snapshots; `apfs.snapshot.delete`
/// removes the `orig-fs.disabled.rn-*` snapshot CFW install leaves on the
/// system volume, and nothing else (`GuestSnapshotPolicy`). Until it is gone,
/// files trimmed from the system volume free no space: the snapshot still
/// references their blocks. The guest TRIMs the freed blocks within seconds,
/// so the host's disk image shrinks without a reboot. The host cannot do this
/// itself: its SIP refuses to delete snapshots of a System-role volume.
/// `Research/Guest/template_snapshot_deletion.md` has the measurements.
extension GuestAPI {
    static func executeStorage(_ m: StorageMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .apfsSnapshots:
            let mount = try snapshotMount(params)
            return try ["mount": mount, "snapshots": snapshotNames(mount)]
        case .apfsSnapshotDelete:
            let (mount, selection) = try snapshotDeletion(params)
            return try deleteSnapshots(mount: mount, selection: selection)
        }
    }

    fileprivate static func snapshotMount(_ params: [String: Any]) throws -> String {
        let mount = optionalString(params, "mount") ?? GuestSnapshotPolicy.defaultMount
        do {
            try GuestSnapshotPolicy.validateMount(mount)
        } catch {
            throw GuestAPIError.invalidRequest(String(describing: error))
        }
        return mount
    }

    static func snapshotDeletion(_ params: [String: Any]) throws
        -> (mount: String, selection: GuestSnapshotPolicy.Selection) {
        let mount = try snapshotMount(params)
        do {
            let selection = try GuestSnapshotPolicy.Selection.make(
                name: optionalString(params, "name"),
                prefix: optionalString(params, "prefix"),
            )
            return (mount, selection)
        } catch {
            throw GuestAPIError.invalidRequest(String(describing: error))
        }
    }

    static func snapshotNames(_ mount: String) throws -> [String] {
        var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        let status = vp_apfs_snapshot_list(mount, &names, &count)
        guard status == 0 else {
            throw snapshotError(status, operation: "fs_snapshot_list(\(mount))", details: ["mount": mount])
        }
        defer { vp_apfs_snapshot_names_free(names, count) }
        return (0 ..< Int(count)).compactMap { index in names?[index].map { String(cString: $0) } }.sorted()
    }

    /// Deletes the selected snapshots one by one and stops at the first the
    /// kernel refuses. A snapshot already gone counts as deleted, and a
    /// selection that matches nothing succeeds with nothing deleted.
    private static func deleteSnapshots(mount: String, selection: GuestSnapshotPolicy.Selection) throws -> [String: Any] {
        let before = try snapshotNames(mount)
        var deleted: [String] = []
        var alreadyDeleted: [String] = []
        for name in selection.targets(in: before) {
            let status = vp_apfs_snapshot_delete(mount, name)
            if status == 0 {
                deleted.append(name)
                continue
            }
            if GuestSnapshotPolicy.Failure(errno: status) == .alreadyDeleted {
                alreadyDeleted.append(name)
                continue
            }
            throw snapshotError(status, operation: "fs_snapshot_delete(\(name))", details: [
                "mount": mount,
                "snapshot": name,
                "before": before,
                "deleted": deleted,
                "after": (try? snapshotNames(mount)) ?? NSNull(),
            ])
        }
        let after = try snapshotNames(mount)
        return [
            "mount": mount,
            "before": before,
            "deleted": deleted,
            "already_deleted": alreadyDeleted,
            "after": after,
            "remaining": after.filter(selection.matches),
        ]
    }

    /// An invalid request is an ordinary invalid request; any other refusal
    /// carries `reason`, `retryable` and `errno` beside the listings.
    private static func snapshotError(_ status: Int32, operation: String, details: [String: Any]) -> Error {
        let failure = GuestSnapshotPolicy.Failure(errno: status)
        let message = GuestSnapshotPolicy.message(failure, errno: status, operation: operation)
        if failure == .invalidRequest {
            return GuestAPIError.invalidRequest(message)
        }
        return IcliError.commandFailed(details.merging([
            "error": "snapshot_operation_failed",
            "message": message,
            "reason": failure.rawValue,
            "retryable": failure.retryable,
            "errno": Int(status),
        ]) { $1 })
    }
}
