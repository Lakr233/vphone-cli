import AppKit

// MARK: - UDID Menu Items

/// The UDID the guest gives provisioning profile checks, so a team's profiles
/// for a device it already registered install here. Xcode and devicectl keep
/// showing the guest's own UDID. See `VPhoneGuestControlDeviceIdentity.swift`.
extension VPhoneMenuController {
    func addUDIDItems(to menu: NSMenu) {
        let set = makeItem("Set UDID…", action: #selector(setUDID), symbol: "person.text.rectangle")
        set.isEnabled = false
        setUDIDItem = set
        menu.addItem(set)

        let reset = makeItem("Reset UDID", action: #selector(resetUDID), symbol: "arrow.counterclockwise")
        reset.isEnabled = false
        resetUDIDItem = reset
        menu.addItem(reset)
    }

    func updateUDIDAvailability(available: Bool) {
        setUDIDItem?.isEnabled = available
        resetUDIDItem?.isEnabled = available
    }

    @objc func setUDID() {
        Task {
            let current: String?
            do {
                current = try await control.profileUDID()
            } catch {
                print("[udid] read failed: \(error)")
                current = nil
            }
            promptForUDID(initial: current ?? "")
        }
    }

    @objc func resetUDID() {
        Task {
            do {
                try await control.setProfileUDID(nil)
                VPhoneAlert.present(
                    title: "Reset UDID",
                    message: "App installs now check provisioning profiles against the guest's own UDID.",
                    style: .informational,
                )
            } catch {
                print("[udid] reset failed: \(error)")
                VPhoneAlert.present(
                    title: "Unable to Reset UDID",
                    message: "Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }

    private func promptForUDID(initial: String) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = initial
        field.placeholderString = "00008150-000815E014B8401C"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.setAccessibilityLabel(VPhoneLocalization.text("UDID for provisioning profile checks"))

        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Set UDID")
        alert.informativeText = VPhoneLocalization.text(
            "App installs check provisioning profiles against this UDID. Enter the UDID of a device already registered with your team. Xcode and devicectl still show the guest's own UDID.",
        )
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "udid.alert.set", defaultValue: "Set", bundle: VPhoneLocalization.bundle))
        alert.addButton(withTitle: VPhoneLocalization.text("Cancel"))
        alert.window.initialFirstResponder = field

        VPhoneAlert.present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = field.stringValue
            guard let udid = VPhoneGuestControl.normalizedUDID(text) else {
                VPhoneAlert.present(
                    title: "Invalid UDID",
                    message: "Enter 8 and 16 hexadecimal digits joined by a hyphen, or 40 hexadecimal digits.",
                    style: .warning,
                ) { [weak self] _ in
                    self?.promptForUDID(initial: text)
                }
                return
            }
            applyUDID(udid)
        }
    }

    private func applyUDID(_ udid: String) {
        Task {
            do {
                guard let applied = try await control.setProfileUDID(udid) else {
                    throw VPhoneGuestControl.ControlError.protocolError("udid.set returned no UDID")
                }
                VPhoneAlert.present(
                    title: "Set UDID",
                    message: VPhoneLocalization.format(
                        "App installs now check provisioning profiles against %@.",
                        applied,
                    ),
                    style: .informational,
                )
            } catch {
                print("[udid] set failed: \(error)")
                VPhoneAlert.present(
                    title: "Unable to Set UDID",
                    message: "Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }
}
