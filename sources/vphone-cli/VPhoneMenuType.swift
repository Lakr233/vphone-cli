import AppKit

// MARK: - Type Menu

extension VPhoneMenuController {
    func buildTypeMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Type")
        menu.addItem(makeItem("Type ASCII from Clipboard", action: #selector(typeFromClipboard)))
        item.submenu = menu
        return item
    }

    @objc func typeFromClipboard() {
        keyHelper.typeFromClipboard()
    }
}
