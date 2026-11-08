extension Installer {
    static func stepB(layout: String) {
        Installer.setProgress(["phase": "failed", "layout": layout, "error": "boom", "downloaded_bytes": 0])
    }
}
