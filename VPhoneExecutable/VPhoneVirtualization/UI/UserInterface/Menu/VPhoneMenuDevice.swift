import AppKit
import LocalAuthentication
import VPhoneCoreKit

// MARK: - Device Menu

/// The phone's buttons and input, and restarting it. Sensor overrides live
/// in the Features menu.
extension VPhoneMenuController {
    func buildDeviceMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Device")
        menu.autoenablesItems = false
        menu.addItem(makePanelItem(.controls, "Controls", keyEquivalent: "k", symbol: "slider.horizontal.3"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(
            "Home Screen",
            action: #selector(sendHome),
            keyEquivalent: "h",
            modifiers: [.command, .shift],
            symbol: "house",
        ))
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
        let restart = makeItem("Restart Guest…", action: #selector(restartGuest), symbol: "arrow.clockwise")
        restart.isEnabled = false
        restartGuestItem = restart
        menu.addItem(restart)
        item.submenu = menu
        return item
    }

    @objc func sendHome() {
        keySender.sendHome()
    }

    /// iOS has no back key. Esc and this item both replay the system back
    /// gesture instead of forwarding a keystroke the guest would only read as
    /// "cancel" (or, in Safari, "stop loading").
    @objc func sendBack() {
        captureView?.performBackGesture()
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
