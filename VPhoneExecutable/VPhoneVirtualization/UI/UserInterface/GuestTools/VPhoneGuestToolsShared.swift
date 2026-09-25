import SwiftUI

// MARK: - Mode

/// The toolbar switch each guest tool window shows.
enum VPhoneGuestToolMode: String, CaseIterable, Identifiable {
    case read
    case write

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .read: String(localized: "Read", bundle: VPhoneLocalization.bundle)
        case .write: String(localized: "Write", bundle: VPhoneLocalization.bundle)
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .read: "1"
        case .write: "2"
        }
    }
}

struct VPhoneGuestToolModePicker: View {
    @Binding var mode: VPhoneGuestToolMode

    var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(VPhoneGuestToolMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between reading from and writing to the guest (⌘1, ⌘2)")
    }
}

// MARK: - Status

struct VPhoneGuestToolStatus {
    let message: String
    let isError: Bool
}

/// The bottom bar shared by the guest windows: connection, activity, result.
struct VPhoneGuestToolStatusBar: View {
    let isConnected: Bool
    let activity: String?
    let status: VPhoneGuestToolStatus?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityLabel(isConnected ? String(localized: "Guest connected", bundle: VPhoneLocalization.bundle) : String(localized: "Guest disconnected", bundle: VPhoneLocalization.bundle))

            if let activity {
                ProgressView()
                    .controlSize(.small)
                Text(activity)
                    .foregroundStyle(.secondary)
            } else if let status {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.isError ? .orange : .green)
                Text(status.message)
                    .foregroundStyle(status.isError ? .primary : .secondary)
                    .textSelection(.enabled)
            } else {
                Text(isConnected ? String(localized: "Connected", bundle: VPhoneLocalization.bundle) : String(localized: "Guest not connected", bundle: VPhoneLocalization.bundle))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Shortcuts

/// A keyboard shortcut for a toolbar action.
struct VPhoneGuestToolShortcut {
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var isEnabled = true
    let action: () -> Void
}

extension View {
    /// Adds keyboard shortcuts for toolbar actions. The buttons are invisible
    /// but stay in the hosting view, where AppKit routes key equivalents.
    func guestToolShortcuts(_ shortcuts: [VPhoneGuestToolShortcut]) -> some View {
        background {
            ForEach(shortcuts.indices, id: \.self) { index in
                let shortcut = shortcuts[index]
                Button(action: shortcut.action) { EmptyView() }
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                    .disabled(!shortcut.isEnabled)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Metadata

/// A small caption label above a value.
struct VPhoneGuestToolsField: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title, bundle: VPhoneLocalization.bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }
}
