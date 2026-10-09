import SwiftUI

/// The patch editor: a preset, and a checkmark for every patch the bundle
/// declares. New Machine opens it for a machine that does not exist yet, and
/// the inspector for one that does.
///
/// For an existing machine the choice is read from and saved to that machine
/// (`fw patches <vm>`, `fw set-patches <vm>`) with its own Core Bundle, and
/// the status line says how each change reaches it: guest patches at the next
/// guest environment update, the boot chain only with a restore.
///
/// The list is never a copy of the catalogue — it is whatever
/// `vphone-cli fw patches --json` reports, so a patch set added to the bundle
/// shows up here without a change to Launchpad. Only the boxes that differ from
/// the preset are kept, and switching preset re-bases them, since a difference
/// from the preset that is no longer active means nothing.
struct VPhoneLaunchpadPatchSettingsView: View {
    typealias Catalog = VPhoneLaunchpadPatchCatalog

    /// What the boxes start from.
    let initial: VPhoneLaunchpadPatchSelection
    /// The Core Bundle New Machine creates with; its `vphone-cli` lists the
    /// patches. Nil reads the default version's.
    let bundleVersion: String?
    /// The existing machine being edited, or nil in New Machine.
    let machine: VPhoneLaunchpadMachinePath?
    /// Hands the edited choice back; New Machine holds it until the VM exists,
    /// the inspector saves it to the machine.
    let onSave: (VPhoneLaunchpadPatchSelection) -> Void
    /// The inspector shows a created machine's choice without changing it:
    /// its boot chain was patched when it was restored.
    let isReadOnly: Bool

    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: VPhoneLaunchpadPatchSelection
    @State private var catalog: Catalog?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var filter = ""
    /// Empty keeps the order the bundle applies the patches in; a header click
    /// replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadPatchRow>] = []
    /// The selected rows; the detail pane reads the summary of one.
    @State private var highlighted: Set<String> = []
    @State private var confirmsBootEssential = false
    /// What was on when the editor opened, so the status line can count what
    /// an edit to an existing machine changes. Taken from the first read.
    @State private var initiallyOn: Set<String>?

    init(
        initial: VPhoneLaunchpadPatchSelection,
        bundleVersion: String? = nil,
        machine: VPhoneLaunchpadMachinePath? = nil,
        isReadOnly: Bool = false,
        onSave: @escaping (VPhoneLaunchpadPatchSelection) -> Void,
    ) {
        self.initial = initial
        self.bundleVersion = bundleVersion
        self.machine = machine
        self.isReadOnly = isReadOnly
        self.onSave = onSave
        _selection = State(initialValue: initial)
    }

