import AppKit

// MARK: - Record Menu

extension VPhoneMenuController {
    func buildRecordMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Capture")
        let toggle = makeItem(
            "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r",
            modifiers: [.command, .shift],
        )
        recordingItem = toggle
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Copy Screenshot to Mac Clipboard", action: #selector(copyScreenshotToClipboard)))
        menu.addItem(makeItem("Save Screenshot to File", action: #selector(saveScreenshotToFile)))
        item.submenu = menu
        return item
    }

    @objc func toggleRecording() {
        if screenRecorder?.isRecording == true {
            Task { @MainActor in
                let url = await screenRecorder?.stopRecording()
                recordingItem?.title = "Start Recording"
                if let url {
                    showRecordingSavedAlert(url: url)
                }
            }
        } else {
            guard let view = activeCaptureView() else {
                showCaptureAlert(
                    title: "Recording",
                    message: "No VM window is open. Start a VM, then try again.",
                    style: .warning,
                )
                return
            }
            do {
                try screenRecorder?.startRecording(view: view)
                recordingItem?.title = "Stop Recording"
            } catch {
                showCaptureAlert(title: "Recording", message: "Unable to start recording. Try again.", style: .warning)
            }
        }
    }

    @objc func copyScreenshotToClipboard() {
        guard let recorder = screenRecorder else { return }
        guard control.isConnected else {
            showCaptureAlert(
                title: "Screenshot",
                message: "The guest is not connected. Start a VM, then try again.",
                style: .warning,
            )
            return
        }

        Task { @MainActor in
            do {
                let image = try await control.screenshotJPEG()
                try recorder.copyScreenshotToPasteboard(jpegData: image)
                showCaptureAlert(title: "Screenshot", message: "Screenshot copied to the Mac clipboard.", style: .informational)
            } catch {
                showCaptureAlert(title: "Screenshot", message: "Unable to copy the screenshot. Try again.", style: .warning)
            }
        }
    }

    @objc func saveScreenshotToFile() {
        guard let recorder = screenRecorder else { return }
        guard control.isConnected else {
            showCaptureAlert(
                title: "Screenshot",
                message: "The guest is not connected. Start a VM, then try again.",
                style: .warning,
            )
            return
        }

        Task { @MainActor in
            do {
                let image = try await control.screenshotJPEG()
                let url = try recorder.saveScreenshot(jpegData: image)
                showCaptureAlert(title: "Screenshot", message: "Saved to \(url.path)", style: .informational)
            } catch {
                showCaptureAlert(title: "Screenshot", message: "Unable to save the screenshot. Try again.", style: .warning)
            }
        }
    }

    private func activeCaptureView() -> NSView? {
        guard let captureView else { return nil }
        return captureView.window == nil ? nil : captureView
    }

    private func showCaptureAlert(title: String, message: String, style: NSAlert.Style) {
        VPhoneAlert.present(
            title: title,
            message: message,
            style: style,
            attachedTo: NSApp.keyWindow ?? activeCaptureView()?.window,
        )
    }

    private func showRecordingSavedAlert(url: URL) {
        VPhoneAlert.present(
            title: "Recording",
            message: "Saved to \(url.path)",
            style: .informational,
            attachedTo: NSApp.keyWindow ?? activeCaptureView()?.window,
            buttons: ["OK", "Reveal in Finder"],
        ) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
