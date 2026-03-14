import AppKit
import Foundation

// MARK: - Apps Menu

extension VPhoneMenuController {
    func buildAppsMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Apps")
        menu.autoenablesItems = false

        let browse = makeItem("App Browser", action: #selector(openAppBrowser))
        browse.isEnabled = false
        appsListItem = browse
        menu.addItem(browse)

        menu.addItem(NSMenuItem.separator())

        let openURL = makeItem("Open URL...", action: #selector(openURL))
        openURL.isEnabled = false
        appsOpenURLItem = openURL
        menu.addItem(openURL)

        menu.addItem(NSMenuItem.separator())

        let install = makeItem("Install IPA/TIPA...", action: #selector(installIPAFromDisk))
        install.isEnabled = false
        installPackageItem = install
        menu.addItem(install)

        item.submenu = menu
        return item
    }

    func updateAppsAvailability(available: Bool) {
        appsListItem?.isEnabled = available
    }

    func updateURLAvailability(available: Bool) {
        appsOpenURLItem?.isEnabled = available
    }

    func updateInstallAvailability(available: Bool) {
        installPackageItem?.isEnabled = available
    }

    @objc func openAppBrowser() {
        onAppsPressed?()
    }

    @objc func installIPAFromDisk() {
        guard control.isConnected else {
            showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VPhoneInstallPackage.allowedContentTypes
        panel.prompt = "Install"
        panel.message = "Choose an IPA or TIPA package to install in the guest."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        Task {
            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                showAlert(
                    title: "Install App Package",
                    message: VPhoneInstallPackage.successMessage(
                        for: url.lastPathComponent,
                        detail: result
                    ),
                    style: .informational
                )
            } catch {
                showAlert(title: "Install App Package", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func openURL() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open URL"
        panel.center()

        let lbl = NSTextField(labelWithString: "Enter URL to open on the guest:")
        lbl.frame = NSRect(x: 20, y: 70, width: 380, height: 20)

        let field = NSTextField(frame: NSRect(x: 20, y: 42, width: 380, height: 24))
        field.placeholderString = "https://example.com"

        let ok = NSButton(frame: NSRect(x: 310, y: 10, width: 90, height: 28))
        ok.title = "Open"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = self
        ok.action = #selector(VPhoneMenuController.confirmModal)

        let cancel = NSButton(frame: NSRect(x: 210, y: 10, width: 90, height: 28))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = NSApp
        cancel.action = #selector(NSApplication.abortModal)

        panel.contentView?.addSubview(lbl)
        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(ok)
        panel.contentView?.addSubview(cancel)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .OK, !field.stringValue.isEmpty else { return }
        let url = field.stringValue

        Task {
            do {
                try await control.openURL(url)
                showAlert(title: "Open URL", message: "Opened \(url)", style: .informational)
            } catch {
                showAlert(title: "Open URL", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func confirmModal() {
        NSApp.stopModal(withCode: .OK)
    }
}
