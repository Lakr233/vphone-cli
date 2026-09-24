import AppKit
import SwiftUI

@MainActor
class VPhoneKeychainWindowController: NSObject, NSToolbarDelegate {
    private nonisolated static let classItemID = NSToolbarItem.Identifier("keychain-class")
    private nonisolated static let searchItemID = NSToolbarItem.Identifier("keychain-search")
    private nonisolated static let actionsItemID = NSToolbarItem.Identifier("keychain-actions")

    private var window: NSWindow?
    private var model: VPhoneKeychainBrowserModel?
    private var searchItem: NSSearchToolbarItem?

    var isKeyWindow: Bool { window?.isKeyWindow == true }

    func showWindow(control: VPhoneGuestControl) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = VPhoneKeychainBrowserModel(control: control)
        let view = VPhoneKeychainBrowserView(model: model)
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "Keychain"
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 700, height: 300)
        window.center()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.level = .normal

        let toolbar = NSToolbar(identifier: "vphone-keychain-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                self?.model = nil
                self?.searchItem = nil
            }
        }
    }

    func focusSearch() {
        searchItem?.beginSearchInteraction()
    }

    // MARK: - Toolbar

    nonisolated func toolbar(
        _: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool,
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            switch identifier {
            case Self.classItemID: makeClassItem()
            case Self.searchItemID: makeSearchItem()
            case Self.actionsItemID: makeActionsItem()
            default: nil
            }
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.classItemID, .flexibleSpace, Self.searchItemID, Self.actionsItemID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.classItemID, Self.searchItemID, Self.actionsItemID, .flexibleSpace, .space]
    }

    private func makeClassItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.classItemID)
        item.label = "Item Type"
        item.toolTip = "Filter keychain items by type"
        item.visibilityPriority = .high

        let labels = VPhoneKeychainBrowserModel.classFilters.map(\.label)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: self,
            action: #selector(classChanged(_:)),
        )
        control.selectedSegment = 0
        control.frame.size = NSSize(width: 420, height: 28)
        item.view = control
        return item
    }

    private func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: Self.searchItemID)
        item.label = "Search Keychain"
        item.visibilityPriority = .high
        item.preferredWidthForSearchField = 190

        let field = NSSearchField()
        field.placeholderString = "Search Keychain"
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchChanged(_:))
        item.searchField = field
        searchItem = item
        return item
    }

    private func makeActionsItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: Self.actionsItemID)
        item.label = "Actions"
        item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")

        let menu = NSMenu(title: "Keychain Actions")
        menu.addItem(actionItem("Refresh", action: #selector(refresh)))
        menu.addItem(actionItem("Copy Selected Rows", action: #selector(copySelectedRows)))
        menu.addItem(actionItem("Show Diagnostics", action: #selector(toggleDiagnostics)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Add Test Item", action: #selector(addTestItem)))
        menu.addItem(actionItem("Remove Test Item", action: #selector(removeTestItem)))
        item.menu = menu
        return item
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func classChanged(_ sender: NSSegmentedControl) {
        guard VPhoneKeychainBrowserModel.classFilters.indices.contains(sender.selectedSegment) else { return }
        model?.filterClass = VPhoneKeychainBrowserModel.classFilters[sender.selectedSegment].value
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model?.searchText = sender.stringValue
    }

    @objc private func refresh() {
        guard let model else { return }
        Task { await model.refresh() }
    }

    @objc private func copySelectedRows() {
        guard let model else { return }
        model.copyRows(ids: model.selection)
    }

    @objc private func toggleDiagnostics() {
        model?.showDiagnostics.toggle()
    }

    @objc private func addTestItem() {
        guard let model else { return }
        Task { await model.addTestItem() }
    }

    @objc private func removeTestItem() {
        guard let model else { return }
        Task { await model.removeTestItem() }
    }
}
