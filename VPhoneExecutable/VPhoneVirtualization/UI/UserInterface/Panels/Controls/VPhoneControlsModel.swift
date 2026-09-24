import Foundation

/// Display, audio, power, hardware button and keyboard controls for the guest.
/// Every write reads the guest's value back; a failed write restores the
/// control from the guest.
@MainActor
@Observable
final class VPhoneControlsModel {
    enum Activity: Equatable {
        case reading
        case setting(VPhoneControlsSetting)
        case pressing(VPhoneControlsButton)
        case sendingKey(String)
        case typing(Int)
        case pasting

        var title: String {
            switch self {
            case .reading:
                String(localized: "Reading guest controls…", bundle: VPhoneLocalization.bundle)
            case let .setting(setting):
                String(localized: "Setting \(setting.title)…", bundle: VPhoneLocalization.bundle)
            case let .pressing(button):
                String(localized: "Pressing \(button.title)…", bundle: VPhoneLocalization.bundle)
            case let .sendingKey(name):
                String(localized: "Sending \(name)…", bundle: VPhoneLocalization.bundle)
            case let .typing(count):
                String(localized: "Typing \(count) characters…", bundle: VPhoneLocalization.bundle)
            case .pasting:
                String(localized: "Pasting text…", bundle: VPhoneLocalization.bundle)
            }
        }
    }

    let control: VPhoneGuestControl
    /// Mirrors `control.isConnected`, which is not observable; `run()` keeps it current.
    var isConnected: Bool
    private(set) var activity: Activity?
    private(set) var status: VPhoneGuestToolStatus?

    // MARK: - Display State

    /// The slider position. It follows the guest except while the user drags.
    var brightness: Double = 0
    private(set) var guestBrightness: Double?
    private(set) var autoBrightness: Bool?
    private(set) var orientation: VPhoneControlsOrientation?
    private(set) var rotationLocked: Bool?

    // MARK: - Audio State

    var volume: Double = 0
    private(set) var guestVolume: Double?
    private(set) var volumeCategory: VPhoneControlsVolumeCategory = .media
    private(set) var activeAudioCategory: String?
    private(set) var activeAudioVolume: Double?
    private(set) var activeAudioMuted: Bool?
    private(set) var audioStateError: String?

    // MARK: - Power and Keyboard State

    private(set) var lowPowerMode: Bool?
    var keyboardText = ""
    var modifiers: Set<VPhoneControlsModifier> = []

    var isBusy: Bool {
        activity != nil
    }

    var canWrite: Bool {
        isConnected && !isBusy
    }

    var canSendText: Bool {
        canWrite && !keyboardText.isEmpty && keyboardText.utf8.count <= 64 * 1024
    }

    init(control: VPhoneGuestControl) {
        self.control = control
        isConnected = control.isConnected
    }

    // MARK: - Connection

    /// Reads the guest now and again whenever it reconnects. Runs until the
    /// view's task is cancelled.
    func run() async {
        var observed = control.isConnected
        if observed {
            isConnected = true
            await refresh()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let connected = control.isConnected
            guard connected != observed else { continue }
            observed = connected
            isConnected = connected
            if connected {
                await refresh()
            }
        }
    }

    // MARK: - Read

    func refresh() async {
        guard activity == nil else { return }
        isConnected = control.isConnected
        guard isConnected else {
            fail(String(localized: "The guest is not connected. Wait for vphoned to start, then refresh.", bundle: VPhoneLocalization.bundle))
            return
        }
        activity = .reading
        defer { activity = nil }

        var failures = 0
        let reads: [(String, [String: Any], @MainActor ([String: Any]) -> Void)] = [
            ("display.brightness", [:], { self.apply(brightnessResult: $0) }),
            ("display.rotation", [:], { self.apply(rotationResult: $0) }),
            ("audio.volume", ["category": volumeCategory.rawValue], { self.apply(volumeResult: $0) }),
            ("power.low_power_mode", [:], { self.apply(lowPowerModeResult: $0) }),
        ]
        for (method, params, apply) in reads {
            do {
                try await apply(control.call(method, params: params))
            } catch {
                failures += 1
            }
        }
        // audio.state fails when no audio session is active; that is a readout, not a failure.
        await readAudioState()

        if failures == reads.count {
            fail(String(localized: "Unable to read the guest controls. Check the connection, then try again.", bundle: VPhoneLocalization.bundle))
        } else if failures > 0 {
            fail(String(localized: "Unable to read some guest controls. Controls without a value are unavailable.", bundle: VPhoneLocalization.bundle))
        } else {
            status = nil
        }
    }

    private func readAudioState() async {
        do {
            try await apply(audioStateResult: control.call("audio.state"))
        } catch {
            activeAudioCategory = nil
            activeAudioVolume = nil
            activeAudioMuted = nil
            audioStateError = Self.guestMessage(error)
        }
    }

