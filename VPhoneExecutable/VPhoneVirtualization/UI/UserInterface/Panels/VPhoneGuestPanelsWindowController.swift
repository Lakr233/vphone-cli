import AppKit
import SwiftUI

// MARK: - Panels

/// The guest inspection windows, in the order the Diagnostics and Device menus
/// list them.
enum VPhoneGuestPanel: CaseIterable {
    case deviceInfo
    case processes
    case console
    case crashLogs
    case services
    case controls
    case gyroscope
    case attitude
    case foldPosture

    /// The `/v1/health` capability an agent must report before the panel can
    /// talk to it. Older agents answer "Unknown method" for everything else.
    var capability: String {
        switch self {
        case .deviceInfo: "device_info"
        case .processes: "processes"
        case .console, .crashLogs: "logs"
        case .services: "services"
        case .controls: "display"
        case .gyroscope: "motion_gyroscope_toggle"
        case .attitude: "motion_attitude"
        case .foldPosture: "device_pose"
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
    private var attitudeDials: VPhoneAttitudeDialsWindowController?
    weak var displayWindow: NSWindow? {
        didSet { attitudeDials?.attach(to: displayWindow) }
    }

    /// Saves the memory of a guest process, by pid and kernel name; set by
    /// the menu controller, which owns the VM.
    var onDumpProcess: ((Int32, String) -> Void)?

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    func show(_ panel: VPhoneGuestPanel) {
        let window = windows[panel] ?? makeWindow(panel)
        windows[panel] = window
        window.show()
    }

    func attitudeConnectionChanged() {
        attitudeDials?.connectionChanged(control.isConnected && control.guestCapabilities.contains("motion_attitude"))
    }

    func closeAttitudeDials() {
        attitudeDials?.close()
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
            model.onDumpMemory = { [weak self] row in self?.onDumpProcess?(Int32(row.pid), row.name) }
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
        case .controls:
            let model = VPhoneControlsModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Controls", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-controls",
                size: NSSize(width: 480, height: 640),
                minSize: NSSize(width: 460, height: 400),
            ) { VPhoneControlsView(model: model) }
        case .gyroscope:
            let model = VPhoneMotionModel(
                read: { try await control.readGyroscope() },
                write: { try await control.setGyroscope($0) },
            )
            return VPhoneGuestToolWindow(
                title: String(localized: "3D Gyroscope", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-gyroscope",
                size: NSSize(width: 440, height: 380),
                minSize: NSSize(width: 400, height: 340),
            ) { VPhoneMotionView(model: model, sensor: .gyroscope, connected: { control.isConnected }) }
        case .attitude:
            let model = VPhoneMotionModel(
                ranges: VPhoneMotionSensor.attitude.ranges,
                rejectionMessage: "Guest did not apply the attitude configuration",
                read: { try await control.readAttitude() },
                write: { try await control.setAttitude($0) },
            )
            let dials = VPhoneAttitudeDialsWindowController(model: model)
            attitudeDials = dials
            dials.attach(to: displayWindow)
            attitudeConnectionChanged()
            return VPhoneGuestToolWindow(
                title: String(localized: "Device Attitude", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-attitude",
                size: NSSize(width: 480, height: 520),
                minSize: NSSize(width: 440, height: 480),
            ) { VPhoneMotionView(model: model, sensor: .attitude, connected: { control.isConnected }, attitudeDials: dials) }
        case .foldPosture:
            let model = VPhoneFoldModel(control: control)
            return VPhoneGuestToolWindow(
                title: String(localized: "Fold Posture", bundle: VPhoneLocalization.bundle),
                autosaveName: "vphone-panel-fold-posture",
                size: NSSize(width: 440, height: 560),
                minSize: NSSize(width: 400, height: 480),
            ) { VPhoneFoldView(model: model) }
        }
    }
}
