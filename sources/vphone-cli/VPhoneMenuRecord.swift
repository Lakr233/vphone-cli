import AppKit

// MARK: - Record Menu

extension VPhoneMenuController {
    func buildRecordMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Record")
        let toggle = makeItem("Start Recording", action: #selector(toggleRecording))
        recordingItem = toggle
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Copy Screenshot to Clipboard", action: #selector(copyScreenshotToClipboard)))
        menu.addItem(makeItem("Save Screenshot to File", action: #selector(saveScreenshotToFile)))
        item.submenu = menu
        return item
    }

    @objc func toggleRecording() {
        if screenRecorder?.isRecording == true {
            Task { @MainActor in
                _ = await screenRecorder?.stopRecording()
                recordingItem?.title = "Start Recording"
            }
        } else {
            guard let view = activeCaptureView() else {
                showAlert(title: "Recording", message: "No active VM window.", style: .warning)
                return
            }
            do {
                try screenRecorder?.startRecording(view: view)
                recordingItem?.title = "Stop Recording"
            } catch {
                showAlert(title: "Recording", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func copyScreenshotToClipboard() {
        guard let recorder = screenRecorder else { return }
        guard let view = activeCaptureView() else {
            showAlert(title: "Screenshot", message: "No active VM window.", style: .warning)
            return
        }

        Task { @MainActor in
            do {
                try await recorder.copyScreenshotToPasteboard(view: view)
                showAlert(title: "Screenshot", message: "Copied to clipboard.", style: .informational)
            } catch {
                showAlert(title: "Screenshot", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func saveScreenshotToFile() {
        guard let recorder = screenRecorder else { return }
        guard let view = activeCaptureView() else {
            showAlert(title: "Screenshot", message: "No active VM window.", style: .warning)
            return
        }

        Task { @MainActor in
            do {
                let url = try await recorder.saveScreenshot(view: view)
                showAlert(title: "Screenshot", message: "Saved to \(url.path)", style: .informational)
            } catch {
                showAlert(title: "Screenshot", message: "\(error)", style: .warning)
            }
        }
    }

    private func activeCaptureView() -> NSView? {
        NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView
    }
}