    // MARK: - Parse

    /// `display.brightness` → `{value, auto}`; `auto` is null when unknown.
    func apply(brightnessResult result: [String: Any]) {
        guestBrightness = result.double("value").map { min(max($0, 0), 1) }
        brightness = guestBrightness ?? 0
        autoBrightness = result.bool("auto")
    }

    /// `display.rotation` and `display.rotation_lock` → `{degrees, name, locked, device_orientation}`.
    func apply(rotationResult result: [String: Any]) {
        orientation = result.int("degrees").flatMap(VPhoneControlsOrientation.init(degrees:))
        rotationLocked = result.bool("locked")
    }

    /// `audio.volume` → `{volume, category}`; a negative volume means the category is unreadable.
    func apply(volumeResult result: [String: Any]) {
        if let category = result.string("category").flatMap(VPhoneControlsVolumeCategory.init(rawValue:)) {
            volumeCategory = category
        }
        guestVolume = result.double("volume").flatMap { $0 < 0 ? nil : min($0, 1) }
        volume = guestVolume ?? 0
    }

    /// `audio.state` → `{active_volume, active_category, active_muted}`. Also the
    /// shape `input.button` returns for volume-up, volume-down and mute.
    func apply(audioStateResult result: [String: Any]) {
        activeAudioCategory = result.string("active_category")
        activeAudioVolume = result.double("active_volume")
        activeAudioMuted = result.bool("active_muted")
        audioStateError = nil
    }

    /// `power.low_power_mode` → `{enabled, method}` (plus `changed` after a set).
    func apply(lowPowerModeResult result: [String: Any]) {
        lowPowerMode = result.bool("enabled")
    }

    // MARK: - Display

    func commitBrightness() async {
        let value = (brightness * 100).rounded() / 100
        guard value != guestBrightness else { return }
        await write(.brightness, method: "display.brightness", params: ["value": value]) { result in
            self.apply(brightnessResult: result)
            return String(localized: "Brightness set to \(VPhonePanelFormat.percent(self.guestBrightness)).", bundle: VPhoneLocalization.bundle)
        } revert: {
            self.brightness = self.guestBrightness ?? 0
        }
    }

    func setOrientation(_ target: VPhoneControlsOrientation) async {
        guard target != orientation else { return }
        let previous = orientation
        orientation = target
        await write(.orientation, method: "display.rotation", params: ["orientation": target.spec]) { result in
            self.apply(rotationResult: result)
            return String(localized: "Orientation set to \(target.title).", bundle: VPhoneLocalization.bundle)
        } revert: {
            self.orientation = previous
        }
    }

    func setRotationLocked(_ locked: Bool) async {
        let previous = rotationLocked
        rotationLocked = locked
        await write(.rotationLock, method: "display.rotation_lock", params: ["locked": locked]) { result in
            self.apply(rotationResult: result)
            return locked
                ? String(localized: "Rotation Lock is on.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Rotation Lock is off.", bundle: VPhoneLocalization.bundle)
        } revert: {
            self.rotationLocked = previous
        }
    }

    // MARK: - Audio

    func commitVolume() async {
        let value = (volume * 100).rounded() / 100
        guard value != guestVolume else { return }
        let category = volumeCategory
        await write(.volume, method: "audio.volume", params: ["value": value, "category": category.rawValue]) { result in
            self.apply(volumeResult: result)
            await self.readAudioState()
            return String(localized: "\(category.title) volume set to \(VPhonePanelFormat.percent(self.guestVolume)).", bundle: VPhoneLocalization.bundle)
        } revert: {
            self.volume = self.guestVolume ?? 0
        }
    }

    /// Switches the slider to another volume category and reads its level.
    func selectVolumeCategory(_ category: VPhoneControlsVolumeCategory) async {
        guard category != volumeCategory, !isBusy else { return }
        let previous = volumeCategory
        volumeCategory = category
        activity = .reading
        defer { activity = nil }
        do {
            try await apply(volumeResult: control.call("audio.volume", params: ["category": category.rawValue]))
            status = nil
        } catch {
            volumeCategory = previous
            fail(String(localized: "Unable to read the \(category.title) volume. \(Self.guestMessage(error))", bundle: VPhoneLocalization.bundle))
        }
    }

    // MARK: - Power

    func setLowPowerMode(_ enabled: Bool) async {
        let previous = lowPowerMode
        lowPowerMode = enabled
        await write(.lowPowerMode, method: "power.low_power_mode", params: ["enabled": enabled]) { result in
            self.apply(lowPowerModeResult: result)
            return enabled
                ? String(localized: "Low Power Mode is on.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Low Power Mode is off.", bundle: VPhoneLocalization.bundle)
        } revert: {
            self.lowPowerMode = previous
        }
    }

