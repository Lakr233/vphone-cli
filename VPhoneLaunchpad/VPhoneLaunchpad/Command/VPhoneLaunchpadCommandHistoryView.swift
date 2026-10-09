import AppKit
import SwiftUI

/// The commands Launchpad ran, newest first, in a sheet.
struct VPhoneLaunchpadCommandHistoryView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    /// Newest first until a header click replaces it.
    @State private var sortOrder = [KeyPathComparator(\VPhoneLaunchpadCommandHistory.Entry.date, order: .reverse)]

    private var entries: [VPhoneLaunchpadCommandHistory.Entry] {
        model.history.entries.sorted(using: sortOrder)
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Recent Commands"), width: VPhoneLaunchpadSheetSize.wide) {
            if entries.isEmpty {
                ContentUnavailableView("Commands that Launchpad runs appear here.", systemImage: "terminal")
            } else {
                table
            }
        } accessory: {
            Button("Copy") { copy(selection) }
                .disabled(selection.isEmpty)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 460)
    }

    /// The icon and time keep fixed widths, so the command gets the rest.
    private var table: some View {
        Table(entries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.statusOrder) { entry in
                VPhoneLaunchpadStatusIcon(status: entry.status.map { $0 == 0 ? .passed : .failed } ?? .running)
                    .help(entry.status.map { String(localized: "Exit status \($0)") } ?? "")
            }
            .width(16)
            TableColumn("Started", value: \.date) { entry in
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
            }
            .width(64)
            TableColumn("Command", value: \.text) { entry in
                Text(verbatim: entry.text)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.text)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Copy Command") { copy(ids) }
                .disabled(ids.isEmpty)
        }
        .onCopyCommand {
            let text = commands(selection)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        .vphoneFocusedOnAppear()
    }

    /// The selected commands, one per line, in the order the table shows them.
    private func commands(_ ids: Set<UUID>) -> String {
        entries.filter { ids.contains($0.id) }.map(\.text).joined(separator: "\n")
    }

    private func copy(_ ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands(ids), forType: .string)
    }
}

extension VPhoneLaunchpadCommandHistory.Entry {
    /// The status column's order: running, then succeeded, then failed by
    /// exit status.
    var statusOrder: Int {
        status.map { Int($0) } ?? -1
    }
}
