import AppKit

private struct LocationPreset {
    let title: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

private let locationPresets: [LocationPreset] = [
    LocationPreset(
        title: "Apple Park (Cupertino)",
        latitude: 37.334606,
        longitude: -122.009102,
        altitude: 14
    ),
    LocationPreset(
        title: "SF Ferry Building",
        latitude: 37.795490,
        longitude: -122.393738,
        altitude: 5
    ),
    LocationPreset(
        title: "Times Square (NYC)",
        latitude: 40.758000,
        longitude: -73.985500,
        altitude: 12
    ),
    LocationPreset(
        title: "Shibuya Crossing (Tokyo)",
        latitude: 35.659500,
        longitude: 139.700500,
        altitude: 38
    ),
]

private let locationReplayName = "Apple Park Loop"
private let locationReplayPoints: [VPhoneLocationProvider.ReplayPoint] = [
    .init(latitude: 37.334606, longitude: -122.009102, altitude: 14, speed: 6.5, course: 240),
    .init(latitude: 37.333660, longitude: -122.011700, altitude: 14, speed: 7.0, course: 255),
    .init(latitude: 37.332500, longitude: -122.014200, altitude: 14, speed: 7.2, course: 300),
    .init(latitude: 37.333300, longitude: -122.016000, altitude: 14, speed: 6.6, course: 20),
    .init(latitude: 37.335100, longitude: -122.016300, altitude: 14, speed: 6.4, course: 55),
    .init(latitude: 37.337000, longitude: -122.014100, altitude: 14, speed: 6.8, course: 95),
    .init(latitude: 37.337600, longitude: -122.011200, altitude: 14, speed: 6.9, course: 130),
    .init(latitude: 37.336500, longitude: -122.008900, altitude: 14, speed: 6.3, course: 175),
]

// MARK: - Location Menu

extension VPhoneMenuController {
    func buildLocationSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Location", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Location")

        let toggle = makeItem("Sync Host Location", action: #selector(toggleLocationSync))
        toggle.state = .off
        toggle.isEnabled = false
        locationMenuItem = toggle
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let presets = NSMenuItem(title: "Preset Location", action: nil, keyEquivalent: "")
        let presetsMenu = NSMenu(title: "Preset Location")
        for (index, preset) in locationPresets.enumerated() {
            let presetItem = makeItem(preset.title, action: #selector(setLocationPreset(_:)))
            presetItem.tag = index
            presetsMenu.addItem(presetItem)
        }
        presets.submenu = presetsMenu
        presets.isEnabled = false
        locationPresetMenuItem = presets
        menu.addItem(presets)

        menu.addItem(NSMenuItem.separator())

        let replayStart = makeItem("Start Route Replay", action: #selector(startLocationReplay(_:)))
        replayStart.isEnabled = false
        locationReplayStartItem = replayStart
        menu.addItem(replayStart)

        let replayStop = makeItem("Stop Route Replay", action: #selector(stopLocationReplay(_:)))
        replayStop.isEnabled = false
        locationReplayStopItem = replayStop
        menu.addItem(replayStop)

        item.submenu = menu
        return item
    }

    /// Enable or disable the location toggle based on guest capability.
    /// Preserves the user's checkmark state across connect/disconnect cycles.
    func updateLocationCapability(available: Bool) {
        locationMenuItem?.isEnabled = available
        locationPresetMenuItem?.isEnabled = available
        refreshLocationReplayState(available: available)
    }

    @objc func toggleLocationSync() {
        guard let item = locationMenuItem else { return }
        if item.state == .on {
            locationProvider?.stopForwarding()
            control.sendLocationStop()
            item.state = .off
            print("[location] sync toggled off by user")
        } else {
            locationProvider?.stopReplay()
            locationProvider?.startForwarding()
            item.state = .on
            print("[location] sync toggled on by user")
        }
        refreshLocationReplayState(available: item.isEnabled)
    }

    @objc func setLocationPreset(_ sender: NSMenuItem) {
        guard locationMenuItem?.isEnabled == true else { return }
        guard sender.tag >= 0, sender.tag < locationPresets.count else { return }
        let preset = locationPresets[sender.tag]
        disableHostSyncForManualLocation()
        locationProvider?.sendPreset(
            name: preset.title,
            latitude: preset.latitude,
            longitude: preset.longitude,
            altitude: preset.altitude
        )
        refreshLocationReplayState(available: true)
    }

    @objc func startLocationReplay(_: NSMenuItem) {
        guard locationMenuItem?.isEnabled == true else { return }
        disableHostSyncForManualLocation()
        locationProvider?.startReplay(
            name: locationReplayName,
            points: locationReplayPoints,
            intervalSeconds: 1.5,
            loop: true
        )
        refreshLocationReplayState(available: true)
    }

    @objc func stopLocationReplay(_: NSMenuItem) {
        locationProvider?.stopReplay()
        refreshLocationReplayState(available: locationMenuItem?.isEnabled ?? false)
    }

    private func disableHostSyncForManualLocation() {
        guard let hostSyncItem = locationMenuItem else { return }
        if hostSyncItem.state == .on {
            locationProvider?.stopForwarding()
            hostSyncItem.state = .off
            print("[location] host sync disabled for manual simulation")
        }
    }

    private func refreshLocationReplayState(available: Bool) {
        let replaying = locationProvider?.isReplaying ?? false
        locationReplayStartItem?.isEnabled = available && !replaying
        locationReplayStopItem?.isEnabled = available && replaying
        locationReplayStartItem?.state = replaying ? .on : .off
        locationReplayStopItem?.state = replaying ? .on : .off
    }
}
