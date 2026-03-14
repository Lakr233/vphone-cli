import AppKit

// MARK: - Connect Menu

extension VPhoneMenuController {
    func buildConnectMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Connect")
        menu.autoenablesItems = false

        let fileBrowser = makeItem("File Browser", action: #selector(openFiles))
        fileBrowser.isEnabled = false
        connectFileBrowserItem = fileBrowser
        menu.addItem(fileBrowser)

        let keychainBrowser = makeItem("Keychain Browser", action: #selector(openKeychain))
        keychainBrowser.isEnabled = false
        connectKeychainBrowserItem = keychainBrowser
        menu.addItem(keychainBrowser)

        menu.addItem(NSMenuItem.separator())

        let devModeStatus = makeItem("Developer Mode Status", action: #selector(devModeStatus))
        devModeStatus.isEnabled = false
        connectDevModeStatusItem = devModeStatus
        menu.addItem(devModeStatus)

        menu.addItem(NSMenuItem.separator())

        let ping = makeItem("Ping", action: #selector(sendPing))
        ping.isEnabled = false
        connectPingItem = ping
        menu.addItem(ping)

        let guestVersion = makeItem("Guest Version", action: #selector(queryGuestVersion))
        guestVersion.isEnabled = false
        connectGuestVersionItem = guestVersion
        menu.addItem(guestVersion)

        menu.addItem(NSMenuItem.separator())

        let clipGet = makeItem("Get Clipboard", action: #selector(getClipboard))
        clipGet.isEnabled = false
        clipboardGetItem = clipGet
        menu.addItem(clipGet)

        let clipSet = makeItem("Set Clipboard Text...", action: #selector(setClipboardText))
        clipSet.isEnabled = false
        clipboardSetItem = clipSet
        menu.addItem(clipSet)

        menu.addItem(NSMenuItem.separator())

        let settingsGet = makeItem("Read Setting...", action: #selector(readSetting))
        settingsGet.isEnabled = false
        settingsGetItem = settingsGet
        menu.addItem(settingsGet)

        let settingsSet = makeItem("Write Setting...", action: #selector(writeSetting))
        settingsSet.isEnabled = false
        settingsSetItem = settingsSet
        menu.addItem(settingsSet)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(buildLocationSubmenu())
        menu.addItem(buildBatterySubmenu())

        item.submenu = menu
        return item
    }

    func updateSettingsAvailability(available: Bool) {
        settingsGetItem?.isEnabled = available
        settingsSetItem?.isEnabled = available
    }

    func updateConnectAvailability(available: Bool) {
        connectFileBrowserItem?.isEnabled = available
        connectKeychainBrowserItem?.isEnabled = available
        connectDevModeStatusItem?.isEnabled = available
        connectPingItem?.isEnabled = available
        connectGuestVersionItem?.isEnabled = available
    }

    @objc func openFiles() {
        onFilesPressed?()
    }

    @objc func openKeychain() {
        onKeychainPressed?()
    }

    @objc func devModeStatus() {
        Task {
            do {
                let status = try await control.sendDevModeStatus()
                showAlert(
                    title: "Developer Mode",
                    message: status.enabled ? "Developer Mode is enabled." : "Developer Mode is disabled.",
                    style: .informational
                )
            } catch {
                showAlert(title: "Developer Mode", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func sendPing() {
        Task {
            do {
                try await control.sendPing()
                showAlert(title: "Ping", message: "pong", style: .informational)
            } catch {
                showAlert(title: "Ping", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func queryGuestVersion() {
        Task {
            do {
                let hash = try await control.sendVersion()
                showAlert(title: "Guest Version", message: "build: \(hash)", style: .informational)
            } catch {
                showAlert(title: "Guest Version", message: "\(error)", style: .warning)
            }
        }
    }

    func updateClipboardAvailability(available: Bool) {
        clipboardGetItem?.isEnabled = available
        clipboardSetItem?.isEnabled = available
    }

    // MARK: - Clipboard

    @objc func getClipboard() {
        Task {
            do {
                let content = try await control.clipboardGet()
                var message = ""
                if let text = content.text {
                    let truncated = text.count > 500 ? String(text.prefix(500)) + "..." : text
                    message += "Text: \(truncated)\n"
                }
                message += "Types: \(content.types.joined(separator: ", "))\n"
                message += "Has Image: \(content.hasImage)\n"
                message += "Change Count: \(content.changeCount)"
                showAlert(title: "Clipboard Content", message: message, style: .informational)
            } catch {
                showAlert(title: "Clipboard", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func setClipboardText() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Clipboard Text"
        panel.center()

        let lbl = NSTextField(labelWithString: "Enter text to set on the guest clipboard:")
        lbl.frame = NSRect(x: 20, y: 110, width: 380, height: 20)

        let field = NSTextField(frame: NSRect(x: 20, y: 50, width: 380, height: 50))
        field.placeholderString = "Text to copy to clipboard"

        let ok = NSButton(frame: NSRect(x: 310, y: 12, width: 90, height: 28))
        ok.title = "Set"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = self
        ok.action = #selector(VPhoneMenuController.confirmModal)

        let cancel = NSButton(frame: NSRect(x: 210, y: 12, width: 90, height: 28))
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
        let text = field.stringValue

        Task {
            do {
                try await control.clipboardSet(text: text)
                showAlert(title: "Clipboard", message: "Text set successfully.", style: .informational)
            } catch {
                showAlert(title: "Clipboard", message: "\(error)", style: .warning)
            }
        }
    }

    // MARK: - Settings

    @objc func readSetting() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Read Setting"
        panel.center()

        let lbl1 = NSTextField(labelWithString: "Domain:")
        lbl1.frame = NSRect(x: 20, y: 118, width: 380, height: 18)
        let domainField = NSTextField(frame: NSRect(x: 20, y: 92, width: 380, height: 22))
        domainField.placeholderString = "com.apple.springboard"

        let lbl2 = NSTextField(labelWithString: "Key (leave empty for all keys):")
        lbl2.frame = NSRect(x: 20, y: 68, width: 380, height: 18)
        let keyField = NSTextField(frame: NSRect(x: 20, y: 42, width: 380, height: 22))
        keyField.placeholderString = "Key (leave empty for all keys)"

        let ok = NSButton(frame: NSRect(x: 310, y: 10, width: 90, height: 28))
        ok.title = "Read"
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

        panel.contentView?.addSubview(lbl1)
        panel.contentView?.addSubview(domainField)
        panel.contentView?.addSubview(lbl2)
        panel.contentView?.addSubview(keyField)
        panel.contentView?.addSubview(ok)
        panel.contentView?.addSubview(cancel)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .OK else { return }
        let domain = domainField.stringValue
        guard !domain.isEmpty else { return }
        let key: String? = keyField.stringValue.isEmpty ? nil : keyField.stringValue

        Task {
            do {
                let value = try await control.settingsGet(domain: domain, key: key)
                let display: String
                if let dict = value as? [String: Any] {
                    let data = try JSONSerialization.data(
                        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
                    )
                    display = String(data: data, encoding: .utf8) ?? "\(dict)"
                } else {
                    display = "\(value ?? "nil")"
                }
                let truncated = display.count > 2000 ? String(display.prefix(2000)) + "\n..." : display
                showAlert(
                    title: "Setting: \(domain)\(key.map { ".\($0)" } ?? "")",
                    message: truncated,
                    style: .informational
                )
            } catch {
                showAlert(title: "Read Setting", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func writeSetting() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Write Setting"
        panel.center()

        let lbl1 = NSTextField(labelWithString: "Domain:")
        lbl1.frame = NSRect(x: 20, y: 198, width: 380, height: 18)
        let domainField = NSTextField(frame: NSRect(x: 20, y: 172, width: 380, height: 22))
        domainField.placeholderString = "com.apple.springboard"

        let lbl2 = NSTextField(labelWithString: "Key:")
        lbl2.frame = NSRect(x: 20, y: 148, width: 380, height: 18)
        let keyField = NSTextField(frame: NSRect(x: 20, y: 122, width: 380, height: 22))
        keyField.placeholderString = "Key"

        let lbl3 = NSTextField(labelWithString: "Type:")
        lbl3.frame = NSRect(x: 20, y: 98, width: 380, height: 18)
        let typeField = NSTextField(frame: NSRect(x: 20, y: 72, width: 380, height: 22))
        typeField.placeholderString = "Type: boolean | string | integer | float"

        let lbl4 = NSTextField(labelWithString: "Value:")
        lbl4.frame = NSRect(x: 20, y: 48, width: 380, height: 18)
        let valueField = NSTextField(frame: NSRect(x: 20, y: 42, width: 220, height: 22))
        valueField.placeholderString = "Value"

        let ok = NSButton(frame: NSRect(x: 310, y: 10, width: 90, height: 28))
        ok.title = "Write"
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

        panel.contentView?.addSubview(lbl1)
        panel.contentView?.addSubview(domainField)
        panel.contentView?.addSubview(lbl2)
        panel.contentView?.addSubview(keyField)
        panel.contentView?.addSubview(lbl3)
        panel.contentView?.addSubview(typeField)
        panel.contentView?.addSubview(lbl4)
        panel.contentView?.addSubview(valueField)
        panel.contentView?.addSubview(ok)
        panel.contentView?.addSubview(cancel)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .OK else { return }
        let domain = domainField.stringValue
        let key = keyField.stringValue
        let type = typeField.stringValue
        let rawValue = valueField.stringValue
        guard !domain.isEmpty, !key.isEmpty else { return }

        let value: Any =
            switch type.lowercased() {
            case "boolean", "bool":
                rawValue.lowercased() == "true" || rawValue == "1"
            case "integer", "int":
                Int(rawValue) ?? 0
            case "float", "double":
                Double(rawValue) ?? 0.0
            default:
                rawValue
            }

        Task {
            do {
                try await control.settingsSet(
                    domain: domain, key: key, value: value, type: type.isEmpty ? nil : type
                )
                showAlert(
                    title: "Write Setting", message: "Set \(domain).\(key) = \(rawValue)",
                    style: .informational
                )
            } catch {
                showAlert(title: "Write Setting", message: "\(error)", style: .warning)
            }
        }
    }

    // MARK: - Alert

    func showAlert(title: String, message: String, style: NSAlert.Style) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.center()

        let msg = NSTextField(labelWithString: message)
        msg.frame = NSRect(x: 20, y: 50, width: 340, height: 50)
        msg.lineBreakMode = .byWordWrapping
        msg.maximumNumberOfLines = 3

        let ok = NSButton(frame: NSRect(x: 280, y: 12, width: 80, height: 28))
        ok.title = "OK"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = NSApp
        ok.action = #selector(NSApplication.stopModal(withCode:))

        panel.contentView?.addSubview(msg)
        panel.contentView?.addSubview(ok)

        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }
}
