import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Camera Menu

extension VPhoneMenuController {
    func buildCameraSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        item.image = menuSymbol("camera")
        let menu = NSMenu(title: "Camera")

        let status = NSMenuItem(
            title: "Camera server: disconnected",
            action: nil,
            keyEquivalent: "",
        )
        status.isEnabled = false
        cameraStatusItem = status
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())

        let off = makeItem("Source: Off", action: #selector(setCameraSourceOff))
        off.state = .on
        cameraSourceOffItem = off
        menu.addItem(off)

        let testPattern = makeItem(
            "Source: Test Pattern",
            action: #selector(setCameraSourceTestPattern),
        )
        cameraSourceTestPatternItem = testPattern
        menu.addItem(testPattern)

        let videoFile = makeItem(
            "Source: Video File…",
            action: #selector(setCameraSourceVideoFile),
        )
        cameraSourceVideoFileItem = videoFile
        menu.addItem(videoFile)

        let systemCamera = makeItem("Source: System Camera…", action: #selector(setCameraSourceSystemCamera))
        cameraSourceSystemCameraItem = systemCamera
        menu.addItem(systemCamera)

        menu.addItem(NSMenuItem.separator())

        let startStop = makeItem(
            "Start Streaming",
            action: #selector(toggleCameraStreaming),
            symbol: "play",
        )
        startStop.isEnabled = false
        cameraStartStopItem = startStop
        menu.addItem(startStop)

        item.submenu = menu
        return item
    }

    func updateCameraConnectionState(connected: Bool) {
        cameraStatusItem?.title = VPhoneLocalization.text(
            connected ? "Camera server: connected" : "Camera server: disconnected",
        )
        cameraStartStopItem?.isEnabled = connected && (cameraServer?.sourceKind ?? .off) != .off
    }

    private func refreshCameraSourceCheckmarks() {
        let kind = cameraServer?.sourceKind ?? .off
        cameraSourceOffItem?.state = (kind == .off) ? .on : .off
        cameraSourceTestPatternItem?.state =
            (kind == .testPattern) ? .on : .off
        cameraSourceVideoFileItem?.state =
            (kind == .videoFile) ? .on : .off
        cameraSourceSystemCameraItem?.state = (kind == .systemCamera) ? .on : .off
    }

    @objc func setCameraSourceOff() {
        cameraServer?.stopStreaming()
        try? cameraServer?.setSource(.off)
        refreshCameraSourceCheckmarks()
        cameraStartStopItem?.isEnabled = false
        cameraStartStopItem?.title = VPhoneLocalization.text("Start Streaming")
        cameraStartStopItem?.image = menuSymbol("play")
    }

    @objc func setCameraSourceTestPattern() {
        try? cameraServer?.setSource(.testPattern)
        refreshCameraSourceCheckmarks()
        cameraStartStopItem?.isEnabled = (cameraServer?.isConnected ?? false)
    }

    @objc func setCameraSourceVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // AVFoundation's natively-decodable containers on macOS. Anything
        // beyond these (.mkv/.webm/.avi) would need external conversion to
        // .mov / .mp4 first.
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mov") ?? .movie,
            UTType(filenameExtension: "mp4") ?? .movie,
            UTType(filenameExtension: "m4v") ?? .movie,
        ]
        panel.prompt = VPhoneLocalization.text("Use as Camera Source")
        panel.title = VPhoneLocalization.text("Choose Video File")
        VPhoneAlert.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            try? cameraServer?.setSource(.videoFile, videoURL: url)
            refreshCameraSourceCheckmarks()
            cameraStartStopItem?.isEnabled =
                (cameraServer?.isConnected ?? false) &&
                (cameraServer?.sourceKind ?? .off) == .videoFile
        }
    }

    @objc func setCameraSourceSystemCamera() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            do {
                guard allowed else {
                    throw NSError(domain: "VPhoneCamera", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Allow camera access for vphone-launchpad in System Settings → Privacy & Security → Camera."])
                }
                presentSystemCameraPicker()
            } catch {
                VPhoneAlert.present(title: "System Camera Unavailable",
                                    message: error.localizedDescription, style: .warning)
            }
        }
    }

    private func presentSystemCameraPicker() {
        // Discover afresh each time so plugging in a camera requires no restart.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        let devices = discovery.devices.sorted {
            $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        picker.setAccessibilityLabel(VPhoneLocalization.text("Camera"))
        picker.addItem(withTitle: VPhoneLocalization.text("System Default"))
        for device in devices {
            // Use identifiers rather than names: two cameras may have the same name.
            let item = NSMenuItem(title: device.localizedName, action: nil, keyEquivalent: "")
            item.representedObject = device.uniqueID
            picker.menu?.addItem(item)
        }
        if let selected = cameraServer?.cameraDeviceID {
            if let item = picker.itemArray.first(where: { $0.representedObject as? String == selected }) {
                picker.select(item)
            } else {
                let missing = NSMenuItem(title: VPhoneLocalization.text("Selected Camera (Disconnected)"),
                                         action: nil, keyEquivalent: "")
                missing.representedObject = selected
                picker.menu?.addItem(missing)
                picker.select(missing)
            }
        }
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Choose Camera")
        alert.informativeText = VPhoneLocalization.text("Choose the Mac camera to share with this virtual iPhone.")
        alert.accessoryView = picker
        alert.addButton(withTitle: VPhoneLocalization.text("Use Camera"))
        alert.addButton(withTitle: VPhoneLocalization.text("Cancel"))
        VPhoneAlert.present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try cameraServer?.setSource(.systemCamera,
                    cameraDeviceID: picker.selectedItem?.representedObject as? String)
                refreshCameraSourceCheckmarks()
                cameraStartStopItem?.isEnabled = cameraServer?.isConnected ?? false
            } catch {
                VPhoneAlert.present(title: "System Camera Unavailable",
                                    message: error.localizedDescription, style: .warning)
            }
        }
    }

    @objc func toggleCameraStreaming() {
        guard let server = cameraServer else { return }
        if cameraStartStopItem?.title == VPhoneLocalization.text("Start Streaming") {
            server.startStreaming()
            cameraStartStopItem?.title = VPhoneLocalization.text("Stop Streaming")
            cameraStartStopItem?.image = menuSymbol("stop")
        } else {
            server.stopStreaming()
            cameraStartStopItem?.title = VPhoneLocalization.text("Start Streaming")
            cameraStartStopItem?.image = menuSymbol("play")
        }
    }
}
