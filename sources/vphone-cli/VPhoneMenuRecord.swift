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
                let url = await screenRecorder?.stopRecording()
                recordingItem?.title = "Start Recording"
                if let url {
                    showRecordingSavedAlert(url: url)
                }
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
        guard let captureView else { return nil }
        return captureView.window == nil ? nil : captureView
    }

    private func showRecordingSavedAlert(url: URL) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording"
        panel.center()

        let msg = NSTextField(labelWithString: "Saved to \(url.path)")
        msg.frame = NSRect(x: 20, y: 60, width: 380, height: 30)
        msg.lineBreakMode = .byTruncatingMiddle

        let reveal = NSButton(frame: NSRect(x: 20, y: 12, width: 150, height: 28))
        reveal.title = "Reveal in Finder"
        reveal.bezelStyle = .rounded

        let ok = NSButton(frame: NSRect(x: 310, y: 12, width: 90, height: 28))
        ok.title = "OK"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = self
        ok.action = #selector(VPhoneMenuController.confirmModal)

        panel.contentView?.addSubview(msg)
        panel.contentView?.addSubview(reveal)
        panel.contentView?.addSubview(ok)

        var shouldReveal = false
        reveal.target = nil
        reveal.action = nil

        let capturedURL = url
        reveal.target = NSApp
        reveal.action = #selector(NSApplication.stopModal(withCode:))

        // Use a custom approach: reveal button stops modal with code 100
        class RevealHelper: NSObject {
            var action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action }
            @objc func clicked() { action() }
        }
        let helper = RevealHelper {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 100))
        }
        reveal.target = helper
        reveal.action = #selector(RevealHelper.clicked)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        if response.rawValue == 100 {
            NSWorkspace.shared.activateFileViewerSelecting([capturedURL])
        }
    }
}
