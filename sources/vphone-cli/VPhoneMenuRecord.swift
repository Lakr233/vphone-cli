import AppKit

// MARK: - Record Menu

extension VPhoneMenuController {
    func buildRecordMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Record")
        let toggle = makeItem("Start Recording", action: #selector(toggleRecording))
        recordingItem = toggle
        menu.addItem(toggle)
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
            guard let window = NSApp.keyWindow,
                  let view = window.contentView
            else {
                print("[record] no active window")
                return
            }
            do {
                try screenRecorder?.startRecording(view: view)
                recordingItem?.title = "Stop Recording"
            } catch {
                print("[record] failed to start: \(error)")
            }
        }
    }
}
