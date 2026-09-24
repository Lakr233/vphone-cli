import AppKit
import SwiftUI

@MainActor
class VPhoneAppWindowController: NSObject, NSToolbarDelegate {
    private nonisolated static let filterItemID = NSToolbarItem.Identifier("apps-filter")
    private nonisolated static let searchItemID = NSToolbarItem.Identifier("apps-search")
    private nonisolated static let refreshItemID = NSToolbarItem.Identifier("apps-refresh")

    private var window: NSWindow?
    private var model: VPhoneAppBrowserModel?
    private var searchItem: NSSearchToolbarItem?

    var isKeyWindow: Bool {
        window?.isKeyWindow == true
    }

    func showWindow(control: VPhoneGuestControl) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = VPhoneAppBrowserModel(control: control)
        let view = VPhoneAppBrowserView(model: model)
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = VPhoneLocalization.text("Apps")
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 700, height: 300)
        window.center()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.level = .normal

        let toolbar = NSToolbar(identifier: "vphone-apps-toolbar")
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
            case Self.filterItemID: makeFilterItem()
            case Self.searchItemID: makeSearchItem()
            case Self.refreshItemID: makeRefreshItem()
            default: nil
            }
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.filterItemID, .flexibleSpace, Self.searchItemID, Self.refreshItemID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.filterItemID, Self.searchItemID, Self.refreshItemID, .flexibleSpace, .space]
    }

    private func makeFilterItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.filterItemID)
        item.label = VPhoneLocalization.text("App Type")
        item.toolTip = VPhoneLocalization.text("Filter apps by type")
        item.visibilityPriority = .high

        let labels = ["All", "Running", "User", "System"].map(VPhoneLocalization.text)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: self,
            action: #selector(filterChanged(_:)),
        )
        control.selectedSegment = 0
        control.frame.size = NSSize(width: 320, height: 28)
        item.view = control
        return item
    }

    private func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: Self.searchItemID)
        item.label = VPhoneLocalization.text("Search Apps")
        item.visibilityPriority = .high
        item.preferredWidthForSearchField = 220

        let field = NSSearchField()
        field.placeholderString = VPhoneLocalization.text("Search Apps")
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchChanged(_:))
        item.searchField = field
        searchItem = item
        return item
    }

    private func makeRefreshItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.refreshItemID)
        item.label = VPhoneLocalization.text("Refresh")
        item.toolTip = VPhoneLocalization.text("Refresh app list")
        item.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: VPhoneLocalization.text("Refresh"),
        )
        item.target = self
        item.action = #selector(refresh)
        return item
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        let filters = VPhoneAppBrowserModel.AppFilter.allCases
        guard filters.indices.contains(sender.selectedSegment), let model else { return }
        model.filter = filters[sender.selectedSegment]
        Task { await model.refresh() }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model?.searchText = sender.stringValue
    }

    @objc private func refresh() {
        guard let model else { return }
        Task { await model.refresh() }
    }
}
