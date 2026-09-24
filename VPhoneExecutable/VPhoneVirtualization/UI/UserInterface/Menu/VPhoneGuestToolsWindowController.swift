import AppKit
import SwiftUI

enum VPhoneGuestToolPage: String, CaseIterable, Identifiable {
    case getClipboard
    case setClipboard
    case readSetting
    case writeSetting

    var id: Self { self }

    var title: String {
        switch self {
        case .getClipboard: "Get Clipboard"
        case .setClipboard: "Set Clipboard Text"
        case .readSetting: "Read Setting"
        case .writeSetting: "Write Setting"
        }
    }

    var symbol: String {
        switch self {
        case .getClipboard: "doc.on.clipboard"
        case .setClipboard: "square.and.pencil"
        case .readSetting: "list.bullet.rectangle"
        case .writeSetting: "slider.horizontal.3"
        }
    }
}

@MainActor
final class VPhoneGuestToolsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: VPhoneGuestToolsModel

    init(control: VPhoneGuestControl) {
        model = VPhoneGuestToolsModel(control: control)
        super.init()
    }

    func show(_ page: VPhoneGuestToolPage) {
        model.page = page

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false,
            )
            window.title = "Guest Tools"
            window.subtitle = "Clipboard & Settings"
            window.contentViewController = NSHostingController(rootView: VPhoneGuestToolsView(model: model))
            window.contentMinSize = NSSize(width: 680, height: 440)
            window.setContentSize(NSSize(width: 840, height: 560))
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if page == .getClipboard {
            Task { await model.refreshClipboard() }
        }
    }

    nonisolated func windowWillClose(_: Notification) {
        MainActor.assumeIsolated { window = nil }
    }
}

@MainActor
@Observable
final class VPhoneGuestToolsModel {
    enum ValueType: String, CaseIterable, Identifiable {
        case string
        case bool
        case int
        case float

        var id: Self { self }

        var title: String {
            switch self {
            case .string: "String"
            case .bool: "Boolean"
            case .int: "Integer"
            case .float: "Float"
            }
        }
    }

    let control: VPhoneGuestControl
    var page: VPhoneGuestToolPage = .getClipboard
    var isBusy = false
    var clipboardText: String?
    var clipboardTypes: [String] = []
    var clipboardHasImage = false
    var clipboardImageData: Data?
    var clipboardChangeCount = 0
    var hasClipboardResult = false
    var clipboardInput = ""
    var readDomain = ""
    var readKey = ""
    var settingResult: String?
    var writeDomain = ""
    var writeKey = ""
    var writeType: ValueType = .string
    var writeValue = ""
    var status: String?
    var isError = false

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    func refreshClipboard() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = nil
        do {
            let content = try await control.clipboardGet()
            clipboardText = content.text
            clipboardTypes = content.types
            clipboardHasImage = content.hasImage
            clipboardImageData = content.imageData
            clipboardChangeCount = content.changeCount
            hasClipboardResult = true
        } catch {
            showError("Unable to read the guest clipboard. Check the connection and try again.")
        }
    }

    func setClipboard() async {
        guard !clipboardInput.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await control.clipboardSet(text: clipboardInput)
            showSuccess("Text set on the guest clipboard.")
        } catch {
            showError("Unable to set the guest clipboard. Check the connection and try again.")
        }
    }

    func readSetting() async {
        let domain = readDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = readKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = nil
        settingResult = nil
        do {
            let value = try await control.settingsGet(domain: domain, key: key.isEmpty ? nil : key)
            if let value, JSONSerialization.isValidJSONObject(value) {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                settingResult = String(data: data, encoding: .utf8) ?? String(describing: value)
            } else {
                settingResult = value.map { String(describing: $0) } ?? "Not set"
            }
            showSuccess("Read \(domain)\(key.isEmpty ? "" : ".\(key)").")
        } catch {
            showError("Unable to read that setting. Check the domain and key, then try again.")
        }
    }

    func writeSetting() async {
        let domain = writeDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = writeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy else { return }
        guard !domain.isEmpty, !key.isEmpty else {
            showError("Enter a domain and key.")
            return
        }

        let rawValue = writeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any
        switch writeType {
        case .string:
            value = writeValue
        case .bool:
            switch rawValue.lowercased() {
            case "true", "yes", "1": value = true
            case "false", "no", "0": value = false
            default:
                showError("Enter true or false for a Boolean value.")
                return
            }
        case .int:
            guard let number = Int64(rawValue) else {
                showError("Enter a valid integer.")
                return
            }
            value = number
        case .float:
            guard let number = Double(rawValue), number.isFinite else {
                showError("Enter a finite number.")
                return
            }
            value = number
        }

        isBusy = true
        defer { isBusy = false }
        do {
            try await control.settingsSet(domain: domain, key: key, value: value, type: writeType.rawValue)
            showSuccess("Wrote \(domain).\(key).")
        } catch {
            showError("Unable to write that setting. Check the connection and try again.")
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showSuccess("Copied to the Mac clipboard.")
    }

    func copyImage() {
        guard let clipboardImageData, let image = NSImage(data: clipboardImageData) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showSuccess("Image copied to the Mac clipboard.")
    }

    private func showSuccess(_ message: String) {
        status = message
        isError = false
    }

    private func showError(_ message: String) {
        status = message
        isError = true
    }
}

