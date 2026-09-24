import SwiftUI

struct VPhoneGuestClipboardView: View {
    @Bindable var model: VPhoneGuestClipboardModel
    @FocusState private var composeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.mode {
                case .read: readPane
                case .write: writePane
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
            VPhoneGuestToolShortcut(key: "r", isEnabled: model.mode == .read && !model.isBusy) {
                Task { await model.refresh() }
            },
            VPhoneGuestToolShortcut(key: .return, isEnabled: model.mode == .write && model.canSend) {
                Task { await model.send() }
            },
        ])
        .onAppear(perform: applyFocusRequest)
        .onChange(of: model.focusComposeRequested) { _, _ in applyFocusRequest() }
        .onChange(of: model.mode) { _, mode in
            if mode == .read, model.clipboard == nil {
                Task { await model.refresh() }
            } else if mode == .write {
                composeFocused = true
            }
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
                Button("Copy Text", systemImage: "doc.on.doc") { model.copyTextToMac() }
                    .help("Copy the guest text to the Mac clipboard")
                    .disabled(!model.canCopyText)
                Button("Copy Image", systemImage: "photo.on.rectangle") { model.copyImageToMac() }
                    .help("Copy the guest image to the Mac clipboard")
                    .disabled(!model.canCopyImage)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .help("Read the guest clipboard again (⌘R)")
                    .disabled(model.isBusy)
            }
        case .write:
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Paste from Mac", systemImage: "doc.on.clipboard") { model.pasteFromMac() }
                    .help("Replace the text below with the Mac clipboard text")
                Button("Send", systemImage: "paperplane") { Task { await model.send() } }
                    .help("Set the guest clipboard to this text (⌘↩)")
                    .disabled(!model.canSend)
            }
        }
    }

    // MARK: - Read

    @ViewBuilder
    private var readPane: some View {
        if let clipboard = model.clipboard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 24) {
                    VPhoneGuestToolsField(title: "Change Count", value: String(clipboard.changeCount))
                    VPhoneGuestToolsField(
                        title: "Read At",
                        value: model.readDate?.formatted(date: .omitted, time: .standard) ?? "—",
                    )
                    VPhoneGuestToolsField(
                        title: "Types",
                        value: clipboard.types.isEmpty ? String(localized: "None", bundle: VPhoneLocalization.bundle) : clipboard.types.joined(separator: ", "),
                    )
                }
                content(clipboard)
            }
        } else if model.activity == .reading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Clipboard Not Read", systemImage: "doc.on.clipboard")
            } description: {
                Text("Choose Refresh to read the guest clipboard's text, image and types.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ clipboard: VPhoneGuestControl.ClipboardContent) -> some View {
        let image = clipboard.imageData.flatMap(NSImage.init(data:))
        if clipboard.text == nil, image == nil {
            ContentUnavailableView(
                "Clipboard Empty",
                systemImage: "clipboard",
                description: Text("The guest clipboard holds no text or image. Copy something in the guest, then refresh."),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 12) {
                if let text = clipboard.text {
                    ScrollView {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Guest clipboard text")
                }
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: clipboard.text == nil ? .infinity : 220, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                        .accessibilityLabel("Guest clipboard image")
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Write

    private var writePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.composeText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .focused($composeFocused)
                .accessibilityLabel("Text to send to the guest clipboard")

            Text(
                model.composeText.count == 1
                    ? String(localized: "1 character", bundle: VPhoneLocalization.bundle)
                    : String(localized: "\(model.composeText.count) characters", bundle: VPhoneLocalization.bundle),
            )
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private func applyFocusRequest() {
        guard model.focusComposeRequested else { return }
        composeFocused = true
        model.focusComposeRequested = false
    }
}
