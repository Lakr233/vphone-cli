import SwiftUI

struct VPhoneGuestPreferencesView: View {
    @Bindable var model: VPhoneGuestPreferencesModel
    @FocusState private var focus: VPhoneGuestPreferencesModel.Field?
    @State private var selection: VPhoneGuestPreferenceEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            domainBar
                .padding(12)
            Divider()
            Group {
                switch model.mode {
                case .read: resultPane
                case .write: writeForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.activity?.title,
                status: model.status,
            )
        }
        .toolbar { toolbar }
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "1") { model.mode = .read },
            VPhoneGuestToolShortcut(key: "2") { model.mode = .write },
            VPhoneGuestToolShortcut(key: "r", isEnabled: model.mode == .read && model.canRead) {
                Task { await model.read() }
            },
            VPhoneGuestToolShortcut(key: .return, isEnabled: model.mode == .write && model.canWrite) {
                Task { await model.write() }
            },
        ])
        .onAppear(perform: applyFocusRequest)
        .onChange(of: model.focusRequest) { _, _ in applyFocusRequest() }
        .onChange(of: selection) { _, id in
            // A single click fills the write form; double-click also opens it.
            guard let id, let entry = entry(for: id) else { return }
            model.edit(entry, switchToWrite: false)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VPhoneGuestToolModePicker(mode: $model.mode)
        }

        switch model.mode {
        case .read:
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Result Style", selection: $model.resultStyle) {
                    ForEach(VPhoneGuestPreferencesModel.ResultStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbol).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show the result as an outline or as JSON")
                .disabled(model.readResult == nil)
                Button("Copy JSON", systemImage: "doc.on.doc") { model.copyResult() }
                    .help("Copy the result as JSON")
                    .disabled(!model.canCopyResult)
                Button("Read", systemImage: "arrow.clockwise") { Task { await model.read() } }
                    .help("Read the key, or every key in the domain when Key is empty (⌘R)")
                    .disabled(!model.canRead)
            }
        case .write:
            ToolbarItem(placement: .primaryAction) {
                Button("Write", systemImage: "square.and.arrow.down") { Task { await model.write() } }
                    .help("Write this value to the guest (⌘↩)")
                    .disabled(!model.canWrite)
            }
        }
    }

    // MARK: - Domain

    private var domainBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Domain")
                .foregroundStyle(.secondary)
            TextField("Domain", text: $model.domain, prompt: Text("com.apple.springboard"))
                .focused($focus, equals: .domain)
                .onSubmit(submit)
            Menu {
                ForEach(VPhoneGuestPreferencesModel.suggestedDomains, id: \.self) { domain in
                    Button(domain) { model.domain = domain }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Common preference domains")
            .accessibilityLabel("Common domains")

            if model.mode == .read {
                Text("Key")
                    .foregroundStyle(.secondary)
                TextField("Key", text: $model.readKey, prompt: Text("All keys"))
                    .focused($focus, equals: .readKey)
                    .onSubmit(submit)
                    .frame(maxWidth: 220)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .labelsHidden()
    }

    // MARK: - Read

    @ViewBuilder
    private var resultPane: some View {
        if let result = model.readResult {
            if model.resultStyle == .json || result.entries.isEmpty {
                jsonView(result)
            } else {
                outline(result)
            }
        } else if model.activity == .reading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Preference Read",
                systemImage: "list.bullet.rectangle",
                description: Text("Enter a domain, then choose Read. Leave Key empty to read every key in the domain."),
            )
        }
    }

    private func outline(_ result: VPhoneGuestPreferenceReadResult) -> some View {
        Table(result.entries, children: \.children, selection: $selection) {
            TableColumn("Key") { entry in
                Text(entry.key)
                    .font(.system(.body, design: .monospaced))
                    .help(entry.key)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Type") { entry in
                Text(entry.typeTitle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Value") { entry in
                Text(entry.summary)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(entry.children == nil ? .primary : .secondary)
                    .lineLimit(1)
                    .help(entry.summary)
            }
        }
        .contextMenu(forSelectionType: VPhoneGuestPreferenceEntry.ID.self) { ids in
            if let id = ids.first, let entry = entry(for: id) {
                Button("Edit Value…") { model.edit(entry, switchToWrite: true) }
                    .disabled(!model.canEdit(entry))
                Divider()
                Button("Copy Key") { copy(entry.key) }
                Button("Copy Value") { copy(entry.summary) }
                    .disabled(entry.children != nil)
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = entry(for: id) {
                model.edit(entry, switchToWrite: true)
            }
        }
        .accessibilityLabel("Preference values for \(result.title)")
    }

    private func jsonView(_ result: VPhoneGuestPreferenceReadResult) -> some View {
        ScrollView {
            Text(result.text.isEmpty ? "No value." : result.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(result.text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Preference value for \(result.title)")
    }

    // MARK: - Write

    private var writeForm: some View {
        Form {
            TextField("Key", text: $model.writeKey, prompt: Text("Preference key"))
                .focused($focus, equals: .writeKey)
                .onSubmit(submit)

            Picker("Type", selection: $model.writeType) {
                ForEach(VPhoneGuestPreferenceType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }

            valueField

            if let current = model.currentWriteValue {
                LabeledContent("Current Value") {
                    Text("\(current.summary)  (\(current.typeTitle))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private var valueField: some View {
        if model.writeType == .bool {
            Picker("Value", selection: $model.writeValue) {
                Text("true").tag("true")
                Text("false").tag("false")
            }
            .pickerStyle(.segmented)
            .focused($focus, equals: .value)
            .onAppear {
                if case .failure = model.writeType.parse(model.writeValue) {
                    model.writeValue = "true"
                }
            }
        } else {
            TextField("Value", text: $model.writeValue, prompt: Text(model.writeType.prompt))
                .focused($focus, equals: .value)
                .onSubmit(submit)
        }
    }

    // MARK: - Helpers

    private func submit() {
        switch model.mode {
        case .read: Task { await model.read() }
        case .write: Task { await model.write() }
        }
    }

    private func entry(for id: VPhoneGuestPreferenceEntry.ID) -> VPhoneGuestPreferenceEntry? {
        func find(_ entries: [VPhoneGuestPreferenceEntry]) -> VPhoneGuestPreferenceEntry? {
            for entry in entries {
                if entry.id == id { return entry }
                if let match = entry.children.flatMap(find) { return match }
            }
            return nil
        }
        return model.readResult.flatMap { find($0.entries) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func applyFocusRequest() {
        guard let request = model.focusRequest else { return }
        focus = request
        model.focusRequest = nil
    }
}
