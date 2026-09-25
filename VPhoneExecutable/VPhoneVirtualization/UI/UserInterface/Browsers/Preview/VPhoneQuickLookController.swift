import AppKit
@preconcurrency import Quartz
import VPhoneCoreKit

@MainActor
final class VPhoneQuickLookController: NSResponder, QLPreviewPanelDataSource {
    private var tempDir: URL?
    private(set) var previewURL: URL?

    // MARK: - Public API

    func open(data: Data, filename: String) {
        cleanupTempFiles()

        // A fresh private directory; the guest's name is created in it
        // exclusively and never through a link.
        let directory: VPhoneHostDownloadDirectory
        do {
            directory = try VPhoneHostDownloadDirectory.makeTemporary()
        } catch {
            print("[ql] failed to create temp dir: \(error)")
            return
        }
        let dir = directory.url
        let fileURL: URL
        do {
            fileURL = try directory.writeNewFile(named: filename, data: data)
        } catch {
            print("[ql] failed to write temp file: \(error)")
            try? FileManager.default.removeItem(at: dir)
            return
        }
        VPhoneHostDownloadDirectory.markQuarantined(fileURL)
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

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL != nil ? 1 : 0 }
    }

    nonisolated func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (previewURL ?? URL(fileURLWithPath: "/dev/null")) as NSURL }
    }

    // MARK: - QLPreviewPanelController

    // AppKit calls these when walking the responder chain.

    override nonisolated func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        // Called on main thread; synchronous return required.
        MainActor.assumeIsolated { previewURL != nil }
    }

    override nonisolated func beginPreviewPanelControl(_: QLPreviewPanel!) {
        // `open()` already sets panel.dataSource synchronously before showing the panel.
        // Nothing to do here; the conformance method must exist for QLPreviewPanelController.
    }

    override nonisolated func endPreviewPanelControl(_: QLPreviewPanel!) {
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
