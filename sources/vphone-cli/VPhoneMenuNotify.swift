import AppKit

// MARK: - Notify Menu

private enum NotifyEntry {
    case section(String)
    case notification(name: String, label: String)
}

private let knownNotifications: [NotifyEntry] = [
    .section("SpringBoard"),
    .notification(name: "com.apple.springboard.lockstate", label: "Lock State"),
    .notification(name: "com.apple.springboard.lockcomplete", label: "Lock Complete"),
    .notification(name: "com.apple.springboard.hasBlankedScreen", label: "Screen Blanked"),
    .notification(name: "com.apple.springboard.pluggedin", label: "Plugged In"),
    .notification(name: "com.apple.springboard.finishedstartup", label: "SpringBoard Finished Startup"),
    .notification(name: "com.apple.springboard.screenshotService", label: "Screenshot Service"),
    .notification(name: "com.apple.springboard.attemptactivation", label: "Attempt Activation"),

    .section("Display & Backlight"),
    .notification(name: "com.apple.iokit.hid.displayStatus", label: "Display Status"),
    .notification(name: "com.apple.backboardd.backlight.changed", label: "Backlight Changed"),

    .section("Power & Battery"),
    .notification(name: "com.apple.system.lowpowermode", label: "Low Power Mode"),
    .notification(name: "com.apple.system.thermalpressurelevel", label: "Thermal Pressure Level"),

    .section("Network & Telephony"),
    .notification(name: "com.apple.system.config.network_change", label: "Network Change"),
    .notification(name: "com.apple.MobileSignal.CTRegistrationDataStatusChanged", label: "Cellular Registration Changed"),

    .section("Locale & Time"),
    .notification(name: "com.apple.language.changed", label: "Language Changed"),
    .notification(name: "com.apple.system.timezone", label: "Timezone Changed"),
    .notification(name: "com.apple.system.clock_set", label: "Clock Set"),

    .section("Location"),
    .notification(name: "com.apple.locationd.authorization.changed", label: "Location Authorization Changed"),

    .section("Keyboard & UI"),
    .notification(name: "com.apple.UIKit.keyboard.visibility.changed", label: "Keyboard Visibility Changed"),
    .notification(name: "com.apple.accessibility.cache.ax.app.notification", label: "Accessibility App Notification"),

    .section("Keybag & Security"),
    .notification(name: "com.apple.mobile.keybagd.lock_status", label: "Keybag Lock Status"),
    .notification(name: "com.apple.mobile.keybagd.first_unlock", label: "Keybag First Unlock"),

    .section("App Lifecycle"),
    .notification(name: "com.apple.frontboard.systemapp.didlaunch", label: "System App Did Launch"),
    .notification(name: "com.apple.mobile.application_installed", label: "App Installed"),
    .notification(name: "com.apple.mobile.application_uninstalled", label: "App Uninstalled"),

    .section("Lockdown & Device State"),
    .notification(name: "com.apple.mobile.lockdown.phone_number_changed", label: "Phone Number Changed"),
    .notification(name: "com.apple.mobile.lockdown.device_name_changed", label: "Device Name Changed"),
    .notification(name: "com.apple.mobile.lockdown.timezone_changed", label: "Lockdown Timezone Changed"),
    .notification(name: "com.apple.mobile.lockdown.trusted_host_attached", label: "Trusted Host Attached"),
    .notification(name: "com.apple.mobile.lockdown.host_attached", label: "Host Attached"),
    .notification(name: "com.apple.mobile.lockdown.host_detached", label: "Host Detached"),
    .notification(name: "com.apple.mobile.lockdown.activation_state", label: "Activation State"),
    .notification(name: "com.apple.mobile.lockdown.disk_usage_changed", label: "Disk Usage Changed"),
    .notification(name: "com.apple.mobile.developer_image_mounted", label: "Developer Image Mounted"),

    .section("Sync"),
    .notification(name: "com.apple.itunes-mobdev.syncWillStart", label: "Sync Will Start"),
    .notification(name: "com.apple.itunes-mobdev.syncDidStart", label: "Sync Did Start"),
    .notification(name: "com.apple.itunes-mobdev.syncDidFinish", label: "Sync Did Finish"),
    .notification(name: "com.apple.mobile.data_sync.domain_changed", label: "Data Sync Domain Changed"),
    .notification(name: "com.apple.mobile.backup.domain_changed", label: "Backup Domain Changed"),

    .section("Backup & Restore"),
    .notification(name: "com.apple.MobileSync.BackupAgent.RestoreStarted", label: "Restore Started"),

    .section("Filesystem"),
    .notification(name: "com.apple.system.lowdiskspace", label: "Low Disk Space"),
    .notification(name: "com.apple.system.lowdiskspace.system", label: "Low Disk Space (System)"),
    .notification(name: "com.apple.system.lowdiskspace.user", label: "Low Disk Space (User)"),
    .notification(name: "com.apple.system.kernel.mount", label: "VFS Mount"),
    .notification(name: "com.apple.system.kernel.unmount", label: "VFS Unmount"),
    .notification(name: "com.apple.system.kernel.mountupdate", label: "VFS Mount Update"),

    .section("Other"),
    .notification(name: "com.apple.system.hostname", label: "Hostname Changed"),
    .notification(name: "com.apple.system.logger.message", label: "ASL Logger Message"),
    .notification(name: "com.apple.AddressBook.PreferenceChanged", label: "Address Book Preference Changed"),
    .notification(name: "com.apple.itdbprep.notification.didEnd", label: "iTunes DB Prep Did End"),
]

extension VPhoneMenuController {
    func updateNotifyAvailability(available: Bool) {
        notifyPostItem?.isEnabled = available
    }

