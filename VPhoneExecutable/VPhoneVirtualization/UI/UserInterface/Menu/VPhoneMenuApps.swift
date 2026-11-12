import AppKit
import Foundation
import VPhoneCoreKit

// MARK: - Apps Menu

extension VPhoneMenuController {
    func buildAppsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Apps")
        menu.autoenablesItems = false

        let browse = makeItem(
            "App Browser",
            action: #selector(openAppBrowser),
            keyEquivalent: "a",
            modifiers: [.command, .shift],
            symbol: "square.grid.2x2",
        )
        browse.isEnabled = false
        appsListItem = browse
        menu.addItem(browse)

        menu.addItem(NSMenuItem.separator())

        let openURL = makeItem("Open URL…", action: #selector(openURL), symbol: "link")
        openURL.isEnabled = false
        appsOpenURLItem = openURL
        menu.addItem(openURL)

        menu.addItem(NSMenuItem.separator())

        let install = makeItem(
            "Install App Package…",
            action: #selector(installIPAFromDisk),
            symbol: "square.and.arrow.down",
        )
        install.isEnabled = false
        installPackageItem = install
        menu.addItem(install)

        // Only a guest restored as trusted darwinOS reports `cryptex`.
        let cryptex = makeItem("Install Cryptex…", action: #selector(installCryptexFromDisk), symbol: "shippingbox")
        cryptex.isEnabled = false
        installCryptexItem = cryptex
        menu.addItem(cryptex)
        let listCryptexes = makeItem("List Cryptexes", action: #selector(showCryptexes), symbol: "list.bullet")
        listCryptexes.isEnabled = false
        listCryptexesItem = listCryptexes
        menu.addItem(listCryptexes)

        menu.addItem(NSMenuItem.separator())
        addBootstrapItems(to: menu)

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

    func updateCryptexAvailability(available: Bool) {
        installCryptexItem?.isEnabled = available
        listCryptexesItem?.isEnabled = available
    }

    @objc func installCryptexFromDisk() {
        guard control.isConnected else {
            VPhoneAlert.present(
                title: "Install Cryptex", message: "The guest is not connected. Start a VM, then try again.",
                style: .warning,
            )
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = VPhoneLocalization.text("Install")
        panel.message = VPhoneLocalization.text("Choose Root folder (incl. e.g., usr/bin and Library/LaunchDaemons)")
        VPhoneAlert.present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.installCryptex(from: url)
        }
    }

    private func installCryptex(from url: URL) {
        Task {
            do {
                let result = try await control.installCryptex(from: url)
                print("[cryptex] \(result)")
                VPhoneAlert.present(
                    title: "Install Cryptex",
                    message: VPhoneLocalization.installedMessage(for: url.lastPathComponent, detail: result),
                    style: .informational,
                )
            } catch {
                print("[cryptex] install failed: \(error)")
                VPhoneAlert.present(title: "Install Cryptex", message: error.localizedDescription, style: .warning)
            }
        }
    }

    @objc func showCryptexes() {
        Task {
            do {
                let output = try await control.listCryptexes()
                VPhoneAlert.present(
                    title: "Cryptexes",
                    message: output.isEmpty ? VPhoneLocalization.text("No cryptexes are installed.") : output,
                    style: .informational,
                )
            } catch {
                VPhoneAlert.present(title: "Cryptexes", message: error.localizedDescription, style: .warning)
            }
        }
    }

    @objc func openAppBrowser() {
        onAppsPressed?()
    }

    @objc func installIPAFromDisk() {
        guard control.isConnected else {
            VPhoneAlert.present(
                title: "Install App Package", message: "The guest is not connected. Start a VM, then try again.",
                style: .warning,
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VPhoneInstallPackage.allowedContentTypes
        panel.prompt = VPhoneLocalization.text("Install")
        panel.message = VPhoneLocalization.text("Choose an IPA or TIPA package to install in the guest.")

        VPhoneAlert.present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.installIPA(from: url)
        }
    }

    private func installIPA(from url: URL) {
        Task {
            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                VPhoneAlert.present(
                    title: "Install App Package",
                    message: VPhoneLocalization.installedMessage(
                        for: url.lastPathComponent,
                        detail: result,
                    ),
                    style: .informational,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Install App Package",
                    message: "Unable to install the app package. Check the file and guest connection, then try again.",
                    style: .warning,
                )
            }
        }
    }

    @objc func openURL() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://example.com"
        field.setAccessibilityLabel(VPhoneLocalization.text("URL to open on the guest"))

        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Open URL")
        alert.informativeText = VPhoneLocalization.text("Enter a URL to open on the guest.")
        alert.accessoryView = field
        alert.addButton(withTitle: VPhoneLocalization.text("Open"))
        alert.addButton(withTitle: VPhoneLocalization.text("Cancel"))
        alert.window.initialFirstResponder = field

        VPhoneAlert.present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            self?.openOnGuest(field.stringValue)
        }
    }

    private func openOnGuest(_ url: String) {
        Task {
            do {
                try await control.openURL(url)
                VPhoneAlert.present(
                    title: "Open URL", message: VPhoneLocalization.format("Opened %@", url), style: .informational,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Open URL",
                    message: "Unable to open the URL on the guest. Check the URL and guest connection, then try again.",
                    style: .warning,
                )
            }
        }
    }
}
