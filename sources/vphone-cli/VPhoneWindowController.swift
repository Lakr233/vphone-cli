import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController: NSObject, NSToolbarDelegate {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private weak var control: VPhoneControl?
    private var isUploading = false

    private nonisolated static let homeItemID = NSToolbarItem.Identifier("home")
    private nonisolated static let uploadItemID = NSToolbarItem.Identifier("upload")

    func showWindow(
        for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double,
        keyHelper: VPhoneKeyHelper, control: VPhoneControl
    ) {
        self.control = control

        let view = VPhoneVMView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keyHelper = keyHelper
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale, height: CGFloat(screenHeight) / scale
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.contentAspectRatio = windowSize
        window.title = "vphone"
        window.subtitle = "daemon connecting..."
        window.contentView = vmView
        window.center()

        // Toolbar with unified style for two-line title
        let toolbar = NSToolbar(identifier: "vphone-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        keyHelper.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Poll vphoned status for subtitle
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                if self.isUploading { return }
                window.subtitle = control.isConnected ? "daemon connected" : "daemon connecting..."
            }
        }
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.homeItemID {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Home"
                item.toolTip = "Home Button"
                item.image = NSImage(
                    systemSymbolName: "circle.circle", accessibilityDescription: "Home"
                )
                item.target = self
                item.action = #selector(homePressed)
                return item
            }
            if itemIdentifier == Self.uploadItemID {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Upload"
                item.toolTip = "Upload files to /var/mobile/"
                item.image = NSImage(
                    systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Upload"
                )
                item.target = self
                item.action = #selector(uploadPressed)
                return item
            }
            return nil
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.uploadItemID, .flexibleSpace, Self.homeItemID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.homeItemID, Self.uploadItemID, .flexibleSpace, .space]
    }

    // MARK: - Actions

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }

    @objc private func uploadPressed() {
        guard let control, !isUploading else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let window = windowController?.window
        isUploading = true
        Task {
            var uploaded = 0
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let name = url.lastPathComponent
                let dest = "/var/mobile/\(name)"
                window?.subtitle = "uploading \(name)..."
                do {
                    try await control.uploadFile(path: dest, data: data)
                    uploaded += 1
                    print("[files] uploaded \(name) → \(dest) (\(data.count) bytes)")
                } catch {
                    print("[files] upload failed: \(error)")
                    window?.subtitle = "upload failed: \(name)"
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            if uploaded > 0 {
                window?.subtitle = "uploaded \(uploaded) file\(uploaded == 1 ? "" : "s")"
            }
            isUploading = false
        }
    }
}
