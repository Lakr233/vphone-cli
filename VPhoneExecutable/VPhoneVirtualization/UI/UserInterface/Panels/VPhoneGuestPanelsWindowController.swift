import AppKit
import SwiftUI

// MARK: - Panels

/// The guest inspection windows, in the order the Diagnostics and Guest menus
/// list them.
enum VPhoneGuestPanel: CaseIterable {
    case deviceInfo
    case processes
    case console
    case crashLogs
    case services
    case uiInspector
    case controls

    /// The `/v1/health` capability an agent must report before the panel can
    /// talk to it. Older agents answer "Unknown method" for everything else.
    var capability: String {
        switch self {
        case .deviceInfo: "device_info"
        case .processes: "processes"
        case .console, .crashLogs: "logs"
        case .services: "services"
        case .uiInspector: "ui_inspection"
        case .controls: "display"
        }
    }
}

// MARK: - Window Controller

/// Creates each panel window the first time it is opened and keeps its model,
/// so reopening a window shows the last loaded state.
@MainActor
final class VPhoneGuestPanelsWindowController {
    private let control: VPhoneGuestControl
    private var windows: [VPhoneGuestPanel: VPhoneGuestToolWindow] = [:]

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    func show(_ panel: VPhoneGuestPanel) {
        let window = windows[panel] ?? makeWindow(panel)
        windows[panel] = window
        window.show()
    }

    private func makeWindow(_ panel: VPhoneGuestPanel) -> VPhoneGuestToolWindow {
        let control = control
        switch panel {
        case .deviceInfo:
            let model = VPhoneDeviceInfoModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Device Info", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-device-info",
                size: NSSize(width: 560, height: 720),
                minSize: NSSize(width: 480, height: 420),
            ) { VPhoneDeviceInfoView(model: model) }
        case .processes:
            let model = VPhoneProcessesModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Processes", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-processes",
                size: NSSize(width: 1240, height: 640),
                minSize: NSSize(width: 640, height: 360),
            ) { VPhoneProcessesView(model: model) }
        case .console:
            let model = VPhoneConsoleModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Console", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-console",
                size: NSSize(width: 1000, height: 640),
                minSize: NSSize(width: 760, height: 440),
            ) { VPhoneConsoleView(model: model) }
        case .crashLogs:
            let model = VPhoneCrashLogsModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Crash Logs", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-crash-logs",
                size: NSSize(width: 960, height: 600),
                minSize: NSSize(width: 830, height: 440),
            ) { VPhoneCrashLogsView(model: model) }
        case .services:
            let model = VPhoneServicesModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Services", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-services",
                size: NSSize(width: 1000, height: 680),
                minSize: NSSize(width: 760, height: 480),
            ) { VPhoneServicesView(model: model) }
        case .uiInspector:
            let model = VPhoneUIInspectorModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "UI Inspector", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-ui-inspector",
                size: NSSize(width: 1080, height: 720),
                minSize: NSSize(width: 840, height: 540),
            ) { VPhoneUIInspectorView(model: model) }
        case .controls:
            let model = VPhoneControlsModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Controls", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-controls",
                size: NSSize(width: 480, height: 640),
                minSize: NSSize(width: 460, height: 400),
            ) { VPhoneControlsView(model: model) }
        }
    }
}
