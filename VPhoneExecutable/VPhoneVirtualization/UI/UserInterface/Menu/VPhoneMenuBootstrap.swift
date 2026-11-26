import AppKit
import UniformTypeIdentifiers

// MARK: - Bootstrap Installation and Removal

/// Installs the Irisin bootstrap in the guest from the Apps menu and shows
/// vphoned's progress while it downloads, extracts and registers it.
extension VPhoneMenuController {
    /// Install and Uninstall, each with an Option alternate.
    func addBootstrapItems(to menu: NSMenu) {
        let install = makeItem(
            "Install Bootstrap…",
            action: #selector(installBootstrap),
            symbol: "arrow.down.circle",
        )
        install.isEnabled = false
        installBootstrapItem = install
        menu.addItem(install)
        let installFromFile = makeItem(
            "Install Bootstrap from File…",
            action: #selector(installBootstrapFromFile),
            modifiers: [.option],
            symbol: "doc",
        )
        installFromFile.isAlternate = true
        installFromFile.isEnabled = false
        installBootstrapFromFileItem = installFromFile
        menu.addItem(installFromFile)

        let uninstall = makeItem(
            "Uninstall Bootstrap…",
            action: #selector(uninstallBootstrap),
            symbol: "trash",
        )
        uninstall.isEnabled = false
        uninstallBootstrapItem = uninstall
        menu.addItem(uninstall)
        let uninstallNoRestart = makeItem(
            "Uninstall Bootstrap Without Restarting…",
            action: #selector(uninstallBootstrapWithoutRestart),
            modifiers: [.option],
            symbol: "trash",
        )
        uninstallNoRestart.isAlternate = true
        uninstallNoRestart.isEnabled = false
        uninstallBootstrapNoRestartItem = uninstallNoRestart
        menu.addItem(uninstallNoRestart)

        let rebuild = makeItem(
            "Rebuild App Registrations",
            action: #selector(rebuildAppRegistrations),
            symbol: "arrow.clockwise.circle",
        )
        rebuild.isEnabled = false
        rebuildAppRegistrationsItem = rebuild
        menu.addItem(rebuild)
    }

    func updateBootstrapAvailability(available: Bool) {
        let enabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
        installBootstrapItem?.isEnabled = enabled
        installBootstrapFromFileItem?.isEnabled = enabled
    }

    func updateBootstrapUninstallAvailability(available: Bool) {
        let enabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
        uninstallBootstrapItem?.isEnabled = enabled
        uninstallBootstrapNoRestartItem?.isEnabled = enabled
        rebuildAppRegistrationsItem?.isEnabled = enabled && !isRebuildingAppRegistrations
    }

    @objc func installBootstrap() {
        unlessBootstrapInstalled { [weak self] in
            self?.chooseBootstrapLayout(localURL: nil)
        }
    }

