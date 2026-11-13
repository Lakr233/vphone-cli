import Foundation
import IcliKit
import IcliSystem

// MARK: - Service Profile

/// `services.profile` and `services.profile.apply`, over the same launchd
/// override as `services.disable` and `services.enable`. The lists, the
/// never-disabled set and the bookkeeping are in `GuestServiceProfile`.
extension GuestAPI {
    /// One apply at a time: two would read the same record and overwrite each
    /// other's.
    private static let serviceProfileLock = NSLock()

    private static var guestIOSMajor: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// Read-only: the recorded profile, the lists for this iOS version, and
    /// how the recorded labels stand now.
    static func serviceProfileState() throws -> [String: Any] {
        let major = guestIOSMajor
        let record = GuestServiceProfile.readRecord()
        let owned = record?.labels ?? []
        let overrides = try disabledServiceOverrides()["disabled"] as? [String: Bool] ?? [:]
        let running = runningServiceLabels()
        let groups = GuestServiceProfile.groups(iosMajor: major) ?? []
        let pending = owned.filter { running.contains($0) }
        return [
            "profile": record?.profile ?? GuestServiceProfile.none,
            "ios_major": major,
            "supported": GuestServiceProfile.groups(iosMajor: major) != nil,
            "supported_ios": GuestServiceProfile.supportedMajors,
            "list_version": GuestServiceProfile.listVersion,
            "groups": groups.map { group -> [String: Any] in
                ["name": group.name, "default": group.byDefault, "summary": group.summary, "labels": group.labels]
            },
            "never_disable": GuestServiceProfile.neverDisable.sorted(),
            "record": record?.json ?? NSNull(),
            "disabled": owned.filter { overrides[$0] == true },
            "enabled_since": owned.filter { overrides[$0] != true },
            "running": pending,
            "reboot_required": !pending.isEmpty,
        ]
    }

    /// `{profile: "trimmed"|"none", groups?, allow?}`. Disables what the
    /// profile selects and is not yet disabled, turns back on what it disabled
    /// earlier and no longer selects, records what it owns, and leaves every
    /// other override alone. Idempotent: a second call changes nothing.
    static func applyServiceProfile(_ params: [String: Any]) throws -> [String: Any] {
        let profile = try string(params, "profile")
        let extraGroups = try stringList(params, "groups")
        let allow = try stringList(params, "allow")
        for label in allow {
            try validateServiceLabel(label)
        }

        serviceProfileLock.lock()
        defer { serviceProfileLock.unlock() }

        let major = guestIOSMajor
        let selection: GuestServiceProfile.Selection
        do {
            selection = try GuestServiceProfile.select(
                profile: profile, iosMajor: major, extraGroups: extraGroups, allow: allow,
            )
        } catch let failure as GuestServiceProfile.Failure {
            throw GuestAPIError.invalidRequest(failure.description, hint: "profile is trimmed or none; group names must be in the trimmed service list for this iOS version")
        }
        let previous = GuestServiceProfile.readRecord()
        let overrides = try disabledServiceOverrides()["disabled"] as? [String: Bool] ?? [:]
        let change = GuestServiceProfile.reconcile(
            target: selection.labels, owned: previous?.labels ?? [], overrides: overrides,
        )

        var disabled: [String] = []
        var enabled: [String] = []
        var failed: [[String: Any]] = []
        var failedDisable = Set<String>()
        var failedEnable = Set<String>()
        for label in change.disable {
            do {
                _ = try setServiceEnabled(label, enabled: false)
                disabled.append(label)
            } catch {
                failedDisable.insert(label)
                failed.append(["label": label, "action": "disable", "error": serviceErrorMessage(error)])
            }
        }
        for label in change.enable {
            do {
                _ = try setServiceEnabled(label, enabled: true)
                enabled.append(label)
            } catch {
                failedEnable.insert(label)
                failed.append(["label": label, "action": "enable", "error": serviceErrorMessage(error)])
            }
        }

        let owned = GuestServiceProfile.owned(after: change, failedDisable: failedDisable, failedEnable: failedEnable)
        let record = GuestServiceProfile.Record(
            profile: profile, listVersion: GuestServiceProfile.listVersion, iosMajor: major,
            groups: selection.groups, allow: selection.allowed, labels: owned, updated: Date(),
        )
        do {
            try GuestServiceProfile.writeRecord(record)
        } catch {
            throw GuestAPIError.operationFailed(
                "Disabled \(disabled.count) and enabled \(enabled.count) services, but could not record them in "
                    + "\(GuestServiceProfile.recordPath): \(error.localizedDescription)",
            )
        }

        let running = runningServiceLabels()
        let pending = owned.filter { running.contains($0) }
        return [
            "profile": profile,
            "ios_major": major,
            "list_version": GuestServiceProfile.listVersion,
            "groups": selection.groups,
            "disabled": disabled,
            "enabled": enabled,
            "kept": change.keep,
            "skipped": (change.skipped + selection.refused.map {
                GuestServiceProfile.Skip(label: $0, reason: GuestServiceProfile.neverDisabledReason)
            }).map { ["label": $0.label, "reason": $0.reason] },
            "allowed": selection.allowed,
            "failed": failed,
            "owned": owned.count,
            "reboot_required": !disabled.isEmpty || !enabled.isEmpty || !pending.isEmpty,
        ]
    }

    /// Labels launchd reports with a pid, in either domain. Empty when the
    /// list cannot be read; it only feeds `reboot_required`.
    private static func runningServiceLabels() -> Set<String> {
        let rows = (try? listServices())?["services"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { row in row["running"] as? Bool == true ? row["label"] as? String : nil })
    }

    private static func serviceErrorMessage(_ error: Error) -> String {
        (error as? IcliError)?.message ?? String(describing: error)
    }

    /// An absent key is an empty list; anything but an array of strings is refused.
    private static func stringList(_ params: [String: Any], _ key: String) throws -> [String] {
        guard let value = params[key], !(value is NSNull) else { return [] }
        guard let list = value as? [String] else {
            throw GuestAPIError.invalidRequest("\(key) must be an array of strings")
        }
        return list
    }
}
