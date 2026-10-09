import SwiftUI

// MARK: - Snapshots

/// One machine's disk snapshots, from `vm snapshot list --json`, with Take,
/// Revert and Delete. The list can be read while the machine runs; the
/// actions wait for it to stop, since the disk, SEP storage and NVRAM are
/// copied or replaced together. The sheet reports its own errors.
struct VPhoneLaunchpadSnapshotsView: View {
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil until the first list answers.
    @State private var snapshots: [VPhoneLaunchpadMachineSnapshot]?
    @State private var listError: String?
    @State private var selection: Set<VPhoneLaunchpadMachineSnapshot.ID> = []
    /// Empty keeps the order `vm snapshot list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadMachineSnapshot>] = []
    @State private var takesSnapshot = false
    @State private var reversion: VPhoneLaunchpadMachineSnapshot?
    /// The snapshots the delete confirmation is for; empty when it is closed.
    @State private var deletion: [VPhoneLaunchpadMachineSnapshot] = []
    @State private var actionError: VPhoneLaunchpadError?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var state: VPhoneLaunchpadMachineLibrary.RunState {
        library.state(of: machine)
    }

    private var isStopped: Bool {
        state == .stopped
    }

    private var selected: [VPhoneLaunchpadMachineSnapshot] {
        (snapshots ?? []).filter { selection.contains($0.id) }
    }

    /// Revert takes exactly one.
    private var single: VPhoneLaunchpadMachineSnapshot? {
        selected.count == 1 ? selected[0] : nil
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("\(machine.name) Snapshots")) {
            VStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !isStopped {
                    Divider()
                    status
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        } accessory: {
            Button("Take Snapshot…") { takesSnapshot = true }
                .disabled(!isStopped || snapshots == nil)
                .help("Save the machine's disk, SEP storage and NVRAM as they are now.")
            Button("Revert…") { reversion = single }
                .disabled(!isStopped || single == nil)
            Button("Delete…") { deletion = selected }
                .disabled(!isStopped || selected.isEmpty)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 420)
        .task { await reload() }
        .sheet(isPresented: $takesSnapshot) {
            VPhoneLaunchpadTakeSnapshotSheet(
                machine: machine,
                taken: Set((snapshots ?? []).map(\.name)),
            ) { name, note in
                run { try await library.createSnapshot(of: machine, name: name, note: note) }
                selection = [name]
            }
        }
        .confirmationDialog(
            "Revert \(machine.name) to “\(reversion?.name ?? "")”?",
            isPresented: Binding(get: { reversion != nil }, set: {
                if !$0 {
                    reversion = nil
                }
            }),
            presenting: reversion,
        ) { snapshot in
            Button("Revert", role: .destructive) {
                run { try await library.revertSnapshot(of: machine, to: snapshot.name) }
            }
        } message: { _ in
            Text("The machine's current disk, SEP storage and NVRAM are replaced with the snapshot's. Anything changed since then is lost unless you take a snapshot first.")
        }
        .confirmationDialog(
            deletion.count == 1 ? Text("Delete Snapshot “\(deletion[0].name)”?") : Text("Delete \(deletion.count) Snapshots?"),
            isPresented: Binding(get: { !deletion.isEmpty }, set: {
                if !$0 {
                    deletion = []
                }
            }),
            presenting: deletion,
        ) { snapshots in
            Button("Delete", role: .destructive) {
                run {
                    for snapshot in snapshots {
                        try await library.deleteSnapshot(of: machine, name: snapshot.name)
                    }
                }
            }
        } message: { snapshots in
            if snapshots.count == 1 {
                Text("The snapshot's files are removed. The machine itself is not changed. This cannot be undone.")
            } else {
                Text("Their files are removed. The machine itself is not changed. This cannot be undone.")
            }
        }
        .errorAlert($actionError)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if let snapshots {
            if snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No Snapshots", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Take a snapshot before you change the guest, so you can put it back later. A snapshot keeps the disk, SEP storage and NVRAM; settings and the Core Bundle are not part of it.")
                }
            } else {
                table(snapshots)
            }
        } else if let listError {
            ContentUnavailableView {
                Label("Unable to List Snapshots", systemImage: "exclamationmark.triangle")
            } description: {
                Text(listError)
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func table(_ snapshots: [VPhoneLaunchpadMachineSnapshot]) -> some View {
        Table(snapshots.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { snapshot in
                Text(verbatim: snapshot.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.name)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("Date Created", value: \.created) { snapshot in
                Text(snapshot.created.formatted(date: .abbreviated, time: .shortened))
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 170)
            TableColumn("Note", value: \.noteOrder) { snapshot in
                Text(verbatim: snapshot.note ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(snapshot.note ?? "")
            }
        }
        .contextMenu(forSelectionType: VPhoneLaunchpadMachineSnapshot.ID.self) { names in
            let chosen = snapshots.filter { names.contains($0.id) }
            Button("Revert…") { reversion = chosen.first }
                .disabled(!isStopped || chosen.count != 1)
            Button("Delete…", role: .destructive) { deletion = chosen }
                .disabled(!isStopped || chosen.isEmpty)
        }
        .onDeleteCommand {
            if isStopped, !selected.isEmpty {
                deletion = selected
            }
        }
        .vphoneFocusedOnAppear()
    }

    /// What the actions are waiting for: the command under way, or the
    /// machine to stop.
    @ViewBuilder
    private var status: some View {
        switch state {
        case let .busy(activity):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(activity)
            }
        case .running:
            Label("Stop the machine to take, revert to or delete a snapshot.", systemImage: "info.circle")
        case .stopped:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func reload() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                snapshots = VPhoneLaunchpadPreview.snapshots
                selection = Set(snapshots?.last.map { [$0.id] } ?? [])
                return
            }
        #endif
        do {
            let loaded = try await library.snapshots(of: machine)
            snapshots = loaded
            listError = nil
            selection.formIntersection(loaded.map(\.id))
        } catch {
            listError = VPhoneLaunchpadError.message(for: error)
        }
    }

    /// Runs one snapshot command, then reads the list again whatever it did.
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch is CancellationError {
            } catch {
                actionError = VPhoneLaunchpadError(actionFailure: error)
            }
            await reload()
        }
    }
}

// MARK: - Take Snapshot

/// A name for the new snapshot, by default the date and time, and an
/// optional note. Names follow the machine name rules.
struct VPhoneLaunchpadTakeSnapshotSheet: View {
    let machine: VPhoneLaunchpadMachinePath
    /// The names already used, which a new snapshot cannot take.
    let taken: Set<String>
    let onConfirm: (_ name: String, _ note: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""

    private var isTaken: Bool {
        taken.contains(name)
    }

    private var isValid: Bool {
        VPhoneLaunchpadNames.isValidMachineName(name) && !isTaken
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Take Snapshot of \(machine.name)")) {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    if isTaken {
                        Text("A snapshot with this name already exists.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Use letters, numbers, periods, hyphens, and underscores.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(2 ... 4)
                } footer: {
                    Text("The snapshot keeps the machine's disk, SEP storage and NVRAM as they are now. Its settings and Core Bundle are not part of it.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Take Snapshot") {
                onConfirm(name, note)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = VPhoneLaunchpadMachineSnapshot.defaultName(at: Date(), taken: taken) }
    }
}

extension VPhoneLaunchpadMachineSnapshot {
    /// The Note column's order: snapshots without one first.
    var noteOrder: String {
        note ?? ""
    }
}