    @objc func installBootstrapFromFile() {
        unlessBootstrapInstalled { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "deb") ?? .data]
            panel.prompt = VPhoneLocalization.text("Install")
            panel.message = VPhoneLocalization.text("Choose an Irisin .deb package to install in the guest.")
            VPhoneAlert.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                self?.chooseBootstrapLayout(localURL: url)
            }
        }
    }

    /// vphoned installs the bootstrap once and refuses a second install, so
    /// ask it first and explain instead of starting an install that fails.
    /// A guest that cannot be asked goes straight on; its install answer is
    /// handled the same way below.
    private func unlessBootstrapInstalled(_ proceed: @escaping @MainActor () -> Void) {
        guard !isInstallingBootstrap, !isUninstallingBootstrap else { return }
        Task {
            if let installation = await control.completedBootstrap() {
                presentBootstrapAlreadyInstalled(root: installation.root)
            } else {
                proceed()
            }
        }
    }

    private func presentBootstrapAlreadyInstalled(root: String) {
        let message = VPhoneLocalization.format(
            "The bootstrap is already installed in %@. To reinstall it, uninstall the bootstrap first.", root,
        )
        let canUninstall = control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall")
        VPhoneAlert.present(
            title: "Bootstrap Already Installed",
            message: message,
            style: .informational,
            buttons: canUninstall ? ["OK", "Uninstall Bootstrap…"] : ["OK"],
        ) { [weak self] response in
            if canUninstall, response == .alertSecondButtonReturn {
                self?.uninstallBootstrap()
            }
        }
    }

    private func chooseBootstrapLayout(localURL: URL?) {
        let message = if let localURL {
            VPhoneLocalization.format("Choose the bootstrap layout for %@.", localURL.lastPathComponent)
        } else {
            VPhoneLocalization.text("Choose the bootstrap layout. This installs the latest Irisin release once in the guest.")
        }
        // Irisin serves an Apple TV only as RootHide; vphoned refuses rootless
        // there, so the button stays visible but cannot be chosen.
        let offersRootless = !showsTVControls
        let rootlessOnly = control.guestCapabilities.contains("bootstrap_rootless_only")
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = message
        alert.alertStyle = .informational
        let roothide = alert.addButton(withTitle: VPhoneLocalization.text("roothide"))
        roothide.isEnabled = !rootlessOnly
        let rootless = alert.addButton(
            withTitle: VPhoneLocalization.text(rootlessOnly ? "rootless" : offersRootless ? "rootless (deprecated)" : "rootless (unavailable)"),
        )
        rootless.isEnabled = offersRootless
        if rootlessOnly {
            roothide.keyEquivalent = ""
            rootless.keyEquivalent = "\r"
        }
        alert.addButton(withTitle: VPhoneLocalization.text("Cancel")).keyEquivalent = "\u{1b}"
        // Irisin alone leaves the guest without a shell, SSH or coreutils, so
        // the packages are on by default; a guest whose vphoned cannot install
        // them says so instead of offering a box that would fail.
        let offersPackages = control.guestCapabilities.contains("bootstrap_packages")
        let packages = NSButton(
            checkboxWithTitle: VPhoneLocalization.text("Also install OwnGoal Bootstrap for vphone"),
            target: nil,
            action: nil,
        )
        packages.state = offersPackages ? .on : .off
        packages.isEnabled = offersPackages
        packages.sizeToFit()
        // NSAlert insets the accessory 16 points from each edge; inset another
        // 6 so the box lines up with the alert's text column.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: packages.frame.height))
        packages.setFrameOrigin(NSPoint(x: 6, y: 0))
        accessory.addSubview(packages)
        alert.accessoryView = accessory
        VPhoneAlert.present(alert) { [weak self] response in
            let layout: String
            switch response {
            case .alertFirstButtonReturn where !rootlessOnly: layout = "roothide"
            case .alertSecondButtonReturn where offersRootless: layout = "rootless"
            default: return
            }
            self?.performBootstrapInstallation(
                layout: layout, localURL: localURL, alsoInstallPackages: packages.state == .on,
            )
        }
    }

    private func performBootstrapInstallation(layout: String, localURL: URL?, alsoInstallPackages: Bool) {
        isInstallingBootstrap = true
        installBootstrapItem?.isEnabled = false
        installBootstrapFromFileItem?.isEnabled = false
        uninstallBootstrapItem?.isEnabled = false
        uninstallBootstrapNoRestartItem?.isEnabled = false
        rebuildAppRegistrationsItem?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = if let localURL {
            VPhoneLocalization.format("Installing %@ in the guest.", localURL.lastPathComponent)
        } else {
            VPhoneLocalization.text("Installing the latest Irisin release in the guest.")
        }
        let close = alert.addButton(withTitle: VPhoneLocalization.text("Close"))
        close.isEnabled = false
        // NSAlert places the accessory 16 points from each edge; inset its
        // contents another 6 points to align with the alert's text columns.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        let statusLabel = NSTextField(labelWithString: VPhoneLocalization.text("Preparing bootstrap…"))
        statusLabel.frame = NSRect(x: 6, y: 26, width: 348, height: 22)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        accessory.addSubview(statusLabel)
        let indicator = NSProgressIndicator(frame: NSRect(x: 6, y: 4, width: 348, height: 16))
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
                if indicator.isIndeterminate {
                    indicator.stopAnimation(nil)
                }
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
                await poller.value
                let version = result["version"] as? String ?? ""
                let root = result["jbroot"] as? String ?? ""
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = 100
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
                if alsoInstallPackages {
                    let irisin = alert.informativeText
                    // Irisin is in; the packages can run for half an hour more.
                    // The sheet is document-modal, so holding Close shut until
                    // then would lock the VM window for the whole install, and
                    // quitting to escape would stop the guest mid-transaction.
                    close.isEnabled = true
                    indicator.isIndeterminate = true
                    indicator.startAnimation(nil)
                    switch await installBootstrapPackages(label: statusLabel, indicator: indicator) {
                    case let .installed(packages):
                        indicator.stopAnimation(nil)
                        indicator.isIndeterminate = false
                        indicator.doubleValue = 100
                        statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installed")
                        alert.informativeText = packages.isEmpty
                            ? irisin
                            : irisin + "\n\n" + VPhoneLocalization.format(
                                "Installed %@.", packages.joined(separator: ", "),
                            )
                    case let .skipped(note):
                        indicator.stopAnimation(nil)
                        indicator.isIndeterminate = false
                        indicator.doubleValue = 100
                        statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installed")
                        alert.informativeText = irisin + "\n\n" + VPhoneLocalization.format(
                            "No packages were installed: %@.", note,
                        )
                    case let .failed(reason):
                        indicator.stopAnimation(nil)
                        indicator.isIndeterminate = false
                        indicator.doubleValue = 100
                        // Irisin is installed; only the packages failed. Say so,
                        // and name the way back, since asking for the bootstrap
                        // again only answers that it is already installed.
                        statusLabel.stringValue = VPhoneLocalization.text("Packages not installed")
                        alert.alertStyle = .warning
                        alert.informativeText = irisin + "\n\n" + VPhoneLocalization.format(
                            "The packages were not installed.\n\n%@\n\nOpen Irisin in the guest and run Bootstrap Install to finish.",
                            reason,
                        )
                    }
                }
            } catch VPhoneGuestControl.ControlError.bootstrapAlreadyInstalled {
                poller.cancel()
                await poller.value
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap already installed")
                alert.informativeText = VPhoneLocalization.text(
                    "The bootstrap is already installed. To reinstall it, uninstall the bootstrap first.",
                )
            } catch let VPhoneGuestControl.ControlError.guestError(message) where !message.isEmpty {
                // vphoned answered: show its reason rather than suggest the
                // connection is at fault.
                poller.cancel()
                await poller.value
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installation failed")
                alert.alertStyle = .warning
                alert.informativeText = VPhoneLocalization.format("Unable to install the bootstrap.\n\n%@", message)
            } catch {
                poller.cancel()
                await poller.value
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
        guard !isInstallingBootstrap, !isUninstallingBootstrap else { return }
        isUninstallingBootstrap = true
        updateBootstrapAvailability(available: false)
        updateBootstrapUninstallAvailability(available: false)
        Task {
            do {
                let installation = try await control.installedBootstrap()
                guard installation["installed"] as? Bool == true,
                      let roots = installation["roots"] as? [String], !roots.isEmpty
                else {
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

    // MARK: - App Registrations

    /// `uicache -a`: registers apps added to or updated in the bootstrap's
    /// /Applications and removes records of apps deleted from it.
    @objc func rebuildAppRegistrations() {
        guard !isInstallingBootstrap, !isUninstallingBootstrap, !isRebuildingAppRegistrations else { return }
        isRebuildingAppRegistrations = true
        rebuildAppRegistrationsItem?.isEnabled = false
        Task {
            defer {
                isRebuildingAppRegistrations = false
                updateBootstrapUninstallAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall"),
                )
            }
            guard await control.completedBootstrap() != nil else {
                VPhoneAlert.present(
                    title: "Rebuild App Registrations",
                    message: "No bootstrap environment was found.",
                    style: .informational,
                )
                return
            }
            do {
                let result = try await control.rebuildBootstrapAppRegistrations()
                let count = { (key: String) in String((result[key] as? [Any])?.count ?? 0) }
                VPhoneAlert.present(
                    title: "Rebuild App Registrations",
                    message: VPhoneLocalization.format(
                        "Registered %1$@, removed %2$@, %3$@ unchanged.",
                        count("registered"),
                        count("unregistered"),
                        count("unchanged"),
                    ),
                    style: .informational,
                )
            } catch let VPhoneGuestControl.ControlError.guestError(message) where !message.isEmpty {
                VPhoneAlert.present(
                    title: "Unable to Rebuild App Registrations",
                    message: VPhoneLocalization.format("Unable to rebuild app registrations.\n\n%@", message),
                    style: .warning,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Unable to Rebuild App Registrations",
                    message: "Unable to rebuild app registrations. Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }

    private func updateBootstrapProgress(
        _ status: [String: Any], label: NSTextField, indicator: NSProgressIndicator,
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
        case "packages":
            label.stringValue = VPhoneLocalization.text("Installing packages…")
        default: break
        }
    }

    /// What came of installing the packages.
    private enum PackagesOutcome {
        case installed([String])
        case skipped(String)
        case failed(String)
    }

    /// Runs `bootstrap.packages` and waits for it to finish.
    ///
    /// A silent guest is dropped at the 120 s read timeout and the whole
    /// exchange at 180 s, while the guest carries on, so for a call that runs
    /// far longer than either the reply is usually lost. A lost reply is
    /// followed through `bootstrap.status` instead of being reported.
    ///
    /// Only errors raised before anything reached the guest are failures on
    /// their own: there is no work for a status to describe, so following one
    /// would wait out the full deadline and then blame the time.
    private func installBootstrapPackages(
        label: NSTextField, indicator: NSProgressIndicator,
    ) async -> PackagesOutcome {
        let deadline = Date().addingTimeInterval(1800)
        label.stringValue = VPhoneLocalization.text("Installing packages…")
        do {
            switch VPhoneBootstrapPackagesStatus.outcome(forReply: try await control.installBootstrapPackages()) {
            case let .skipped(note): return .skipped(note)
            case let .completed(packages): return .installed(packages)
            case .running, .failed: return .installed([])
            }
        } catch let VPhoneGuestControl.ControlError.guestError(message) where !message.isEmpty {
            return .failed(message)
        } catch let error as VPhoneGuestControl.ControlError {
            switch error {
            case .notConnected, .guestPaused, .unsupportedCapability:
                return .failed(error.description)
            default:
                break
            }
        } catch {
            // No reply yet; the guest is still working.
        }
        while Date() < deadline {
            if Task.isCancelled { return .failed(VPhoneLocalization.text("The guest gave no reason.")) }
            if let status = try? await control.bootstrapStatus() {
                updateBootstrapProgress(status, label: label, indicator: indicator)
                switch VPhoneBootstrapPackagesStatus.outcome(for: status) {
                case let .completed(packages): return .installed(packages)
                case let .skipped(note): return .skipped(note)
                case let .failed(reason):
                    return .failed(reason.isEmpty
                        ? VPhoneLocalization.text("The guest gave no reason.")
                        : reason)
                case .running, nil: break
                }
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                // Cancelled: stop rather than spin through the deadline.
                return .failed(VPhoneLocalization.text("The guest gave no reason."))
            }
        }
        return .failed(VPhoneLocalization.text("The packages did not finish in time."))
    }
}
