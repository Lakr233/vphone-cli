import AppKit
import LocalAuthentication
import VPhoneCoreKit

// MARK: - Device Menu

/// The phone's buttons and input, the UDID it gives provisioning profile
/// checks, and restarting it. Sensor overrides live
/// in the Features menu.
extension VPhoneMenuController {
    func buildDeviceMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        menu.addItem(makePanelItem(.controls, "Controls", keyEquivalent: "k", symbol: "slider.horizontal.3"))
        let remote = makeItem(
            "Apple TV Remote", action: #selector(showTVRemote),
            keyEquivalent: "r", modifiers: [.command, .option], symbol: "appletvremote.gen2",
        )
        remote.isHidden = true
        tvRemoteItem = remote
        menu.addItem(remote)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(
            "Home Screen",
            action: #selector(sendHome),
            keyEquivalent: "h",
            modifiers: [.command, .shift],
            symbol: "house",
        ))
        // Shown only for an Apple TV guest; see `showsTVControls`.
        let controlCenter = makeItem(
            "Control Center",
            action: #selector(sendTVControlCenter),
            keyEquivalent: "t",
            modifiers: [.command, .shift],
            symbol: "switch.2",
        )
        controlCenter.isHidden = true
        tvControlCenterItem = controlCenter
        menu.addItem(controlCenter)
        // iOS has no back key, so this item and the Esc key both replay the
        // system back gesture. The key equivalent is here so the menu can show
        // it; VPhoneApplication intercepts Esc before the menu is consulted,
        // because AppKit's matching for a bare Esc missed presses.
        menu.addItem(makeItem(
            "Back",
            action: #selector(sendBack),
            keyEquivalent: "\u{1b}",
            modifiers: [],
            symbol: "arrow.uturn.backward",
        ))
        // Shown only for an Apple Watch guest; see `showsWatchControls`.
        let sideButton = makeItem("Side Button", action: #selector(sendWatchSideButton), symbol: "button.vertical.right.press")
        sideButton.isHidden = true
        watchSideButtonItem = sideButton
        menu.addItem(sideButton)
        menu.addItem(makeItem("Power", action: #selector(sendPower), symbol: "power"))
        menu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp), symbol: "speaker.plus"))
        menu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown), symbol: "speaker.minus"))
        menu.addItem(NSMenuItem.separator())
        let rotateLeft = makeItem(
            "Rotate Left",
            action: #selector(rotateLeft),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            symbol: "rotate.left",
        )
        let rotateRight = makeItem(
            "Rotate Right",
            action: #selector(rotateRight),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            symbol: "rotate.right",
        )
        let orientationItem = NSMenuItem(title: "Orientation", action: nil, keyEquivalent: "")
        orientationItem.image = menuSymbol("rectangle.portrait.rotate")
        orientationItem.submenu = buildOrientationMenu()
        // Disabled until the agent connects, so ⌘← and ⌘→ reach the guest.
        for rotate in [rotateLeft, rotateRight, orientationItem] {
            rotate.isEnabled = false
            menu.addItem(rotate)
        }
        rotateMenuItems = [rotateLeft, rotateRight, orientationItem]
        control.observeInterfaceOrientation { [weak self] orientation in
            self?.updateOrientationChecks(orientation)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Open Guest Spotlight", action: #selector(sendSpotlight), symbol: "magnifyingglass"))
        menu.addItem(makeItem("Switch Guest Input Source", action: #selector(sendGlobe), symbol: "globe"))
        let keyboardItem = makeItem(
            "Use Hardware Keyboard",
            action: #selector(toggleHardwareKeyboard),
            keyEquivalent: "k",
            modifiers: [.command, .shift],
            symbol: "keyboard",
        )
        keyboardItem.isEnabled = false
        keyboardItem.toolTip = VPhoneLocalization.text("Changing the hardware keyboard requires restarting the virtual machine.")
        hardwareKeyboardItem = keyboardItem
        menu.addItem(keyboardItem)
        // Simulator's I/O > Keyboard item, without its Command-K: a plain
        // Command-letter is the guest's (Command-K is Add Link in Notes). It
        // flips the guest's keyboard mode in place, so it needs no restart.
        let softwareKeyboard = makeItem(
            "Toggle Software Keyboard",
            action: #selector(toggleSoftwareKeyboard),
            symbol: "keyboard.chevron.compact.down",
        )
        softwareKeyboard.isEnabled = false
        softwareKeyboard.toolTip = VPhoneLocalization.text(
            "Shows or hides the guest's software keyboard while the hardware keyboard stays attached. Restarting SpringBoard returns to the hardware keyboard.",
        )
        softwareKeyboardItem = softwareKeyboard
        menu.addItem(softwareKeyboard)
        // Trackpad scroll and pinch arrive as ordinary NSEvents; the view turns
        // them into guest touches. Off hands both back to AppKit untouched.
        let trackpadItem = makeItem(
            "Trackpad Scroll & Pinch to Touch",
            action: #selector(toggleTrackpadGestures),
            symbol: "hand.draw",
        )
        trackpadItem.state = VPhoneTrackpadGestures.isEnabled ? .on : .off
        trackpadGesturesItem = trackpadItem
        menu.addItem(trackpadItem)
        let captureItem = makeItem("Capture Mouse", action: #selector(toggleMouseCapture), symbol: "computermouse")
        captureItem.toolTip = "Forward mouse movement and buttons to the guest. Control–Option–M releases capture."
        captureItem.state = .off
        mouseCaptureItem = captureItem
        menu.addItem(captureItem)
        menu.addItem(makeItem("Release Mouse", action: #selector(releaseMouseCapture),
            keyEquivalent: "m", modifiers: [.control, .option]))
        let externalItem = NSMenuItem(title: "External Display", action: nil, keyEquivalent: "")
        let externalMenu = NSMenu(title: "External Display")
        externalMenu.autoenablesItems = false
        externalMenu.addItem(makeItem("Connect 1080p (1920 × 1080)", action: #selector(connectExternal1080p)))
        externalMenu.addItem(makeItem("Connect 4K (3840 × 2160)", action: #selector(connectExternal4K)))
        externalMenu.addItem(makeItem("Disconnect", action: #selector(disconnectExternalDisplay)))
        externalItem.submenu = externalMenu
        menu.addItem(externalItem)
        // Off unless asked for: the window subtitle then carries the frames the
        // guest presented in the last second.
        let frameRateItem = makeItem("Show Frame Rate", action: #selector(toggleFrameRateDisplay))
        frameRateItem.state = VPhoneFrameRateDisplay.isEnabled ? .on : .off
        frameRateItem.isEnabled = VPhoneFrameRateMeter.isSupported
        menu.addItem(frameRateItem)
        let tidItem = makeItem("Touch ID Home Forwarding", action: #selector(toggleTouchIDForwarding))
        if hasTouchID {
            let tidEnabled = !UserDefaults.standard.bool(forKey: "touchIDForwardingDisabled")
            tidItem.state = tidEnabled ? .on : .off
        } else {
            tidItem.isEnabled = false
            tidItem.state = .off
        }
        touchIDMenuItem = tidItem
        menu.addItem(tidItem)
        menu.addItem(NSMenuItem.separator())
        addUDIDItems(to: menu)
        menu.addItem(NSMenuItem.separator())
        addSetupAssistantItem(to: menu)
        // Saved to this machine and read when vphoned next starts in the guest.
        let unlockItem = makeItem("Unlock at Startup", action: #selector(toggleUnlockAtStartup), symbol: "lock.open")
        unlockItem.state = control.unlocksAtStartup ? .on : .off
        unlockItem.toolTip = VPhoneLocalization.text(
            "Wake the guest and dismiss its Lock Screen each time it starts.",
        )
        unlockAtStartupItem = unlockItem
        menu.addItem(unlockItem)
        let restart = makeItem("Restart Guest…", action: #selector(restartGuest), symbol: "arrow.clockwise")
        restart.isEnabled = false
        restartGuestItem = restart
        menu.addItem(restart)
        let shutDown = makeItem("Shut Down Guest…", action: #selector(shutDownGuest), symbol: "power")
        shutDown.isEnabled = false
        shutDownGuestItem = shutDown
        menu.addItem(shutDown)
        item.submenu = menu
        return item
    }

    @objc func showTVRemote() {
        guard showsTVControls else { return }
        tvRemoteWindowController.show()
    }

    @objc func sendHome() {
        keySender.sendHome()
    }

    @objc func sendTVControlCenter() {
        keySender.sendTVControlCenter()
    }

    /// iOS has no back key. Esc and this item both replay the system back
    /// gesture instead of forwarding a keystroke the guest would only read as
    /// "cancel" (or, in Safari, "stop loading").
    @objc func sendBack() {
        captureView?.performBackGesture()
    }

    @objc func sendWatchSideButton() {
        keySender.sendWatchSideButton()
    }

    @objc func sendPower() {
        keySender.sendPower()
    }

    @objc func sendVolumeUp() {
        keySender.sendVolumeUp()
    }

    @objc func sendVolumeDown() {
        keySender.sendVolumeDown()
    }

    @objc func sendSpotlight() {
        keySender.sendSpotlight()
    }

    @objc func sendGlobe() {
        keySender.sendGlobe()
    }

    @objc func toggleHardwareKeyboard() {
        guard let vm, let change = onHardwareKeyboardChange,
              hardwareKeyboardItem?.isEnabled == true else { return }
        guard screenRecorder?.isRecording != true else {
            VPhoneAlert.present(
                title: "Recording in Progress",
                message: "Stop the screen recording before changing the hardware keyboard.",
                style: .warning,
            )
            return
        }
        let enabled = !vm.usesHardwareKeyboard
        hardwareKeyboardItem?.isEnabled = false
        VPhoneAlert.present(
            title: enabled ? "Enable Hardware Keyboard?" : "Disable Hardware Keyboard?",
            message: "Changing the hardware keyboard requires restarting the virtual machine. Save your work in the guest first. The setting is saved for this machine. With the hardware keyboard disabled, tap a text field to use the guest's software keyboard.",
            style: .warning,
            buttons: ["Restart and Apply", "Cancel"],
        ) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                hardwareKeyboardItem?.isEnabled = true
                return
            }
            Task { [weak self] in
                do {
                    try await change(enabled)
                } catch {
                    self?.hardwareKeyboardItem?.isEnabled = true
                    VPhoneAlert.present(
                        title: "Unable to Change Hardware Keyboard",
                        message: error.localizedDescription,
                        style: .warning,
                    )
                }
            }
        }
    }

    // MARK: - Software Keyboard

    /// Without a virtual USB keyboard the guest already uses its software
    /// keyboard, so the item only applies while one is attached. Only iPhone and
    /// iPad guests were measured: tvOS draws its own on-screen keyboard, and a
    /// watch or HomePod guest was not tried, so those never get it.
    func updateSoftwareKeyboardAvailability(available: Bool) {
        let measured = !showsTVControls && !showsWatchControls && !control.isHomePodGuest
        softwareKeyboardItem?.isEnabled = available && measured && vm?.usesHardwareKeyboard == true
    }

    /// GraphicsServices keeps the guest's hardware keyboard in the state of the
    /// `GSEventHardwareKeyboardAttached` Darwin notification: bit 0 attached,
    /// bits 8–15 the country code, bits 16 and up the keyboard type. Posting it
    /// with bit 0 flipped is what the guest does when a keyboard comes or goes,
    /// so the guest switches to or from its software keyboard while the USB
    /// keyboard stays attached. SpringBoard sets bit 0 again when it restarts.
    @objc func toggleSoftwareKeyboard() {
        guard softwareKeyboardItem?.isEnabled == true else { return }
        let name = "GSEventHardwareKeyboardAttached"
        Task {
            do {
                let reply = try await control.call("notify.state", params: ["name": name])
                guard let state = (reply["state"] as? NSNumber)?.uint64Value else {
                    throw VPhoneGuestControl.ControlError.protocolError("notify.state returned no state for \(name)")
                }
                let toggled = state ^ 1
                // A decimal string keeps all 64 bits, which a JSON double does not.
                _ = try await control.call("notify.post", params: ["name": name, "state": String(toggled)])
                print("[keyboard] Software keyboard \(toggled & 1 == 0 ? "shown" : "hidden"), state 0x\(String(toggled, radix: 16))")
            } catch {
                print("[keyboard] Software keyboard toggle failed: \(error)")
                VPhoneAlert.present(
                    title: "Unable to Toggle Software Keyboard",
                    message: "Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }

    // MARK: - Rotate

    /// The four interface orientations, checked by the one the window last
    /// read from the guest.
    private func buildOrientationMenu() -> NSMenu {
        let menu = NSMenu(title: "Orientation")
        let orientations: [(VPhoneDisplayOrientation, String)] = [
            (.portrait, "Portrait"),
            (.landscapeLeft, "Landscape Left"),
            (.landscapeRight, "Landscape Right"),
            (.upsideDown, "Upside Down"),
        ]
        for (orientation, title) in orientations {
            let item = makeItem(title, action: #selector(chooseOrientation(_:)))
            item.representedObject = orientation.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func updateOrientationChecks(_ orientation: VPhoneDisplayOrientation?) {
        guard let menu = rotateMenuItems.last?.submenu else { return }
        for item in menu.items {
            item.state = (item.representedObject as? Int) == orientation?.rawValue ? .on : .off
        }
    }

    @objc func chooseOrientation(_ sender: NSMenuItem) {
        guard let degrees = sender.representedObject as? Int,
              let orientation = VPhoneDisplayOrientation(degrees: degrees)
        else { return }
        Task {
            do {
                try await control.rotate(toFirstOf: [orientation])
            } catch {
                VPhoneAlert.present(
                    title: "Unable to Rotate",
                    message: "The app in front does not support this orientation.",
                    style: .warning,
                )
            }
        }
    }

    @objc func rotateLeft() {
        rotate(clockwise: false)
    }

    @objc func rotateRight() {
        rotate(clockwise: true)
    }

    /// Turns the guest a quarter turn from its interface orientation, the
    /// one already turning to when pressed again. An orientation the app in
    /// front refuses, such as upside down on the Home Screen, is skipped for
    /// the one after it. The window turns with the guest.
    private func rotate(clockwise: Bool) {
        Task {
            var current = control.interfaceOrientation
            if current == nil {
                let method = control.guestCapabilities.contains("display_orientation")
                    ? "display.orientation" : "display.rotation"
                let degrees = try? await (control.call(method)["degrees"] as? NSNumber)?.intValue
                current = degrees.flatMap(VPhoneDisplayOrientation.init(degrees:))
            }
            guard let current else { return }
            let next = current.turned(clockwise: clockwise)
            try? await control.rotate(toFirstOf: [next, next.turned(clockwise: clockwise)])
        }
    }

    /// Replays trackpad scroll and pinch inside the guest instead of letting
    /// AppKit scroll the window. Persisted, so the choice survives relaunches.
    @objc func toggleTrackpadGestures() {
        let enabled = !VPhoneTrackpadGestures.isEnabled
        VPhoneTrackpadGestures.isEnabled = enabled
        trackpadGesturesItem?.state = enabled ? .on : .off
        captureView?.trackpadGesturesEnabled = enabled
    }

    @objc func toggleMouseCapture() {
        guard let captureView else { return }
        captureView.setMouseCaptured(!captureView.isMouseCaptured)
    }

    @objc func releaseMouseCapture() {
        captureView?.setMouseCaptured(false)
    }

    @objc func connectExternal1080p() { connectExternalDisplay(width: 1920, height: 1080) }
    @objc func connectExternal4K() { connectExternalDisplay(width: 3840, height: 2160) }
    private func connectExternalDisplay(width: Int, height: Int) {
        guard !externalDisplayWindow.isConfiguring else { return }
        Task {
            do { try await externalDisplayWindow.connect(width: width, height: height) }
            catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Connect External Display"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
    @objc func disconnectExternalDisplay() {
        if externalDisplayWindow.window?.isVisible == true { externalDisplayWindow.close() }
        else { externalDisplayWindow.disconnect() }
    }

    /// Saved to this machine's config.plist; it takes effect from the next
    /// guest start and does not unlock the guest now.
    @objc func toggleUnlockAtStartup() {
        let enabled = !control.unlocksAtStartup
        do {
            try onUnlockAtStartupChange?(enabled)
            control.unlocksAtStartup = enabled
            unlockAtStartupItem?.state = enabled ? .on : .off
        } catch {
            VPhoneAlert.present(
                title: "Unable to Change Unlock at Startup",
                message: error.localizedDescription,
                style: .warning,
            )
        }
    }

    /// Shows the guest's frame rate in the window subtitle. Persisted.
    @objc func toggleFrameRateDisplay(_ sender: NSMenuItem) {
        let enabled = !VPhoneFrameRateDisplay.isEnabled
        VPhoneFrameRateDisplay.isEnabled = enabled
        sender.state = enabled ? .on : .off
        onFrameRateDisplayChange?(enabled)
    }

    // MARK: - Restart

    func updateRestartAvailability(available: Bool) {
        restartGuestItem?.isEnabled = available
    }

    @objc func restartGuest() {
        VPhoneAlert.present(
            title: "Restart the guest?",
            message: "Apps in the guest quit. The guest agent reconnects after the guest starts up.",
            style: .warning,
            buttons: ["Restart Guest", "Cancel"],
        ) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await self.control.restartGuest()
                } catch let VPhoneGuestControl.ControlError.guestError(message) {
                    print("[restart] guest refused: \(message)")
                    VPhoneAlert.present(
                        title: "Unable to Restart Guest",
                        message: "The guest refused the restart request.",
                        style: .warning,
                    )
                } catch {
                    // The guest restarts before it replies, so the connection
                    // drops. onDisconnect updates the menus.
                }
            }
        }
    }

    // MARK: - Shut Down

    func updateShutDownAvailability(available: Bool) {
        shutDownGuestItem?.isEnabled = available
    }

    @objc func shutDownGuest() {
        VPhoneAlert.present(
            title: "Shut down the guest?",
            message: "Apps in the guest quit and the virtual machine stops. This window closes when the guest has shut down.",
            style: .warning,
            buttons: ["Shut Down Guest", "Cancel"],
        ) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await self.control.shutDownGuest()
                } catch let VPhoneGuestControl.ControlError.guestError(message) {
                    print("[shutdown] guest refused: \(message)")
                    VPhoneAlert.present(
                        title: "Unable to Shut Down Guest",
                        message: "The guest refused the shutdown request.",
                        style: .warning,
                    )
                } catch {
                    // The guest can stop before it replies, so the connection
                    // drops. The process exits when the virtual machine stops.
                }
            }
        }
    }

    @objc func toggleTouchIDForwarding() {
        guard let monitor = touchIDMonitor, let item = touchIDMenuItem else { return }
        monitor.isEnabled.toggle()
        item.state = monitor.isEnabled ? .on : .off
        UserDefaults.standard.set(!monitor.isEnabled, forKey: "touchIDForwardingDisabled")
    }
}

private extension VPhoneMenuController {
    var hasTouchID: Bool {
        let ctx = LAContext()
        ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType == .touchID
    }
}
