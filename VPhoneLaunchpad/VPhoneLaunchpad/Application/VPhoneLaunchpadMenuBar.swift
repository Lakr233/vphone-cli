import AppKit
import SwiftUI

// MARK: - Setting

/// Menu bar mode: closing the window keeps Launchpad running in the menu bar,
/// and the Dock icon follows what is on screen.
enum VPhoneLaunchpadMenuBar {
    static let key = "VPhoneLaunchpadShowsInMenuBar"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

// MARK: - Menu

struct VPhoneLaunchpadMenuBarMenu: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Launchpad", action: openLaunchpad)
        Divider()
        if model.machines.machines.isEmpty {
            Text("No Machines")
        }
        ForEach(model.machines.machines) { machine in
            let state = model.machines.state(of: machine.path)
            Menu {
                VPhoneLaunchpadMachineActions(machines: [machine], willRequest: openLaunchpad)
            } label: {
                Label(machine.name, systemImage: state == .running ? "circle.fill" : "circle")
            }
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openLaunchpad() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - Dock icon

/// Shows the Dock icon while a window, minimized or not, or a menu is open,
/// and hides it otherwise. Checked once a second, in every run loop mode so
/// it also runs while a menu is tracking.
@MainActor
final class VPhoneLaunchpadDockPolicy {
    private var timer: Timer?
    private var menusOpen = 0

    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menusOpen += 1
                self?.update()
            }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menusOpen = max(0, self.menusOpen - 1)
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        guard VPhoneLaunchpadMenuBar.isEnabled else {
            setPolicy(.regular)
            return
        }
        // Titled windows only: the status item and open menus are windows too.
        let hasWindow = NSApp.windows.contains { window in
            window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
        setPolicy(hasWindow || menusOpen > 0 ? .regular : .accessory)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
