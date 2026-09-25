import AppKit
import UniformTypeIdentifiers

// MARK: - Bootstrap Installation and Removal

/// Installs the Irisin bootstrap in the guest from the Guest menu and shows
/// vphoned's progress while it downloads, extracts and registers it.
extension VPhoneMenuController {
    func updateBootstrapAvailability(available: Bool) {
        let enabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
        installBootstrapItem?.isEnabled = enabled
        installBootstrapFromFileItem?.isEnabled = enabled
    }

    func updateBootstrapUninstallAvailability(available: Bool) {
        let enabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
        uninstallBootstrapItem?.isEnabled = enabled
        uninstallBootstrapNoRestartItem?.isEnabled = enabled
    }

    @objc func installBootstrap() {
        chooseBootstrapLayout(localURL: nil)
    }

    @objc func installBootstrapFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "deb") ?? .data]
        panel.prompt = VPhoneLocalization.text("Install")
        panel.message = VPhoneLocalization.text("Choose an Irisin .deb package to install in the guest.")
        VPhoneAlert.present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.chooseBootstrapLayout(localURL: url)
        }
    }

    private func chooseBootstrapLayout(localURL: URL?) {
        let message = if let localURL {
            VPhoneLocalization.format("Choose the bootstrap layout for %@.", localURL.lastPathComponent)
        } else {
            VPhoneLocalization.text("Choose the bootstrap layout. This installs the latest Irisin release once in the guest.")
        }
        VPhoneAlert.present(
            title: "Install Bootstrap",
            message: message,
            style: .informational,
            buttons: ["roothide", "rootless (deprecated)", "Cancel"],
        ) { [weak self] response in
            let layout: String
            switch response {
            case .alertFirstButtonReturn: layout = "roothide"
            case .alertSecondButtonReturn: layout = "rootless"
            default: return
            }
            self?.performBootstrapInstallation(layout: layout, localURL: localURL)
        }
    }

    private func performBootstrapInstallation(layout: String, localURL: URL?) {
        isInstallingBootstrap = true
        installBootstrapItem?.isEnabled = false
        installBootstrapFromFileItem?.isEnabled = false
        uninstallBootstrapItem?.isEnabled = false
        uninstallBootstrapNoRestartItem?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = if let localURL {
            VPhoneLocalization.format("Installing %@ in the guest.", localURL.lastPathComponent)
        } else {
            VPhoneLocalization.text("Installing the latest Irisin release in the guest.")
        }
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
                let result = try await control.installBootstrap(layout: layout, localURL: localURL)
                poller.cancel()
                let version = result["version"] as? String ?? ""
                let root = result["jbroot"] as? String ?? ""
                indicator.isIndeterminate = false
                indicator.doubleValue = 100
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installed")
                alert.informativeText = if result["service_start_warning"] as? String != nil {
                    VPhoneLocalization.format(
                        "Installed Irisin %1$@ in %2$@.\n\nSome services did not start, but the bootstrap is ready to use.",
                        version,
                        root,
                    )
                } else {
                    VPhoneLocalization.format("Installed Irisin %@ in %@.", version, root)
                }
            } catch {
                poller.cancel()
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installation failed")
                alert.alertStyle = .warning
                alert.informativeText = if localURL != nil {
                    VPhoneLocalization.text(
                        "Unable to install the bootstrap. Check the file and guest connection, then try again.",
                    )
                } else {
                    VPhoneLocalization.text(
                        "Unable to install the bootstrap. Check that the guest agent is connected, then try again.",
                    )
                }
            }
        }
    }

    @objc func uninstallBootstrap() {
        performBootstrapUninstall(reboot: true)
    }

    @objc func uninstallBootstrapWithoutRestart() {
        performBootstrapUninstall(reboot: false)
    }

    private func performBootstrapUninstall(reboot: Bool) {
        guard !isInstallingBootstrap && !isUninstallingBootstrap else { return }
        isUninstallingBootstrap = true
        updateBootstrapAvailability(available: false)
        updateBootstrapUninstallAvailability(available: false)
        Task {
            do {
                let installation = try await control.installedBootstrap()
                guard installation["installed"] as? Bool == true,
                      let roots = installation["roots"] as? [String], !roots.isEmpty else {
                    VPhoneAlert.present(
                        title: "Uninstall Bootstrap",
                        message: "No bootstrap environment was found.",
                        style: .informational,
                    )
                    finishBootstrapUninstall()
                    return
                }
                let message = if reboot {
                    VPhoneLocalization.format(
                        "Permanently delete these bootstrap environments and restart the guest?\n%@",
                        roots.joined(separator: "\n"),
                    )
                } else {
                    VPhoneLocalization.format(
                        "Permanently delete these bootstrap environments without restarting the guest?\n%@",
                        roots.joined(separator: "\n"),
                    )
                }
                VPhoneAlert.present(
                    title: "Uninstall Bootstrap",
                    message: message,
                    style: .warning,
                    buttons: [reboot ? "Delete and Restart" : "Delete", "Cancel"],
                ) { response in
                    guard response == .alertFirstButtonReturn else {
                        self.finishBootstrapUninstall()
                        return
                    }
                    Task {
                        do {
                            _ = try await self.control.uninstallBootstrap(at: roots, reboot: reboot)
                            VPhoneAlert.present(
                                title: "Uninstall Bootstrap",
                                message: reboot
                                    ? "Bootstrap removed. The guest is restarting."
                                    : "Bootstrap removed. The guest was not restarted.",
                                style: .informational,
                            )
                        } catch {
                            VPhoneAlert.present(
                                title: "Unable to Remove Bootstrap",
                                message: "Unable to remove the bootstrap. Check that the guest agent is connected, then try again.",
                                style: .warning,
                            )
                        }
                        self.finishBootstrapUninstall()
                    }
                }
            } catch {
                VPhoneAlert.present(
                    title: "Unable to Remove Bootstrap",
                    message: "Unable to remove the bootstrap. Check that the guest agent is connected, then try again.",
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