    // MARK: - Hardware Buttons

    func press(_ button: VPhoneControlsButton) async {
        guard canWrite else { return }
        activity = .pressing(button)
        do {
            let result = try await control.call("input.button", params: ["name": button.name])
            if button.isAudio {
                apply(audioStateResult: result)
                if let volume = try? await control.call("audio.volume", params: ["category": volumeCategory.rawValue]) {
                    apply(volumeResult: volume)
                }
            }
            activity = nil
            succeed(String(localized: "Pressed \(button.title).", bundle: VPhoneLocalization.bundle))
        } catch {
            activity = nil
            fail(String(localized: "Unable to press \(button.title). \(Self.guestMessage(error))", bundle: VPhoneLocalization.bundle))
        }
    }

    // MARK: - Keyboard

    /// The `input.key` name for a key with the selected modifiers, such as `cmd+shift+left`.
    func keyName(_ key: VPhoneControlsKey) -> String {
        let prefix = VPhoneControlsModifier.allCases.filter(modifiers.contains).map(\.name)
        return (prefix + [key.name]).joined(separator: "+")
    }

    func send(_ key: VPhoneControlsKey) async {
        guard canWrite else { return }
        let name = keyName(key)
        activity = .sendingKey(name)
        do {
            _ = try await control.call("input.key", params: ["name": name])
            activity = nil
            succeed(String(localized: "Sent \(name).", bundle: VPhoneLocalization.bundle))
        } catch {
            activity = nil
            fail(String(localized: "Unable to send \(name). \(Self.guestMessage(error))", bundle: VPhoneLocalization.bundle))
        }
    }

    /// Sends the text one character at a time, as a hardware keyboard would.
    func typeText() async {
        guard canSendText else { return }
        let text = keyboardText
        activity = .typing(text.count)
        do {
            let result = try await control.call("input.type", params: ["text": text, "delay_ms": 30])
            activity = nil
            succeed(String(localized: "Typed \(result.int("sent") ?? text.count) characters.", bundle: VPhoneLocalization.bundle))
        } catch {
            activity = nil
            fail(String(localized: "Unable to type the text. \(Self.guestMessage(error))", bundle: VPhoneLocalization.bundle))
        }
    }

    /// Inserts the whole text in one keyboard event.
    func pasteText() async {
        guard canSendText else { return }
        let text = keyboardText
        activity = .pasting
        do {
            let result = try await control.call("input.paste", params: ["text": text])
            activity = nil
            succeed(String(localized: "Pasted \(result.int("sent") ?? text.count) characters.", bundle: VPhoneLocalization.bundle))
        } catch {
            activity = nil
            fail(String(localized: "Unable to paste the text. \(Self.guestMessage(error))", bundle: VPhoneLocalization.bundle))
        }
    }

    // MARK: - Write

    /// Sends one setting, applies the guest's answer, and on failure restores
    /// the control from the guest (or from `revert` when the guest cannot answer).
    private func write(
        _ setting: VPhoneControlsSetting,
        method: String,
        params: [String: Any],
        apply: @MainActor ([String: Any]) async -> String,
        revert: @MainActor () -> Void,
    ) async {
        guard canWrite else {
            revert()
            return
        }
        activity = .setting(setting)
        do {
            let result = try await control.call(method, params: params)
            let message = await apply(result)
            activity = nil
            succeed(message)
        } catch {
            revert()
            let reason = Self.guestMessage(error)
            activity = nil
            await reread(setting)
            fail(String(localized: "Unable to set \(setting.title). \(reason)", bundle: VPhoneLocalization.bundle))
        }
    }

    private func reread(_ setting: VPhoneControlsSetting) async {
        do {
            switch setting {
            case .brightness:
                try await apply(brightnessResult: control.call("display.brightness"))
            case .orientation, .rotationLock:
                try await apply(rotationResult: control.call("display.rotation"))
            case .volume:
                try await apply(volumeResult: control.call("audio.volume", params: ["category": volumeCategory.rawValue]))
            case .lowPowerMode:
                try await apply(lowPowerModeResult: control.call("power.low_power_mode"))
            }
        } catch {
            // The reverted local value stands.
        }
    }

    // MARK: - Status

    /// The guest's own error text, or what to do when there is none.
    static func guestMessage(_ error: Error) -> String {
        if case let VPhoneGuestControl.ControlError.guestError(message) = error, !message.isEmpty {
            let sentence = message.prefix(1).uppercased() + message.dropFirst()
            return sentence.hasSuffix(".") ? sentence : sentence + "."
        }
        return String(localized: "Check the connection, then try again.", bundle: VPhoneLocalization.bundle)
    }

    private func succeed(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: false)
    }

    private func fail(_ message: String) {
        status = VPhoneGuestToolStatus(message: message, isError: true)
    }
}
