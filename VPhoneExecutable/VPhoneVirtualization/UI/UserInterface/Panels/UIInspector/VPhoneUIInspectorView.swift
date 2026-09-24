import SwiftUI

struct VPhoneUIInspectorView: View {
    @Bindable var model: VPhoneUIInspectorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                VPhoneUIInspectorScreenView(model: model)
                    .frame(minWidth: 220, idealWidth: 320, maxWidth: 420, maxHeight: .infinity)
                recordsPane
                    .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.activity?.title,
                status: model.status,
            )
        }
        .toolbar { toolbar }
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isBusy) {
                Task { await model.refresh() }
            },
            VPhoneGuestToolShortcut(key: "t", isEnabled: model.canTapSelected) {
                Task { await model.tapSelected() }
            },
            VPhoneGuestToolShortcut(key: "c", modifiers: [.command, .shift], isEnabled: model.selectedJSON != nil) {
                model.copySelected()
            },
        ])
        .task(id: model.control.isConnected) {
            if model.control.isConnected {
                await model.refresh()
            }
        }
        .onChange(of: model.source) { _, _ in
            if !model.hasLoadedSource {
                Task { await model.reloadSource() }
            }
        }
        .onChange(of: model.visibleOnly) { _, _ in
            Task { await model.reloadSource() }
        }
        .onChange(of: model.clickableOnly) { _, _ in
            Task { await model.reloadSource() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle("Visible Only", systemImage: "eye", isOn: $model.visibleOnly)
                .help("Show only accessibility elements inside the screen")
                .disabled(model.source != .accessibility || model.isBusy || !model.control.isConnected)
            Toggle("Clickable Only", systemImage: "hand.tap", isOn: $model.clickableOnly)
                .help("Show only accessibility elements that accept taps")
                .disabled(model.source != .accessibility || model.isBusy || !model.control.isConnected)
            Button("Tap Selected", systemImage: "hand.point.up.left") {
                Task { await model.tapSelected() }
            }
            .help("Tap the selected element in the guest (⌘T)")
            .disabled(!model.canTapSelected)
            Button("Copy", systemImage: "doc.on.doc") { model.copySelected() }
                .help("Copy the selected element as JSON (⇧⌘C)")
                .disabled(model.selectedJSON == nil)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("Capture the guest screen and reload the elements (⌘R)")
                .disabled(model.isBusy || !model.control.isConnected)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
            if model.appBundleID.isEmpty {
                Text("Frontmost app unknown")
                    .foregroundStyle(.secondary)
            } else {
                Text(model.appName.isEmpty ? model.appBundleID : model.appName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                VPhonePanelMonoText(model.appBundleID, secondary: true)
                if let pid = model.appPID {
                    VPhonePanelMonoText("PID \(pid)", secondary: true)
                        .fixedSize()
                }
            }
            Spacer(minLength: 8)
            if let points = model.pointSize {
                VPhonePanelMonoText(screenText(points), secondary: true)
                    .fixedSize()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func screenText(_ points: CGSize) -> String {
        let size = "\(VPhoneUIInspectorRecord.number(points.width))×\(VPhoneUIInspectorRecord.number(points.height)) pt"
        guard let scale = model.screenScale else { return size }
        return "\(size) @\(VPhoneUIInspectorRecord.number(scale))x"
    }

    // MARK: - Records

    private var recordsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Source", selection: $model.source) {
                    ForEach(VPhoneUIInspectorModel.Source.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Choose accessibility elements or text recognized in the screenshot")
                Spacer(minLength: 8)
                if model.hasLoadedSource {
                    VPhonePanelMonoText(countText, secondary: true)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            records
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VPhoneUIInspectorDetailView(details: model.selectedDetails)
                .frame(height: 148)
        }
    }

    private var countText: String {
        switch model.source {
        case .accessibility:
            model.elementsTruncated
                ? String(localized: "\(model.elements.count)+ elements", bundle: VPhoneLocalization.bundle)
                : String(localized: "\(model.elements.count) elements", bundle: VPhoneLocalization.bundle)
        case .text:
            String(localized: "\(model.textBlocks.count) blocks", bundle: VPhoneLocalization.bundle)
        }
    }

    @ViewBuilder
    private var records: some View {
        switch model.source {
        case .accessibility:
            if !model.elements.isEmpty {
                elementTable
            } else if model.hasLoadedElements {
                VPhonePanelEmptyState(
                    title: "No Elements",
                    systemImage: "rectangle.dashed",
                    message: "The frontmost app reported no accessibility elements. Turn off Visible Only or Clickable Only, or bring another app to the front.",
                )
            } else {
                placeholder
            }
        case .text:
            if !model.textBlocks.isEmpty {
                textTable
            } else if model.hasLoadedText {
                VPhonePanelEmptyState(
                    title: "No Text",
                    systemImage: "text.viewfinder",
                    message: "No text was recognized on the guest screen.",
                )
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isBusy {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.control.isConnected {
            VPhonePanelEmptyState(
                title: "Not Loaded",
                systemImage: "arrow.clockwise",
                message: "Choose Refresh to inspect the guest screen.",
            )
        } else {
            VPhonePanelEmptyState(
                title: "Guest Not Connected",
                systemImage: "bolt.horizontal",
                message: "The inspector loads once vphoned is reachable in the guest.",
            )
        }
    }

    // MARK: - Accessibility Table

    private var elementTable: some View {
        ScrollViewReader { proxy in
            Table(model.sortedElements, selection: $model.selectedElementID, sortOrder: $model.elementSortOrder) {
                TableColumn("Role", value: \.role) { element in
                    VPhonePanelMonoText(element.role)
                }
                .width(min: 52, ideal: 56, max: 90)
                TableColumn("Label", value: \.label) { element in
                    VPhonePanelMonoText(element.label)
                }
                .width(min: 72, ideal: 96)
                TableColumn("Identifier", value: \.identifier) { element in
                    VPhonePanelMonoText(element.identifier, secondary: true)
                }
                .width(min: 56, ideal: 60)
                TableColumn("Value", value: \.value) { element in
                    VPhonePanelMonoText(element.value)
                }
                .width(min: 40, ideal: 44)
                TableColumn("Frame", value: \.frameOrder) { element in
                    VPhonePanelMonoText(element.frameText)
                }
                .width(min: 104, ideal: 106, max: 170)
                TableColumn("Clickable", value: \.clickableOrder) { element in
                    flag(element.isClickable, on: "Clickable", off: "Not clickable")
                }
                .width(min: 56, ideal: 56, max: 72)
                TableColumn("Enabled", value: \.enabledOrder) { element in
                    flag(element.isEnabled, on: "Enabled", off: "Disabled", showsOff: true)
                }
                .width(min: 56, ideal: 56, max: 72)
            }
            .contextMenu(forSelectionType: VPhoneUIInspectorElement.ID.self) { ids in
                if let element = ids.first.flatMap({ id in model.elements.first { $0.id == id } }) {
                    Button("Tap") { Task { await model.tap(at: element.tapPoint) } }
                        .disabled(!model.control.isConnected || model.isBusy)
                    Divider()
                    Button("Copy as JSON") { model.copy(element.json) }
                    Button("Copy Label") { model.copy(element.label) }
                        .disabled(element.label.isEmpty)
                    Button("Copy Identifier") { model.copy(element.identifier) }
                        .disabled(element.identifier.isEmpty)
                    Button("Copy Frame") { model.copy(element.frameText) }
                }
            } primaryAction: { ids in
                if let element = ids.first.flatMap({ id in model.elements.first { $0.id == id } }) {
                    Task { await model.tap(at: element.tapPoint) }
                }
            }
            .onChange(of: model.selectedElementID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func flag(_ value: Bool, on: LocalizedStringKey, off: LocalizedStringKey, showsOff: Bool = false) -> some View {
        Group {
            if value {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            } else if showsOff {
                Image(systemName: "xmark")
                    .foregroundStyle(.orange)
            } else {
                Text(verbatim: "")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(value ? on : off, bundle: VPhoneLocalization.bundle))
    }

    // MARK: - Text Table

    private var textTable: some View {
        ScrollViewReader { proxy in
            Table(model.sortedTextBlocks, selection: $model.selectedTextID, sortOrder: $model.textSortOrder) {
                TableColumn("Text", value: \.text) { block in
                    VPhonePanelMonoText(block.text)
                }
                .width(min: 120, ideal: 220)
                TableColumn("Confidence", value: \.confidence) { block in
                    VPhonePanelMonoText(VPhonePanelFormat.percent(block.confidence), secondary: block.confidence < 0.5)
                }
                .width(min: 84, ideal: 88, max: 110)
                TableColumn("Frame", value: \.frameOrder) { block in
                    VPhonePanelMonoText(block.frameText)
                }
                .width(min: 104, ideal: 120, max: 170)
            }
            .contextMenu(forSelectionType: VPhoneUIInspectorTextBlock.ID.self) { ids in
                if let block = ids.first.flatMap({ id in model.textBlocks.first { $0.id == id } }) {
                    Button("Tap") { Task { await model.tap(at: block.tapPoint) } }
                        .disabled(!model.control.isConnected || model.isBusy)
                    Divider()
                    Button("Copy as JSON") { model.copy(block.json) }
                    Button("Copy Text") { model.copy(block.text) }
                    Button("Copy Frame") { model.copy(block.frameText) }
                }
            } primaryAction: { ids in
                if let block = ids.first.flatMap({ id in model.textBlocks.first { $0.id == id } }) {
                    Task { await model.tap(at: block.tapPoint) }
                }
            }
            .onChange(of: model.selectedTextID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
    }
}
