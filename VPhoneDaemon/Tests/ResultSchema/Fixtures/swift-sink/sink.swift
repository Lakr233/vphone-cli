// A setProgress sink shaped like GuestIrisinInstaller. Parsed only, never compiled.
enum Installer {
    private static var progress: [String: Any] = ["phase": "idle"]

    static func setProgress(_ value: [String: Any]) {
        lock.lock()
        progress = value
        lock.unlock()
    }

    static func downloadProgress(received: Int64, total: Int64) {
        progress["downloaded_bytes"] = received
        if total > 0 {
            progress["total_bytes"] = total
        }
    }

    static func begin(layout: String) {
        setProgress(["phase": "preparing", "layout": layout])
    }
}
