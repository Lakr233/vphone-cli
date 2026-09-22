import AppKit
import IOKit.ps

// MARK: - Battery Menu

extension VPhoneMenuController {
    func buildBatterySubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Battery", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Battery")

        // Sync toggle
        let syncItem = makeItem("Sync with Host", action: #selector(toggleBatterySync(_:)))
        syncItem.state = .off
        menu.addItem(syncItem)

        // Status line (hidden until sync is active)
        let statusItem = NSMenuItem(title: "Status: —", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.isHidden = true
        menu.addItem(statusItem)
        batterySyncStatusItem = statusItem

        menu.addItem(NSMenuItem.separator())

        // Charge level presets
        batteryLevelMenuItems = []
        for level in [100, 75, 50, 25, 10, 5] {
            let mi = makeItem("\(level)%", action: #selector(setBatteryLevel(_:)))
            mi.tag = level
            mi.state = level == 100 ? .on : .off
            menu.addItem(mi)
            batteryLevelMenuItems.append(mi)
        }

        menu.addItem(NSMenuItem.separator())

        // Connectivity: 1=charging, 2=disconnected
        let charging = makeItem("Charging", action: #selector(setBatteryConnectivity(_:)))
        charging.tag = 1
        charging.state = .on
        let disconnected = makeItem("Disconnected", action: #selector(setBatteryConnectivity(_:)))
        disconnected.tag = 2

        menu.addItem(charging)
        menu.addItem(disconnected)
        batteryConnectivityMenuItems = [charging, disconnected]

        item.submenu = menu

        // Enable sync by default
        syncItem.state = .on
        batterySyncEnabled = true
        batterySyncStatusItem?.isHidden = false
        batteryLevelMenuItems.forEach { $0.isEnabled = false }
        batteryConnectivityMenuItems.forEach { $0.isEnabled = false }
        syncBatteryFromHost()
        syncLowPowerModeFromHost()
        startPowerSourceMonitoring()
        startLowPowerMonitoring()

        return item
    }

    @objc func setBatteryLevel(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        for mi in menu.items {
            if mi.isSeparatorItem { break }
            mi.state = mi === sender ? .on : .off
        }
        let charge = Double(sender.tag)
        let connectivity = currentBatteryConnectivity(in: menu)
        vm?.setBattery(charge: charge, connectivity: connectivity)
        print("[battery] set \(sender.tag)%, connectivity=\(connectivity)")
    }

    @objc func setBatteryConnectivity(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        var pastSeparator = false
        for mi in menu.items {
            if mi.isSeparatorItem { pastSeparator = true; continue }
            if pastSeparator { mi.state = mi === sender ? .on : .off }
        }
        let charge = currentBatteryCharge(in: menu)
        vm?.setBattery(charge: charge, connectivity: sender.tag)
        print("[battery] set \(Int(charge))%, connectivity=\(sender.tag)")
    }

    // MARK: - Host Sync

    @objc func toggleBatterySync(_ sender: NSMenuItem) {
        batterySyncEnabled.toggle()
        sender.state = batterySyncEnabled ? .on : .off
        batterySyncStatusItem?.isHidden = !batterySyncEnabled
        let manualEnabled = !batterySyncEnabled
        batteryLevelMenuItems.forEach { $0.isEnabled = manualEnabled }
        batteryConnectivityMenuItems.forEach { $0.isEnabled = manualEnabled }

        if batterySyncEnabled {
            syncBatteryFromHost()
            syncLowPowerModeFromHost()
            startPowerSourceMonitoring()
            startLowPowerMonitoring()
        } else {
            stopPowerSourceMonitoring()
            stopLowPowerMonitoring()
        }
        print("[battery] host sync \(batterySyncEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Battery State Sync

    func syncBatteryFromHost() {
        guard batterySyncEnabled else { return }
        guard let (charge, connectivity) = hostBatteryState() else {
            batterySyncStatusItem?.title = "Status: no host battery"
            return
        }
        vm?.setBattery(charge: charge, connectivity: connectivity)
        updateStatusLabel(charge: charge, connectivity: connectivity)
        print("[battery] sync \(Int(charge))%, connectivity=\(connectivity)")
    }

    private func hostBatteryState() -> (charge: Double, connectivity: Int)? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = info[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            let capacity = info[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let state = info[kIOPSPowerSourceStateKey as String] as? String ?? kIOPSACPowerValue
            let connectivity = (state == kIOPSACPowerValue) ? 1 : 2
            return (Double(capacity), connectivity)
        }
        return nil
    }

    // MARK: - Low Power Mode Sync

    func syncLowPowerModeFromHost() {
        guard batterySyncEnabled else { return }
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        Task {
            do {
                try await control.lowPowerMode(enabled: enabled)
                syncBatteryFromHost()  // refresh status label with updated LPM state
                print("[battery] sync LPM: \(enabled)")
            } catch {
                print("[battery] sync LPM failed: \(error)")
            }
        }
    }

    // MARK: - IOKit Power Source Monitoring

    private func startPowerSourceMonitoring() {
        stopPowerSourceMonitoring()
        let rawPtr = Unmanaged.passRetained(self).toOpaque()
        powerSourceRetainedPtr = rawPtr
        let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let ctx = rawContext else { return }
            Task { @MainActor in
                Unmanaged<VPhoneMenuController>.fromOpaque(ctx)
                    .takeUnretainedValue()
                    .syncBatteryFromHost()
            }
        }, rawPtr)
        guard let runLoopSource = source?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    private func stopPowerSourceMonitoring() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
        if let ptr = powerSourceRetainedPtr {
            Unmanaged<VPhoneMenuController>.fromOpaque(ptr).release()
            powerSourceRetainedPtr = nil
        }
    }

    // MARK: - Low Power Mode Monitoring

    private func startLowPowerMonitoring() {
        stopLowPowerMonitoring()
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncLowPowerModeFromHost() }
        }
    }

    private func stopLowPowerMonitoring() {
        if let observer = lowPowerObserver {
            NotificationCenter.default.removeObserver(observer)
            lowPowerObserver = nil
        }
    }

    // MARK: - Status Label

    private func updateStatusLabel(charge: Double, connectivity: Int) {
        let connLabel = connectivity == 1 ? "charging" : "not charging"
        let lpmLabel = ProcessInfo.processInfo.isLowPowerModeEnabled ? ", low power" : ""
        batterySyncStatusItem?.title = "Status: \(Int(charge))% (\(connLabel)\(lpmLabel))"
    }

    // MARK: - Helpers

    private func currentBatteryCharge(in menu: NSMenu) -> Double {
        for mi in menu.items {
            if mi.isSeparatorItem { break }
            if mi.state == .on { return Double(mi.tag) }
        }
        return 100.0
    }

    private func currentBatteryConnectivity(in menu: NSMenu) -> Int {
        var pastSeparator = false
        for mi in menu.items {
            if mi.isSeparatorItem { pastSeparator = true; continue }
            if pastSeparator, mi.state == .on { return mi.tag }
        }
        return 1
    }
}
