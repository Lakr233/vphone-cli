import AppKit

enum VPhoneLocalization {
    static let bundle: Bundle = {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let bundleURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: bundleURL) ?? .main
    }()

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }

    static func installedMessage(for fileName: String, detail: String) -> String {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return format("Installed %@.", fileName)
        }
        if detail.localizedCaseInsensitiveContains(fileName) {
            return detail
        }
        return format("Installed %@.\n\n%@", fileName, detail)
    }

    static func menu(_ menu: NSMenu) {
        menu.title = text(menu.title)
        for item in menu.items {
            item.title = text(item.title)
            if let submenu = item.submenu {
                self.menu(submenu)
            }
        }
    }
}
