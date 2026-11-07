extension Installer {
    static func stepA(layout: String, tag: String) {
        setProgress(["phase": "extracting", "layout": layout, "tag": tag])
    }
}