    private var essentialOff: [Catalog.Patch] {
        catalog.map { selection.bootEssentialOff(in: $0) } ?? []
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Patches"), width: VPhoneLaunchpadSheetSize.wide) {
            VStack(spacing: 0) {
                header
                Divider()
                // A ContentUnavailableView is only as tall as its text; left
                // to that, the stack centers in the sheet and the header
                // drops to the middle.
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                detailPane
            }
        } accessory: {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } actions: {
            if isReadOnly {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(catalog == nil)
            }
        }
        .frame(height: 680)
        // A hidden patch leaves the selection, so the detail pane reads only
        // a row the table shows.
        .onChange(of: filter) {
            if let catalog {
                highlighted.formIntersection(catalog.patches(matching: filter).map(\.identifier))
            }
        }
        .confirmationDialog(
            "Leave ^[\(essentialOff.count) boot-essential patch](inflect: true) off?",
            isPresented: $confirmsBootEssential,
        ) {
            Button("Leave Them Off", role: .destructive) { finish() }
        } message: {
            Text("The machine may not boot without \(essentialOff.map(\.identifier).joined(separator: ", ")).")
        }
        .task { await load(preset: initial.preset) }
    }

    // MARK: - Preset

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Sized to its content, so the label sits against the menu.
                Picker("Preset", selection: presetBinding) {
                    ForEach(catalog?.presets ?? []) { preset in
                        Text(verbatim: preset.displayTitle).tag(preset.identifier)
                    }
                }
                .fixedSize()
                .disabled(catalog == nil || isLoading || isReadOnly)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                VPhoneLaunchpadSearchField(text: $filter, prompt: String(localized: "Filter patches"))
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Switching preset clears both override lists: the checkmarks are read as a
    /// difference from the preset, so a difference from the one just left behind
    /// would silently change meaning.
    private var presetBinding: Binding<String> {
        Binding(
            get: { selection.preset },
            set: { identifier in
                guard identifier != selection.preset else {
                    return
                }
                selection = VPhoneLaunchpadPatchSelection(preset: identifier)
                Task { await load(preset: identifier) }
            },
        )
    }

    // MARK: - Patches

    @ViewBuilder
    private var list: some View {
        if let catalog {
            let rows = catalog.patches(matching: filter)
                .map { VPhoneLaunchpadPatchRow(patch: $0, on: selection.isOn($0) ? 1 : 0) }
                .sorted(using: sortOrder)
            if rows.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                table(rows)
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("No Patch List", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: loadError)
            }
        } else {
            VStack {
                ProgressView()
                Text("Reading the bundle's patches…").foregroundStyle(.secondary)
            }
        }
    }

    /// A flat table sorted by the order the bundle applies the patches, which
    /// already runs one set after another. A header click regroups it; sections
    /// were tried first and make AppKit report a reentrant table delegate.
    private func table(_ rows: [VPhoneLaunchpadPatchRow]) -> some View {
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("On", value: \.on) { row in
                let patch = row.patch
                Toggle("On", isOn: Binding(
                    get: { selection.isOn(patch) },
                    set: { selection.set(patch, on: $0) },
                ))
                .labelsHidden()
                .disabled(isReadOnly)
            }
            .width(36)

            TableColumn("Component", value: \.patch.component) { row in
                let patch = row.patch
                Text(verbatim: patch.component)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Effect", value: \.patch.effect) { row in
                let patch = row.patch
                Text(verbatim: patch.effect)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 40, ideal: 50)

            TableColumn("Name", value: \.patch.name) { row in
                let patch = row.patch
                Text(verbatim: patch.name)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(patch.identifier)
            }
            .width(min: 140, ideal: 220)

            // Most patches are boot-essential, so a mark on each would say
            // nothing. It shows only on one that is off.
            TableColumn("Patch", value: \.patch.title) { row in
                let patch = row.patch
                HStack(spacing: 4) {
                    Text(verbatim: patch.title)
                        .lineLimit(1)
                    if patch.bootEssential, !selection.isOn(patch) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(String(localized: "The machine may not boot without this patch."))
                    }
                }
                .help(patch.summary)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Applies To", value: \.patch.applicability) { row in
                let patch = row.patch
                if patch.isVersionGated {
                    Text(verbatim: patch.applicability).lineLimit(1)
                } else {
                    Text("All").foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Turn On") { set(ids, on: true) }
                .disabled(isReadOnly)
            Button("Turn Off") { set(ids, on: false) }
                .disabled(isReadOnly)
        }
        .vphoneFocusedOnAppear()
    }

    /// Turns each of the patches with these identifiers on or off.
    private func set(_ ids: Set<String>, on: Bool) {
        for patch in catalog?.patches ?? [] where ids.contains(patch.identifier) {
            selection.set(patch, on: on)
        }
    }

    // MARK: - Detail

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !essentialOff.isEmpty {
                Label {
                    Text("^[\(essentialOff.count) boot-essential patch](inflect: true) off: \(essentialOff.map(\.identifier).joined(separator: ", "))")
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
            detail
                .foregroundStyle(.secondary)
        }
        // The footer's font and edges. As tall as the text: the table gives
        // up the room.
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        if highlighted.count == 1, let patch = catalog?.patch(highlighted.first) {
            Text(verbatim: patch.summary)
        } else if highlighted.count > 1 {
            Text("^[\(highlighted.count) patch](inflect: true) selected. Control-click to turn them on or off together.")
        } else {
            Text("Select a patch to see what it changes.")
        }
    }

    /// What is on, what differs from the preset, and when the choice takes effect.
    private var status: String {
        guard let catalog else {
            return ""
        }
        let on = catalog.patches.count(where: { selection.isOn($0) })
        var parts = [String(localized: "\(on) of \(catalog.patches.count) on")]
        if selection.hasOverrides {
            parts.append(String(localized: "\(selection.blocked.count) turned off, \(selection.allowed.count) turned on from the preset"))
        }
        if machine == nil {
            parts.append(String(localized: "Applied when the machine is installed"))
        } else if let initiallyOn {
            let changed = catalog.patches.filter { selection.isOn($0) != initiallyOn.contains($0.identifier) }
            let bootChain = changed.count(where: \.isBootChain)
            let guest = changed.count - bootChain
            if changed.isEmpty {
                parts.append(String(localized: "No change"))
            }
            if guest > 0 {
                parts.append(String(localized: "^[\(guest) guest patch](inflect: true) to apply with a guest environment update"))
            }
            if bootChain > 0 {
                parts.append(String(localized: "^[\(bootChain) boot chain patch](inflect: true) that only a restore applies"))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func load(preset: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try await Catalog.read(
                using: bundleVersion.map(model.bundles.commandLine(version:)) ?? model.bundles.commandLine(),
                machine: machine,
                preset: preset,
            )
            // A second switch of the picker may have overtaken this read.
            guard preset == selection.preset else {
                return
            }
            selection.preset = catalog.activePreset
            selection.normalize(against: catalog)
            if initiallyOn == nil {
                initiallyOn = Set(catalog.patches.filter { selection.isOn($0) }.map(\.identifier))
            }
            self.catalog = catalog
            // The detail pane reserves its space either way, so it starts with
            // something to read rather than a gap.
            if highlighted.isEmpty, let first = catalog.patches.first {
                highlighted = [first.identifier]
            }
            loadError = nil
        } catch {
            loadError = VPhoneLaunchpadError.message(for: error)
        }
    }

    private func commit() {
        if essentialOff.isEmpty {
            finish()
        } else {
            confirmsBootEssential = true
        }
    }

    private func finish() {
        onSave(selection)
        dismiss()
    }
}

/// One row of the patch table: the patch, with whether it is on, so the On
/// column sorts like the others.
struct VPhoneLaunchpadPatchRow: Identifiable {
    let patch: VPhoneLaunchpadPatchCatalog.Patch
    /// 1 when on.
    let on: Int

    var id: String {
        patch.identifier
    }
}
