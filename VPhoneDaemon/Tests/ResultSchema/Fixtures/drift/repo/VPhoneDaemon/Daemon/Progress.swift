enum Installer {
    private static var progress: [String: Any] = ["phase": "idle"]

    static func setProgress(_ value: [String: Any]) {
        progress = value
    }

    static func begin(layout: String) {
        setProgress(["phase": "preparing", "layout": layout])
    }

    static func tagged(layout: String) {
        setProgress(["phase": "tagged", "layout": layout, "tag": "t"])
    }
}
