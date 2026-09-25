import AppKit
import SwiftUI

@main
struct VPhoneLaunchpadApp: App {
    @NSApplicationDelegateAdaptor(VPhoneLaunchpadAppDelegate.self) private var delegate
    @State private var model = VPhoneLaunchpadModel()

    var body: some Scene {
        Window("vphone-launchpad", id: "main") {
            VPhoneLaunchpadRootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Guests keep running when Launchpad quits (their output goes to a log
/// file, not a pipe). A machine being created does not survive, so quitting
/// then asks first.
@MainActor
final class VPhoneLaunchpadAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: VPhoneLaunchpadModel?

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return .terminateNow
            }
        #endif
        guard let model, model.machines.hasActiveCreation else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Stop creating the machine?"
        alert.informativeText = "Quitting stops the New Machine pipeline. You can retry it later from the step it stopped at."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
