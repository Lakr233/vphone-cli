import AppKit
import SwiftUI

@main
struct VPhoneLaunchpadApp: App {
    @NSApplicationDelegateAdaptor(VPhoneLaunchpadAppDelegate.self) private var delegate
    @State private var model = VPhoneLaunchpadModel()
    @AppStorage(VPhoneLaunchpadMenuBar.key) private var showsInMenuBar = false

    init() {
        // AppKit must not restore saved window state. Everything starts from
        // the window's task, so a launch that restores a state with no window
        // in it never opens the control socket, and after a crash AppKit
        // holds the launch at an alert about reopening windows.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        Window(Text(verbatim: "vphone-launchpad"), id: "main") {
            VPhoneLaunchpadRootView()
                .environment(model)
                .confirmCloseDuringCreation(delegate)
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        // Nor is any saved: the window's frame is kept under its own name.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New…") { model.machineSheetRequest = .newMachine }
                    .keyboardShortcut("n")
                    .disabled(model.bundles.defaultVersion == nil)
                Button("Import…") { model.machines.chooseImport() }
                    .keyboardShortcut("o")
                Divider()
                Button("Downloaded Firmware…") { model.present(.ipswCache) }
                if model.machines.hasTemplates {
                    Button("Templates…") { model.present(.templates) }
                }
            }
            // Now rather than on the next five-second tick: the machine list,
            // then the templates, which also measures disk use again.
            CommandGroup(before: .toolbar) {
                Button("Refresh") {
                    Task {
                        await model.machines.refresh()
                        await model.machines.refreshTemplates()
                    }
                }
                .keyboardShortcut("r")
                // Every command Launchpad ran, not one machine's: here rather
                // than in a machine's menu.
                Button("Recent Commands") { model.machineSheetRequest = .commands }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
            }
            // The selected machines' actions, as the toolbar's Actions menu
            // has them, with shortcuts.
            CommandGroup(after: .pasteboard) {
                Divider()
                VPhoneLaunchpadMachineActions(machines: model.machines.selectedMachines, placement: .editMenu)
                    .environment(model)
            }
            CommandMenu("Machine") {
                VPhoneLaunchpadMachineActions(machines: model.machines.selectedMachines, placement: .machineMenu)
                    .environment(model)
            }
            CommandGroup(after: .appSettings) {
                Button("Host Setup…") { model.present(.hostSetup) }
                Button("Core Bundle…") { model.present(.coreBundle) }
            }
        }

        MenuBarExtra(isInserted: $showsInMenuBar) {
            VPhoneLaunchpadMenuBarMenu()
                .environment(model)
        } label: {
            Label {
                Text(verbatim: "vphone-launchpad")
            } icon: {
                Image(systemName: "iphone")
            }
        }
    }
}

/// Guests keep running when Launchpad quits (their output goes to a log
/// file, not a pipe). A machine being created, an import and an export do
/// not survive, so quitting then asks first.
@MainActor
final class VPhoneLaunchpadAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: VPhoneLaunchpadModel? {
        didSet { importOpened() }
    }

    /// Archives opened from Finder before the window gave us the model.
    private var opened: [URL] = []
    private let dockPolicy = VPhoneLaunchpadDockPolicy()
    /// Set once the user confirms closing the last window while a machine is
    /// being created, so the terminate path that follows does not ask again.
    private var confirmedClose = false

    func applicationDidFinishLaunching(_: Notification) {
        dockPolicy.start()
    }

    /// A `.vpea` opened in Finder, or dropped on the Dock icon, is imported
    /// into the default library, as Import… would; an IPSW is added to the
    /// IPSW cache.
    func application(_: NSApplication, open urls: [URL]) {
        opened += urls.filter(\.isFileURL)
        importOpened()
    }

    private func importOpened() {
        guard let model, !opened.isEmpty else {
            return
        }
        let archives = opened.filter { !VPhoneLaunchpadIPSWImport.isIPSW($0) }
        model.ipswImport.register(opened, model: model)
        opened = []
        Task {
            for archive in archives {
                await model.machines.importArchive(archive)
            }
        }
    }

    /// In menu bar mode the app stays behind in the menu bar. Closing the
    /// window while a machine is being created is refused in
    /// `windowShouldClose`, so this is not asked until the window is gone.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !VPhoneLaunchpadMenuBar.isEnabled
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return .terminateNow
            }
        #endif
        guard let model else {
            return .terminateNow
        }
        if !confirmedClose, model.machines.hasActiveCreation || model.machines.hasActiveTransfer, !confirmStopWork() {
            return .terminateCancel
        }
        guard model.machines.hasActiveTransfer else {
            return .terminateNow
        }
        // A `vm import` or `vm export` left behind would go on writing with
        // nobody reading its output. Stopped, each removes what it wrote.
        Task {
            await model.machines.stopTransfers()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The close button, Close menu item and ⌘W all ask here, while the
    /// window is still up. Without the menu bar, closing the last window
    /// quits, so the alert says Quit. Cancel refuses the close. In menu bar
    /// mode closing only hides the window, so no confirmation is needed.
    func windowShouldClose(_: NSWindow) -> Bool {
        guard !VPhoneLaunchpadMenuBar.isEnabled, let model,
              model.machines.hasActiveCreation || model.machines.hasActiveTransfer
        else {
            return true
        }
        guard confirmStopWork() else {
            return false
        }
        confirmedClose = true
        return true
    }

    private func confirmStopWork() -> Bool {
        let alert = NSAlert()
        if model?.machines.hasActiveCreation == true {
            alert.messageText = String(localized: "Stop Creating Machine?")
            alert.informativeText = String(
                localized: "Quitting stops creating this machine. You can retry later from the step where it stopped.",
            )
        } else {
            alert.messageText = String(localized: "Stop Importing and Exporting?")
            alert.informativeText = String(
                localized: "Quitting stops every import and export under way and removes what they had written.",
            )
        }
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Installed in the main window's content so that window, and no other, asks
/// before closing while a machine is being created. SwiftUI already owns the
/// window delegate, so the question is forwarded and every other message goes
/// to the delegate that was there.
private final class VPhoneLaunchpadWindowCloseHook: NSView, NSWindowDelegate {
    private weak var delegate: VPhoneLaunchpadAppDelegate?
    /// Read from `NSObject`'s nonisolated forwarding methods. AppKit calls
    /// those, and moves this view between windows, on the main thread.
    private nonisolated(unsafe) weak var forwarded: NSWindowDelegate?

    init(delegate: VPhoneLaunchpadAppDelegate) {
        self.delegate = delegate
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.delegate !== self else { return }
        forwarded = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forwarded?.windowShouldClose?(sender) == false {
            return false
        }
        return delegate?.windowShouldClose(sender) ?? true
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwarded?.responds(to: selector) == true
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        if forwarded?.responds(to: selector) == true {
            return forwarded
        }
        return super.forwardingTarget(for: selector)
    }
}

extension View {
    /// Asks before this window closes while a machine is being created.
    func confirmCloseDuringCreation(_ delegate: VPhoneLaunchpadAppDelegate) -> some View {
        background {
            VPhoneLaunchpadWindowCloseInstaller(delegate: delegate)
        }
    }
}

private struct VPhoneLaunchpadWindowCloseInstaller: NSViewRepresentable {
    let delegate: VPhoneLaunchpadAppDelegate

    func makeNSView(context _: Context) -> NSView {
        MainActor.assumeIsolated {
            VPhoneLaunchpadWindowCloseHook(delegate: delegate)
        }
    }

    func updateNSView(_: NSView, context _: Context) {}
}