struct VPhoneGuestToolsView: View {
    @Bindable var model: VPhoneGuestToolsModel
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case clipboardInput
        case readDomain
        case writeDomain
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                header
                pageContent
                Spacer(minLength: 0)
                if let status = model.status {
                    Label(status, systemImage: model.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(model.isError ? .orange : .green)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: focusCurrentPage)
        .onChange(of: model.page) { _, _ in
            model.status = nil
            focusCurrentPage()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GUEST TOOLS")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ForEach(VPhoneGuestToolPage.allCases) { page in
                Button {
                    model.page = page
                    if page == .getClipboard, !model.hasClipboardResult {
                        Task { await model.refreshClipboard() }
                    }
                } label: {
                    Label(page.title, systemImage: page.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(model.page == page ? Color.accentColor.opacity(0.18) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.page.title)
                .font(.system(size: 22, weight: .semibold))
            Text(pageDescription)
                .foregroundStyle(.secondary)
        }
    }

    private var pageDescription: String {
        switch model.page {
        case .getClipboard: "Inspect the guest clipboard and copy its text to your Mac."
        case .setClipboard: "Send text from your Mac to the guest clipboard."
        case .readSetting: "Read one preference key, or leave the key empty to read all keys in the domain."
        case .writeSetting: "Write a typed value to a guest preference key."
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .getClipboard: clipboardReadPage
        case .setClipboard: clipboardWritePage
        case .readSetting: settingReadPage
        case .writeSetting: settingWritePage
        }
    }

    private var clipboardReadPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Refresh") { Task { await model.refreshClipboard() } }
                    .disabled(model.isBusy)
                Spacer()
                Button("Copy Text") { model.copy(model.clipboardText ?? "") }
                    .disabled(model.clipboardText == nil)
                Button("Copy Image") { model.copyImage() }
                    .disabled(model.clipboardImageData == nil)
            }
            if model.hasClipboardResult {
                HStack(spacing: 24) {
                    metadata("Types", model.clipboardTypes.isEmpty ? "None" : model.clipboardTypes.joined(separator: ", "))
                    metadata("Image", model.clipboardHasImage ? "Present" : "None")
                    metadata("Change Count", String(model.clipboardChangeCount))
                }
                resultBox(model.clipboardText ?? "No text in the guest clipboard. Copy text in the guest, then refresh.")
                if let data = model.clipboardImageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .accessibilityLabel("Guest clipboard image")
                }
            } else if model.isBusy {
                ProgressView("Reading guest clipboard…")
            } else {
                Text("Choose Refresh to read the guest clipboard.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clipboardWritePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text")
                .font(.headline)
            TextEditor(text: $model.clipboardInput)
                .font(.system(.body, design: .monospaced))
                .focused($focusedField, equals: .clipboardInput)
                .frame(minHeight: 180)
                .accessibilityLabel("Text for guest clipboard")
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Text("Characters: \(model.clipboardInput.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set Clipboard Text") { Task { await model.setClipboard() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.clipboardInput.isEmpty || model.isBusy)
            }
        }
    }

    private var settingReadPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                field("Domain", text: $model.readDomain, prompt: "com.apple.springboard")
                    .focused($focusedField, equals: .readDomain)
                field("Key (Optional)", text: $model.readKey, prompt: "Leave empty for all keys")
            }
            HStack {
                Button("Read Setting") { Task { await model.readSetting() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.readDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Spacer()
                if let result = model.settingResult {
                    Button("Copy Result") { model.copy(result) }
                }
            }
            if let result = model.settingResult {
                resultBox(result)
            } else {
                Text("Enter a domain and choose Read Setting.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingWritePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                field("Domain", text: $model.writeDomain, prompt: "com.apple.springboard")
                    .focused($focusedField, equals: .writeDomain)
                field("Key", text: $model.writeKey, prompt: "Preference key")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type").font(.headline)
                    Picker("Type", selection: $model.writeType) {
                        ForEach(VPhoneGuestToolsModel.ValueType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 150)
                field("Value", text: $model.writeValue, prompt: valuePrompt)
            }
            Text("Boolean accepts true or false. Numeric values use decimal notation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Write Setting") { Task { await model.writeSetting() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.writeDomain.isEmpty || model.writeKey.isEmpty || model.isBusy)
            }
        }
    }

    private var valuePrompt: String {
        switch model.writeType {
        case .string: "Text"
        case .bool: "true or false"
        case .int: "42"
        case .float: "3.14"
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultBox(_ result: String) -> some View {
        ScrollView {
            Text(result)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .accessibilityLabel("Result")
    }

    private func focusCurrentPage() {
        switch model.page {
        case .getClipboard: focusedField = nil
        case .setClipboard: focusedField = .clipboardInput
        case .readSetting: focusedField = .readDomain
        case .writeSetting: focusedField = .writeDomain
        }
    }
}
