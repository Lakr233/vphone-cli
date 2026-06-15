import AppKit
import UniformTypeIdentifiers

// MARK: - Camera Menu

extension VPhoneMenuController {
    func buildCameraSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Camera")

        let status = NSMenuItem(title: "Camera server: disconnected",
                                 action: nil, keyEquivalent: "")
        status.isEnabled = false
        cameraStatusItem = status
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())

        let off = makeItem("Source: Off", action: #selector(setCameraSourceOff))
        off.state = .on
        cameraSourceOffItem = off
        menu.addItem(off)

        let testPattern = makeItem("Source: Test Pattern",
                                    action: #selector(setCameraSourceTestPattern))
        cameraSourceTestPatternItem = testPattern
        menu.addItem(testPattern)

        let videoFile = makeItem("Source: Video File…",
                                  action: #selector(setCameraSourceVideoFile))
        cameraSourceVideoFileItem = videoFile
        menu.addItem(videoFile)

        menu.addItem(NSMenuItem.separator())

        let startStop = makeItem("Start Streaming",
                                  action: #selector(toggleCameraStreaming))
        startStop.isEnabled = false
        cameraStartStopItem = startStop
        menu.addItem(startStop)

        item.submenu = menu
        return item
    }

    func updateCameraConnectionState(connected: Bool) {
        cameraStatusItem?.title = connected
            ? "Camera server: connected (vsock 1338)"
            : "Camera server: disconnected"
        cameraStartStopItem?.isEnabled = connected &&
            (cameraServer?.sourceKind ?? .off) != .off
    }

    private func refreshCameraSourceCheckmarks() {
        let kind = cameraServer?.sourceKind ?? .off
        cameraSourceOffItem?.state = (kind == .off) ? .on : .off
        cameraSourceTestPatternItem?.state =
            (kind == .testPattern) ? .on : .off
        cameraSourceVideoFileItem?.state =
            (kind == .videoFile) ? .on : .off
    }

    @objc func setCameraSourceOff() {
        cameraServer?.stopStreaming()
        cameraServer?.setSource(.off)
        refreshCameraSourceCheckmarks()
        cameraStartStopItem?.isEnabled = false
        cameraStartStopItem?.title = "Start Streaming"
    }

    @objc func setCameraSourceTestPattern() {
        cameraServer?.setSource(.testPattern)
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
        panel.prompt = "Use as Camera Source"
        panel.title = "Pick a video file"
        panel.runModal()
        guard let url = panel.url else { return }
        cameraServer?.setSource(.videoFile, videoURL: url)
        refreshCameraSourceCheckmarks()
        cameraStartStopItem?.isEnabled =
            (cameraServer?.isConnected ?? false) &&
            (cameraServer?.sourceKind ?? .off) == .videoFile
    }

    @objc func toggleCameraStreaming() {
        guard let server = cameraServer else { return }
        if cameraStartStopItem?.title == "Start Streaming" {
            server.startStreaming()
            cameraStartStopItem?.title = "Stop Streaming"
        } else {
            server.stopStreaming()
            cameraStartStopItem?.title = "Start Streaming"
        }
    }
}
