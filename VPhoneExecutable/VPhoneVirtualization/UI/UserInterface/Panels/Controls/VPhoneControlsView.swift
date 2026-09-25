import SwiftUI

struct VPhoneControlsView: View {
    @Bindable var model: VPhoneControlsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                displaySection
                audioSection
                powerSection
                buttonsSection
                keyboardSection
            }
            .formStyle(.grouped)
            .disabled(!model.isConnected)

            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.isConnected,
                activity: model.activity?.title,
                status: model.status,
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .help("Read the guest's current values again (⌘R)")
                    .disabled(model.isBusy)
            }
        }
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isBusy) {
                Task { await model.refresh() }
            },
            VPhoneGuestToolShortcut(key: .return, isEnabled: model.canSendText) {
                Task { await model.typeText() }
            },
        ])
        .task { await model.run() }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            LabeledContent("Brightness") {
                HStack(spacing: 8) {
                    Slider(value: $model.brightness, in: 0 ... 1) { editing in
                        if !editing {
                            Task { await model.commitBrightness() }
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Brightness")
                    .disabled(!model.canWrite || model.guestBrightness == nil)
                    value(model.guestBrightness == nil ? "—" : VPhonePanelFormat.percent(model.brightness))
                }
            }

            LabeledContent("Auto-Brightness") {
                value(onOff(model.autoBrightness))
            }

            Picker("Orientation", selection: orientationBinding) {
                if model.orientation == nil {
                    Text("Unknown").tag(VPhoneControlsOrientation?.none)
                }
                ForEach(VPhoneControlsOrientation.allCases) { orientation in
                    Text(orientation.title).tag(VPhoneControlsOrientation?.some(orientation))
                }
            }
            .disabled(!model.canWrite || model.orientation == nil)
            .help("Rotate the guest interface")

            Toggle("Rotation Lock", isOn: toggleBinding(model.rotationLocked) { locked in
                await model.setRotationLocked(locked)
            })
            .disabled(!model.canWrite || model.rotationLocked == nil)
            .help("Keep the guest interface from rotating with the device")
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section("Audio") {
            Picker("Category", selection: categoryBinding) {
                ForEach(VPhoneControlsVolumeCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .disabled(!model.canWrite)
            .help("Choose which volume the slider below reads and sets")

            LabeledContent("Volume") {
                HStack(spacing: 8) {
                    Slider(value: $model.volume, in: 0 ... 1) { editing in
                        if !editing {
                            Task { await model.commitVolume() }
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Volume")
                    .disabled(!model.canWrite || model.guestVolume == nil)
                    value(model.guestVolume == nil ? "—" : VPhonePanelFormat.percent(model.volume))
                }
            }

            LabeledContent("Active Session") {
                if let error = model.audioStateError {
                    VPhonePanelMonoText(error, secondary: true)
                } else if let category = model.activeAudioCategory {
                    VPhonePanelMonoText(activeSession(category))
                } else {
                    value("—")
                }
            }
        }
    }

    private func activeSession(_ category: String) -> String {
        let name = category.isEmpty ? String(localized: "None", bundle: VPhoneLocalization.bundle) : category
        let level = VPhonePanelFormat.percent(model.activeAudioVolume)
        if model.activeAudioMuted == true {
            return String(localized: "\(name), \(level), muted", bundle: VPhoneLocalization.bundle)
        }
        return String(localized: "\(name), \(level)", bundle: VPhoneLocalization.bundle)
    }

    // MARK: - Power

    private var powerSection: some View {
        Section("Power") {
            Toggle("Low Power Mode", isOn: toggleBinding(model.lowPowerMode) { enabled in
                await model.setLowPowerMode(enabled)
            })
            .disabled(!model.canWrite || model.lowPowerMode == nil)
            .help("Turn Low Power Mode on or off")
        }
    }

    // MARK: - Hardware Buttons

    private var buttonsSection: some View {
        Section("Hardware Buttons") {
            buttonRow([.home, .lock, .wake])
            buttonRow([.volumeUp, .volumeDown, .mute])
        }
    }

    private func buttonRow(_ buttons: [VPhoneControlsButton]) -> some View {
        HStack(spacing: 8) {
            ForEach(buttons) { button in
                Button {
                    Task { await model.press(button) }
                } label: {
                    Label(button.title, systemImage: button.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help(button.help)
            }
        }
        .disabled(!model.canWrite)
    }

    // MARK: - Keyboard

    private var keyboardSection: some View {
        Section("Keyboard") {
            TextField("Text", text: $model.keyboardText, prompt: Text("Text to send to the guest"), axis: .vertical)
                .labelsHidden()
                .lineLimit(3 ... 6)
                .font(.system(size: 11, design: .monospaced))

            HStack(spacing: 8) {
                Text(model.keyboardText.count == 1
                    ? String(localized: "1 character", bundle: VPhoneLocalization.bundle)
                    : String(localized: "\(model.keyboardText.count) characters", bundle: VPhoneLocalization.bundle))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Paste") { Task { await model.pasteText() } }
                    .help("Insert the whole text at once")
                Button("Type") { Task { await model.typeText() } }
                    .help("Type the text one character at a time (⌘↩)")
            }
            .disabled(!model.canSendText)

            HStack(spacing: 8) {
                ForEach(VPhoneControlsKey.allCases.filter { !$0.isArrow }) { key in
                    keyButton(key)
                }
            }

            HStack(spacing: 8) {
                ForEach(VPhoneControlsKey.allCases.filter(\.isArrow)) { key in
                    keyButton(key)
                }
                Spacer(minLength: 8)
                ForEach(VPhoneControlsModifier.allCases) { modifier in
                    Toggle(modifier.symbol, isOn: modifierBinding(modifier))
                        .toggleStyle(.button)
                        .help(modifier.help)
                }
            }
        }
    }

    private func keyButton(_ key: VPhoneControlsKey) -> some View {
        Button {
            Task { await model.send(key) }
        } label: {
            if key.isArrow {
                Image(systemName: key.systemImage)
                    .accessibilityLabel(key.title)
            } else {
                Label(key.title, systemImage: key.systemImage)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .help(String(localized: "Send \(model.keyName(key)) to the guest", bundle: VPhoneLocalization.bundle))
        .disabled(!model.canWrite)
    }

    // MARK: - Bindings

    private var orientationBinding: Binding<VPhoneControlsOrientation?> {
        Binding {
            model.orientation
        } set: { orientation in
            guard let orientation else { return }
            Task { await model.setOrientation(orientation) }
        }
    }

    private var categoryBinding: Binding<VPhoneControlsVolumeCategory> {
        Binding {
            model.volumeCategory
        } set: { category in
            Task { await model.selectVolumeCategory(category) }
        }
    }

    private func toggleBinding(_ value: Bool?, set: @escaping @MainActor (Bool) async -> Void) -> Binding<Bool> {
        Binding {
            value ?? false
        } set: { newValue in
            Task { await set(newValue) }
        }
    }

    private func modifierBinding(_ modifier: VPhoneControlsModifier) -> Binding<Bool> {
        Binding {
            model.modifiers.contains(modifier)
        } set: { isOn in
            if isOn {
                model.modifiers.insert(modifier)
            } else {
                model.modifiers.remove(modifier)
            }
        }
    }

    // MARK: - Values

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 36, alignment: .trailing)
    }

    private func onOff(_ value: Bool?) -> String {
        switch value {
        case true?: String(localized: "On", bundle: VPhoneLocalization.bundle)
        case false?: String(localized: "Off", bundle: VPhoneLocalization.bundle)
        case nil: "—"
        }
    }
}
