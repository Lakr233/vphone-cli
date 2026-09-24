import AppKit
@preconcurrency import Quartz

@MainActor
final class VPhoneQuickLookController: NSResponder, QLPreviewPanelDataSource {

    private var tempDir: URL?
    private(set) var previewURL: URL?

    // MARK: - Public API

    func open(data: Data, filename: String) {
        cleanupTempFiles()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[ql] failed to create temp dir: \(error)")
            return
        }
        let fileURL = dir.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
        } catch {
            print("[ql] failed to write temp file: \(error)")
            try? FileManager.default.removeItem(at: dir)
            return
        }
        tempDir = dir
        previewURL = fileURL

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard previewURL != nil else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
        // cleanupTempFiles() is called by endPreviewPanelControl after orderOut.
    }

    // MARK: - QLPreviewPanelDataSource
    // AppKit calls these on the main thread.

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL != nil ? 1 : 0 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (previewURL ?? URL(fileURLWithPath: "/dev/null")) as NSURL }
    }

    // MARK: - QLPreviewPanelController
    // AppKit calls these when walking the responder chain.

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        // Called on main thread; synchronous return required.
        MainActor.assumeIsolated { previewURL != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // `open()` already sets panel.dataSource synchronously before showing the panel.
        // Nothing to do here; the conformance method must exist for QLPreviewPanelController.
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        Task { @MainActor in
            cleanupTempFiles()
        }
    }

    // MARK: - Private

    private func cleanupTempFiles() {
        previewURL = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
    }
}