    @objc func postNotification() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Send Darwin Notification"
        panel.center()

        // Preset popup
        let presetLbl = NSTextField(labelWithString: "Preset:")
        presetLbl.frame = NSRect(x: 20, y: 202, width: 60, height: 18)

        let popup = NSPopUpButton(frame: NSRect(x: 80, y: 198, width: 380, height: 26), pullsDown: false)
        popup.menu?.autoenablesItems = false
        popup.addItem(withTitle: "Custom")
        for entry in knownNotifications {
            switch entry {
            case let .section(title):
                popup.menu?.addItem(NSMenuItem.separator())
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 11)]
                )
                popup.menu?.addItem(header)
            case let .notification(name, label):
                popup.addItem(withTitle: "\(label)  (\(name))")
            }
        }

        // Name field
        let nameLbl = NSTextField(labelWithString: "Notification name:")
        nameLbl.frame = NSRect(x: 20, y: 172, width: 440, height: 18)

        let nameField = NSTextField(frame: NSRect(x: 20, y: 146, width: 440, height: 22))
        nameField.placeholderString = "com.apple.example.notification"

        // Wire preset selection to populate name field
        let popupHandler = NotifyPopupHandler(nameField: nameField)
        popup.target = popupHandler
        popup.action = #selector(NotifyPopupHandler.presetSelected(_:))

        // Include state checkbox
        let stateCheck = NSButton(checkboxWithTitle: "Include state payload (UInt64)", target: nil, action: nil)
        stateCheck.frame = NSRect(x: 20, y: 116, width: 300, height: 20)
        stateCheck.state = .off

        // State field
        let stateField = NSTextField(frame: NSRect(x: 20, y: 88, width: 440, height: 22))
        stateField.placeholderString = "0"
        stateField.isEnabled = false

        // Wire checkbox to toggle state field
        let checkHandler = NotifyCheckHandler(stateField: stateField)
        stateCheck.target = checkHandler
        stateCheck.action = #selector(NotifyCheckHandler.toggled(_:))

        // Status label (inline feedback instead of separate alert)
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 48, width: 340, height: 18)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        // Buttons
        let postHandler = NotifyPostHandler(
            control: control, nameField: nameField,
            stateCheck: stateCheck, stateField: stateField,
            statusLabel: statusLabel
        )

        let ok = NSButton(frame: NSRect(x: 370, y: 12, width: 90, height: 28))
        ok.title = "Post"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = postHandler
        ok.action = #selector(NotifyPostHandler.post(_:))

        let close = NSButton(frame: NSRect(x: 270, y: 12, width: 90, height: 28))
        close.title = "Close"
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.target = NSApp
        close.action = #selector(NSApplication.stopModal as (NSApplication) -> () -> Void)

        // Stop the modal session when the close button (red X) is clicked
        let closeDelegate = ModalCloseDelegate()
        panel.delegate = closeDelegate

        panel.contentView?.addSubview(presetLbl)
        panel.contentView?.addSubview(popup)
        panel.contentView?.addSubview(nameLbl)
        panel.contentView?.addSubview(nameField)
        panel.contentView?.addSubview(stateCheck)
        panel.contentView?.addSubview(stateField)
        panel.contentView?.addSubview(statusLabel)
        panel.contentView?.addSubview(ok)
        panel.contentView?.addSubview(close)

        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        _ = popupHandler
        _ = checkHandler
        _ = postHandler
        _ = closeDelegate
    }
}

// MARK: - Action Handlers

@MainActor
private final class NotifyPopupHandler: NSObject {
    let nameField: NSTextField

    init(nameField: NSTextField) {
        self.nameField = nameField
    }

    @objc func presetSelected(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title else { return }
        // Find the notification whose formatted title matches
        for entry in knownNotifications {
            if case let .notification(name, label) = entry,
               title == "\(label)  (\(name))" {
                nameField.stringValue = name
                return
            }
        }
    }
}

@MainActor
private final class NotifyCheckHandler: NSObject {
    let stateField: NSTextField

    init(stateField: NSTextField) {
        self.stateField = stateField
    }

    @objc func toggled(_ sender: NSButton) {
        let isOn = sender.state == .on
        stateField.isEnabled = isOn
        if isOn {
            stateField.window?.makeFirstResponder(stateField)
        }
    }
}

@MainActor
private final class NotifyPostHandler: NSObject {
    let control: VPhoneControl
    let nameField: NSTextField
    let stateCheck: NSButton
    let stateField: NSTextField
    let statusLabel: NSTextField

    init(
        control: VPhoneControl, nameField: NSTextField,
        stateCheck: NSButton, stateField: NSTextField,
        statusLabel: NSTextField
    ) {
        self.control = control
        self.nameField = nameField
        self.stateCheck = stateCheck
        self.stateField = stateField
        self.statusLabel = statusLabel
    }

    @objc func post(_ sender: NSButton) {
        let name = nameField.stringValue
        guard !name.isEmpty else {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Enter a notification name."
            return
        }

        var state: UInt64?
        if stateCheck.state == .on {
            guard let parsed = UInt64(stateField.stringValue) else {
                statusLabel.textColor = .systemOrange
                statusLabel.stringValue = "Invalid UInt64 value."
                return
            }
            state = parsed
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Posting..."
        sender.isEnabled = false

        Task {
            do {
                try await control.notifyPost(name: name, state: state)
                let detail = state.map { " (state: \($0))" } ?? ""
                statusLabel.textColor = .systemGreen
                statusLabel.stringValue = "Posted: \(name)\(detail)"
            } catch {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "\(error)"
            }
            sender.isEnabled = true
        }
    }
}

private final class ModalCloseDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
