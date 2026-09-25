import Foundation

/// One process from vphoned's `processes.list`. Task statistics, jetsam
/// fields and the bundle identifier are absent when the guest could not read
/// them, so they stay optional and the table shows "—".
struct VPhoneProcessRow: Identifiable, Hashable {
    let pid: Int
    /// `p_comm`, which the kernel truncates to 16 bytes.
    let name: String
    let executable: String?
    let bundleID: String?
    let ppid: Int?
    let uid: Int?
    /// Seconds since 1970 on the guest clock.
    let startTime: Double?
    let cpuSeconds: Double?
    let footprintBytes: Int64?
    let residentBytes: Int64?
    let jetsamPriority: Int?
    /// Megabytes; the kernel reports -1 for a process without a limit.
    let jetsamLimitMB: Int?

    var id: Int {
        pid
    }

    init?(_ object: [String: Any]) {
        guard let pid = object.int("pid") else { return nil }
        self.pid = pid
        name = object.string("name") ?? ""
        executable = object.string("executable").flatMap { $0.isEmpty ? nil : $0 }
        bundleID = object.string("bundle_id").flatMap { $0.isEmpty ? nil : $0 }
        ppid = object.int("ppid")
        uid = object.int("uid")
        startTime = object.double("start_time").flatMap { $0 > 0 ? $0 : nil }
        cpuSeconds = object.double("cpu_seconds")
        footprintBytes = object.int("footprint_bytes").map(Int64.init)
        residentBytes = object.int("resident_bytes").map(Int64.init)
        jetsamPriority = object.int("jetsam_priority")
        jetsamLimitMB = object.int("jetsam_limit_mb")
    }

    // MARK: - Display

    /// The kernel name, or the executable's file name when `p_comm` was cut
    /// short at 16 bytes.
    var displayName: String {
        let file = executable.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty {
            return file.isEmpty ? "—" : file
        }
        if name.utf8.count >= 15, file.count > name.count, file.hasPrefix(name) {
            return file
        }
        return name
    }

    var userTitle: String {
        switch uid {
        case nil: "—"
        case 0: "root"
        case 501: "mobile"
        case let uid?: String(uid)
        }
    }

    var ppidTitle: String {
        ppid.map(String.init) ?? "—"
    }

    var footprintTitle: String {
        VPhonePanelFormat.bytes(footprintBytes)
    }

    var residentTitle: String {
        VPhonePanelFormat.bytes(residentBytes)
    }

    var cpuTitle: String {
        VPhonePanelFormat.cpuTime(cpuSeconds)
    }

    var jetsamPriorityTitle: String {
        jetsamPriority.map(String.init) ?? "—"
    }

    var jetsamLimitTitle: String {
        guard let jetsamLimitMB else { return "—" }
        guard jetsamLimitMB > 0 else { return String(localized: "None", bundle: VPhoneLocalization.bundle) }
        // The guest supplies the value; a limit past Int64 bytes shows as the maximum.
        let (bytes, overflow) = Int64(jetsamLimitMB).multipliedReportingOverflow(by: 1_048_576)
        return VPhonePanelFormat.bytes(overflow ? Int64.max : bytes)
    }

    /// The time of day for a process started today, else a short date.
    var startedTitle: String {
        guard let startTime else { return "—" }
        let date = Date(timeIntervalSince1970: startTime)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    var startedHelp: String {
        VPhonePanelFormat.date(startTime)
    }

    var executableTitle: String {
        executable ?? "—"
    }

    var bundleTitle: String {
        bundleID ?? "—"
    }

    /// `name (pid)`, as confirmation dialogs and status messages name a process.
    var reference: String {
        "\(displayName) (\(pid))"
    }

    // MARK: - Sorting

    // Table columns sort through these non-optional keys. A missing value
    // sorts below every real one.

    var nameSortKey: String {
        displayName
    }

    var bundleSortKey: String {
        bundleID ?? ""
    }

    var uidSortKey: Int {
        uid ?? -1
    }

    var ppidSortKey: Int {
        ppid ?? -1
    }

    var footprintSortKey: Int64 {
        footprintBytes ?? -1
    }

    var residentSortKey: Int64 {
        residentBytes ?? -1
    }

    var cpuSortKey: Double {
        cpuSeconds ?? -1
    }

    var jetsamPrioritySortKey: Int {
        jetsamPriority ?? Int.min
    }

    var jetsamLimitSortKey: Int {
        jetsamLimitMB ?? Int.min
    }

    var startSortKey: Double {
        startTime ?? 0
    }

    var executableSortKey: String {
        executable ?? ""
    }

    // MARK: - Search

    /// Matches the exact pid, or a case-insensitive substring of the name,
    /// bundle identifier or executable path.
    func matches(_ query: String) -> Bool {
        if Int(query) == pid {
            return true
        }
        return displayName.localizedCaseInsensitiveContains(query)
            || name.localizedCaseInsensitiveContains(query)
            || (bundleID?.localizedCaseInsensitiveContains(query) ?? false)
            || (executable?.localizedCaseInsensitiveContains(query) ?? false)
    }
}
