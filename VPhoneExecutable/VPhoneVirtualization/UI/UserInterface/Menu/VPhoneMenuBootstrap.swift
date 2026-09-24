import AppKit

// MARK: - Bootstrap Installation and Removal

/// Installs the Irisin bootstrap in the guest from the Guest menu and shows
/// vphoned's progress while it downloads, extracts and registers it.
extension VPhoneMenuController {
    func updateBootstrapAvailability(available: Bool) {
        installBootstrapItem?.isEnabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
    }

    func updateBootstrapUninstallAvailability(available: Bool) {
        uninstallBootstrapItem?.isEnabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
    }

    @objc func installBootstrap() {
        VPhoneAlert.present(
            title: "Install Bootstrap",
            message: "Choose the bootstrap layout. This installs the latest Irisin release once in the guest.",
            style: .informational,
            buttons: ["roothide", "rootless (deprecated)", "Cancel"],
        ) { [weak self] response in
            let layout: String
            switch response {
            case .alertFirstButtonReturn: layout = "roothide"
            case .alertSecondButtonReturn: layout = "rootless"
            default: return
            }
            self?.performBootstrapInstallation(layout: layout)
        }
    }

    private func performBootstrapInstallation(layout: String) {
        isInstallingBootstrap = true
        installBootstrapItem?.isEnabled = false
        uninstallBootstrapItem?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = VPhoneLocalization.text("Installing the latest Irisin release in the guest.")
        let close = alert.addButton(withTitle: VPhoneLocalization.text("Close"))
        close.isEnabled = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        let statusLabel = NSTextField(labelWithString: VPhoneLocalization.text("Preparing bootstrap…"))
        statusLabel.frame = NSRect(x: 0, y: 26, width: 360, height: 22)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        accessory.addSubview(statusLabel)
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 4, width: 360, height: 16))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        accessory.addSubview(indicator)
        alert.accessoryView = accessory
        VPhoneAlert.present(alert)

        Task {
            defer {
                isInstallingBootstrap = false
                updateBootstrapAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_install"),
                )
                updateBootstrapUninstallAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall"),
                )
                indicator.stopAnimation(nil)
                close.isEnabled = true
            }
            let poller = Task {
                while !Task.isCancelled {
                    if let status = try? await control.bootstrapStatus() {
                        updateBootstrapProgress(status, label: statusLabel, indicator: indicator)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            do {
                let result = try await control.installBootstrap(layout: layout)
                poller.cancel()
                let version = result["version"] as? String ?? ""
                let root = result["jbroot"] as? String ?? ""
                indicator.isIndeterminate = false
                indicator.doubleValue = 100
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installed")
                var message = VPhoneLocalization.format("Installed Irisin %@ in %@.", version, root)
                if let warning = result["service_start_warning"] as? String {
                    message += "\n\n" + VPhoneLocalization.format("Daemon start: %@", warning)
                }
                alert.informativeText = message
            } catch {
                poller.cancel()
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installation failed")
                alert.alertStyle = .warning
                alert.informativeText = String(describing: error)
            }
        }
    }

    @objc func uninstallBootstrap() {
        guard !isInstallingBootstrap && !isUninstallingBootstrap else { return }
        isUninstallingBootstrap = true
        updateBootstrapAvailability(available: false)
        updateBootstrapUninstallAvailability(available: false)
        Task {
            do {
                let installation = try await control.installedBootstrap()
                guard installation["installed"] as? Bool == true,
                      let root = installation["jbroot"] as? String else {
                    VPhoneAlert.present(
                        title: "Uninstall Bootstrap",
                        message: "No completed bootstrap installation was found.",
                        style: .informational,
                    )
                    finishBootstrapUninstall()
                    return
                }
                VPhoneAlert.present(
                    title: "Uninstall Bootstrap",
                    message: VPhoneLocalization.format(
                        "Permanently delete the bootstrap at %@ and restart the guest?", root,
                    ),
                    style: .warning,
                    buttons: ["Delete and Restart", "Cancel"],
                ) { response in
                    guard response == .alertFirstButtonReturn else {
                        self.finishBootstrapUninstall()
                        return
                    }
                    Task {
                        do {
                            _ = try await self.control.uninstallBootstrap(at: root)
                            VPhoneAlert.present(
                                title: "Uninstall Bootstrap",
                                message: "Bootstrap removed. The guest is restarting.",
                                style: .informational,
                            )
                        } catch {
                            VPhoneAlert.present(
                                title: "Bootstrap removal failed",
                                message: String(describing: error),
                                style: .warning,
                            )
                        }
                        self.finishBootstrapUninstall()
                    }
                }
            } catch {
                VPhoneAlert.present(
                    title: "Bootstrap removal failed",
                    message: String(describing: error),
                    style: .warning,
                )
                finishBootstrapUninstall()
            }
        }
    }

    private func finishBootstrapUninstall() {
        isUninstallingBootstrap = false
        updateBootstrapAvailability(
            available: control.isConnected && control.guestCapabilities.contains("bootstrap_install"),
        )
        updateBootstrapUninstallAvailability(
            available: control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall"),
        )
    }

    private func updateBootstrapProgress(
        _ status: [String: Any], label: NSTextField, indicator: NSProgressIndicator
    ) {
        switch status["phase"] as? String {
        case "downloading":
            let received = status["downloaded_bytes"] as? Int64 ?? 0
            let total = status["total_bytes"] as? Int64 ?? 0
            if total > 0 {
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = Double(total)
                indicator.doubleValue = Double(received)
                let current = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                label.stringValue = VPhoneLocalization.format("Downloading Irisin: %@ of %@", current, expected)
            } else {
                label.stringValue = VPhoneLocalization.text("Downloading Irisin…")
            }
        case "extracting":
            label.stringValue = VPhoneLocalization.text("Extracting Irisin…")
        case "installing":
            label.stringValue = VPhoneLocalization.text("Registering Irisin…")
        case "firmware":
            label.stringValue = VPhoneLocalization.text("Recording firmware version…")
        default: break
        }
    }
}
