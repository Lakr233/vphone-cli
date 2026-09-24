import AppKit
import Foundation

@MainActor
@Observable
final class VPhoneDeviceInfoModel {
    static let autoRefreshInterval: Duration = .seconds(5)

    let control: VPhoneGuestControl
    private(set) var isLoading = false
    private(set) var status: VPhoneGuestToolStatus?
    var autoRefresh = false
    var addressSortOrder = [KeyPathComparator(\VPhoneDeviceNetworkAddress.interface)]
    var selectedAddresses = Set<VPhoneDeviceNetworkAddress.ID>()

    /// The raw `device.info` result, `device.environment` result and the
    /// `memory` object of `memory.pressure`.
    private(set) var info: [String: Any]?
    private(set) var environment: [String: Any]?
    private(set) var jetsamMemory: [String: Any]?
    private(set) var infoJSON: String?
    private(set) var updatedAt: Date?

    var hasInfo: Bool {
        info != nil
    }

    var canCopyJSON: Bool {
        infoJSON != nil
    }

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    // MARK: - Loading

    /// Reads `device.info`, then the memory pressure level and, unless this is
    /// a background poll, the jailbreak environment report.
    func refresh(polling: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await control.call("device.info")
            apply(deviceInfoResult: result)
        } catch {
            fail(String(localized: "Unable to read device information. Check the connection, then try again.", bundle: VPhoneLocalization.bundle))
            return
        }
        if let jetsam = try? await control.call("memory.pressure") {
            apply(jetsamResult: jetsam)
        }
        if !polling || environment == nil, let report = try? await control.call("device.environment") {
            apply(environmentResult: report)
        }
        updatedAt = .now
        let time = Date.now.formatted(date: .omitted, time: .standard)
        status = VPhoneGuestToolStatus(
            message: String(localized: "Updated at \(time).", bundle: VPhoneLocalization.bundle),
            isError: false,
        )
    }

    // MARK: - Parsing

    func apply(deviceInfoResult result: [String: Any]) {
        info = result
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        infoJSON = (try? JSONSerialization.data(withJSONObject: result, options: options))
            .flatMap { String(data: $0, encoding: .utf8) }
        let known = Set(addresses.map(\.id))
        selectedAddresses.formIntersection(known)
    }

    func apply(environmentResult result: [String: Any]) {
        environment = result
    }

    func apply(jetsamResult result: [String: Any]) {
        jetsamMemory = result.object("memory")
    }

    // MARK: - Copy

    func copyJSON() {
        guard let infoJSON else { return }
        copy(infoJSON, message: String(localized: "Copied device information as JSON.", bundle: VPhoneLocalization.bundle))
    }

    func copyValue(_ value: String) {
        copy(value, message: String(localized: "Copied the value to the Mac clipboard.", bundle: VPhoneLocalization.bundle))
    }

    func copyAddresses(_ ids: Set<VPhoneDeviceNetworkAddress.ID>, full: Bool) {
        let rows = sortedAddresses.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return }
        let text = rows.map { full ? $0.line : $0.address }.joined(separator: "\n")
        copy(text, message: String(localized: "Copied the selection to the Mac clipboard.", bundle: VPhoneLocalization.bundle))
    }

    private func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }

    // MARK: - Network

    var addresses: [VPhoneDeviceNetworkAddress] {
        let raw = info?.object("network")?["addresses"] as? [String] ?? []
        var seen = Set<String>()
        return raw.compactMap(VPhoneDeviceNetworkAddress.init).filter { seen.insert($0.id).inserted }
    }

    var sortedAddresses: [VPhoneDeviceNetworkAddress] {
        addresses.sorted(using: addressSortOrder)
    }

    // MARK: - Sections

    var sections: [VPhoneDeviceInfoSection] {
        guard let info else { return [] }
        var sections = [
            deviceSection(info),
            hardwareSection(info),
            powerSection(info),
            displaySection(info),
            securitySection(info),
        ]
        if let environment {
            sections.append(environmentSection(environment))
        }
        sections.append(agentSection(info))
        return sections
    }

    private func deviceSection(_ info: [String: Any]) -> VPhoneDeviceInfoSection {
        let kernel = [info.string("sysname"), info.string("kernel")].compactMap(\.self).joined(separator: " ")
        return VPhoneDeviceInfoSection(kind: .device, title: Self.text("Device"), rows: [
            VPhoneDeviceInfoRow(label: Self.text("Model"), value: Self.value(info.string("model"))),
            VPhoneDeviceInfoRow(label: Self.text("iOS Version"), value: Self.value(info.string("ios_version"))),
            VPhoneDeviceInfoRow(label: Self.text("Kernel"), value: Self.value(kernel)),
            VPhoneDeviceInfoRow(label: Self.text("Host Name"), value: Self.value(info.string("host"))),
            VPhoneDeviceInfoRow(label: Self.text("Boot Time"), value: VPhonePanelFormat.date(info.double("boot_time"))),
            VPhoneDeviceInfoRow(label: Self.text("Uptime"), value: VPhonePanelFormat.duration(info.double("uptime_seconds"))),
            VPhoneDeviceInfoRow(label: Self.text("Boot Session UUID"), value: Self.value(info.string("boot_session_uuid"))),
        ])
    }

    private func hardwareSection(_ info: [String: Any]) -> VPhoneDeviceInfoSection {
        var rows = [
            VPhoneDeviceInfoRow(label: Self.text("Physical Memory"), value: VPhonePanelFormat.bytes(info.int("memory_bytes"))),
            VPhoneDeviceInfoRow(label: Self.text("CPU Count"), value: Self.value(info.string("processor_count"))),
        ]
        let storage = info.object("storage") ?? [:]
        if let total = storage.double("total_bytes"), total > 0 {
            let available = storage.double("available_bytes") ?? 0
            let used = max(0, total - available)
            let fraction = min(1, used / total)
            let value = String(
                localized: "\(VPhonePanelFormat.bytes(Int64(used))) used of \(VPhonePanelFormat.bytes(Int64(total))) (\(VPhonePanelFormat.percent(fraction)))",
                bundle: VPhoneLocalization.bundle,
            )
            let tone: VPhoneDeviceInfoRow.Tone = fraction >= 0.95 ? .critical : fraction >= 0.85 ? .warning : .good
            rows.append(VPhoneDeviceInfoRow(label: Self.text("Storage"), value: value, tone: tone, gauge: fraction))
        } else {
            rows.append(VPhoneDeviceInfoRow(label: Self.text("Storage"), value: "—"))
        }
        rows.append(memoryPressureRow())
        return VPhoneDeviceInfoSection(kind: .hardware, title: Self.text("Hardware"), rows: rows)
    }

    /// `kern.memorystatus_vm_pressure_level` uses the kernel's
    /// kVMPressure values; `kern.memorystatus_level` is the percentage of
    /// memory available.
    private func memoryPressureRow() -> VPhoneDeviceInfoRow {
        let label = Self.text("Memory Pressure")
        guard let memory = jetsamMemory, let level = memory.int("memorystatus_vm_pressure_level") else {
            return VPhoneDeviceInfoRow(label: label, value: Self.text("Unavailable"))
        }
        let name: String
        let tone: VPhoneDeviceInfoRow.Tone
        switch level {
        case 0, 1: (name, tone) = (Self.text("Normal"), .good)
        case 2: (name, tone) = (Self.text("Warning"), .warning)
        case 4: (name, tone) = (Self.text("Urgent"), .critical)
        case 8: (name, tone) = (Self.text("Critical"), .critical)
        default: (name, tone) = ("\(Self.text("Unknown")) (\(level))", .warning)
        }
        guard let available = memory.double("memorystatus_level") else {
            return VPhoneDeviceInfoRow(label: label, value: name, tone: tone)
        }
        let percent = VPhonePanelFormat.percent(available / 100)
        return VPhoneDeviceInfoRow(
            label: label,
            value: String(localized: "\(name) · \(percent) available", bundle: VPhoneLocalization.bundle),
            tone: tone,
        )
    }

    private func powerSection(_ info: [String: Any]) -> VPhoneDeviceInfoSection {
        let battery = info.object("battery") ?? [:]
        let stateName: String = switch battery.int("state") {
        case 1: Self.text("Unplugged")
        case 2: Self.text("Charging")
        case 3: Self.text("Full")
        default: Self.text("Unknown")
        }
        // UIDevice reports -1 when the level is unknown.
        let batteryValue: String = if let fraction = battery.double("fraction"), fraction >= 0 {
            "\(VPhonePanelFormat.percent(fraction)) · \(stateName)"
        } else {
            stateName
        }
        let lock = info.object("lock") ?? [:]
        let lowPower = info.object("low_power_mode")?.bool("enabled")
        return VPhoneDeviceInfoSection(kind: .power, title: Self.text("Power"), rows: [
            VPhoneDeviceInfoRow(label: Self.text("Battery"), value: batteryValue),
            VPhoneDeviceInfoRow(
                label: Self.text("Low Power Mode"),
                value: Self.onOff(lowPower),
                tone: lowPower == true ? .warning : nil,
            ),
            VPhoneDeviceInfoRow(
                label: Self.text("Lock State"),
                value: lock.bool("locked").map { $0 ? Self.text("Locked") : Self.text("Unlocked") } ?? "—",
            ),
            VPhoneDeviceInfoRow(label: Self.text("Screen"), value: lock.bool("screen_off").map { $0 ? Self.text("Off") : Self.text("On") } ?? "—"),
            VPhoneDeviceInfoRow(
                label: Self.text("Passcode"),
                value: lock.bool("passcode_enabled").map { $0 ? Self.text("Set") : Self.text("Not Set") } ?? "—",
            ),
        ])
    }

    private func displaySection(_ info: [String: Any]) -> VPhoneDeviceInfoSection {
        let screen = info.object("screen") ?? [:]
        let rotation = info.object("rotation") ?? [:]
        let brightness = info.object("brightness") ?? [:]
        var size = "—"
        var pixels = "—"
        var scale = "—"
        if let width = screen.double("width"), let height = screen.double("height"), width > 0, height > 0 {
            size = "\(Self.number(width)) × \(Self.number(height)) pt"
            if let factor = screen.double("scale"), factor > 0 {
                pixels = "\(Self.number(width * factor)) × \(Self.number(height * factor)) px"
                scale = "\(Self.number(factor))×"
            }
        }
        var orientation = rotation.string("name") ?? "—"
        if let degrees = rotation.int("degrees") {
            orientation += " (\(degrees)°)"
        }
        let rotationLocked = rotation.bool("locked")
        return VPhoneDeviceInfoSection(kind: .display, title: Self.text("Display"), rows: [
            VPhoneDeviceInfoRow(label: Self.text("Size"), value: size),
            VPhoneDeviceInfoRow(label: Self.text("Pixels"), value: pixels),
            VPhoneDeviceInfoRow(label: Self.text("Scale"), value: scale),
            VPhoneDeviceInfoRow(label: Self.text("Orientation"), value: orientation),
            VPhoneDeviceInfoRow(label: Self.text("Device Orientation"), value: Self.deviceOrientation(rotation.int("device_orientation"))),
            VPhoneDeviceInfoRow(label: Self.text("Rotation Lock"), value: Self.onOff(rotationLocked)),
            VPhoneDeviceInfoRow(label: Self.text("Brightness"), value: VPhonePanelFormat.percent(brightness.double("value"))),
            VPhoneDeviceInfoRow(label: Self.text("Auto-Brightness"), value: Self.onOff(brightness.bool("auto"))),
            VPhoneDeviceInfoRow(label: Self.text("Volume"), value: VPhonePanelFormat.percent(info.double("volume"))),
        ])
    }

    private func securitySection(_ info: [String: Any]) -> VPhoneDeviceInfoSection {
        let developer = info.object("developer_mode") ?? [:]
        let developerValue: String
        let developerTone: VPhoneDeviceInfoRow.Tone?
        if developer.bool("enabled") == true {
            (developerValue, developerTone) = (Self.text("On"), .good)
        } else if developer.bool("armed") == true {
            (developerValue, developerTone) = (Self.text("Armed, turns on after restart"), .warning)
        } else if developer.bool("enabled") == false {
            (developerValue, developerTone) = (Self.text("Off"), nil)
        } else {
            (developerValue, developerTone) = (Self.text("Unavailable"), nil)
        }
        let jailbreak = info.object("jailbreak") ?? [:]
        let layout = jailbreak.string("layout")
        return VPhoneDeviceInfoSection(kind: .security, title: Self.text("Security"), rows: [
            VPhoneDeviceInfoRow(label: Self.text("Developer Mode"), value: developerValue, tone: developerTone),
            VPhoneDeviceInfoRow(label: Self.text("Developer Mode Writable"), value: Self.yesNo(developer.bool("writable"))),
            VPhoneDeviceInfoRow(
                label: Self.text("Jailbreak Layout"),
                value: layout ?? Self.text("Not Detected"),
                tone: layout == nil ? nil : .info,
            ),
            VPhoneDeviceInfoRow(label: Self.text("jbroot"), value: Self.value(jailbreak.string("jbroot"))),
            VPhoneDeviceInfoRow(label: Self.text("Detected By"), value: Self.value(jailbreak.string("source"))),
        ])
    }

    /// icli `environmentReport()`, as served by `device.environment`.
    private func environmentSection(_ report: [String: Any]) -> VPhoneDeviceInfoSection {
        let markers = report["markers"] as? [String] ?? []
        let tools = report["bootstrap_tools_present"] as? [String: Any] ?? [:]
        let present = tools.keys.filter { tools.bool($0) == true }.sorted()
        let missing = tools.keys.filter { tools.bool($0) != true }.sorted()
        let basebin = report.string("basebin_version") ?? ""
        return VPhoneDeviceInfoSection(kind: .environment, title: Self.text("Jailbreak Environment"), rows: [
            VPhoneDeviceInfoRow(label: Self.text("jbroot Source"), value: Self.value(report.string("jbroot_source"))),
            VPhoneDeviceInfoRow(label: Self.text("Rootfs Prefix"), value: Self.value(report.string("rootfs_prefix"))),
            VPhoneDeviceInfoRow(label: Self.text("Markers"), value: markers.isEmpty ? Self.text("None") : markers.joined(separator: ", ")),
            VPhoneDeviceInfoRow(label: Self.text("BaseBin Version"), value: basebin.isEmpty ? "—" : basebin),
            VPhoneDeviceInfoRow(label: Self.text("Bootstrap Tools"), value: present.isEmpty ? Self.text("None") : present.joined(separator: ", ")),
            VPhoneDeviceInfoRow(label: Self.text("Missing Tools"), value: missing.isEmpty ? Self.text("None") : missing.joined(separator: ", ")),
            VPhoneDeviceInfoRow(label: Self.text("Platform Binary"), value: Self.yesNo(report.bool("platform_binary"))),
            VPhoneDeviceInfoRow(label: Self.text("RootHide Runtime"), value: Self.yesNo(report.bool("roothide_runtime_active"))),
            VPhoneDeviceInfoRow(label: Self.text("Effective UID"), value: Self.value(report.string("euid"))),
        ])
    }

    private func agentSection(_ info: [String: Any]) -> VPhoneDeviceInfoSection {
        let agent = info.object("agent") ?? [:]
        return VPhoneDeviceInfoSection(kind: .agent, title: Self.text("vphoned Agent"), rows: [
            VPhoneDeviceInfoRow(label: Self.text("Binary SHA-256"), value: Self.value(agent.string("binary_hash")), truncatesMiddle: true),
            VPhoneDeviceInfoRow(label: Self.text("PID"), value: Self.value(agent.string("pid"))),
        ])
    }

    // MARK: - Value Formatting

    private static func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: VPhoneLocalization.bundle)
    }

    private static func value(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return "—" }
        return string
    }

    private static func onOff(_ value: Bool?) -> String {
        value.map { $0 ? text("On") : text("Off") } ?? text("Unavailable")
    }

    private static func yesNo(_ value: Bool?) -> String {
        value.map { $0 ? text("Yes") : text("No") } ?? "—"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)).grouping(.never))
    }

    /// UIDeviceOrientation raw values.
    private static func deviceOrientation(_ value: Int?) -> String {
        switch value {
        case 1: "portrait"
        case 2: "portrait-upside-down"
        case 3: "landscape-left"
        case 4: "landscape-right"
        case 5: "face-up"
        case 6: "face-down"
        case nil: "—"
        default: "unknown"
        }
    }
}
