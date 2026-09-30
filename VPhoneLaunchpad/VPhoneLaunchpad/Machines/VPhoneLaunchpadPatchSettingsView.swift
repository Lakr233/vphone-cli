import SwiftUI

/// The patch editor New Machine opens: a preset, and a checkmark for every
/// patch the bundle declares.
///
/// Only a machine that does not exist yet has one. Once installed, its
/// firmware is patched and the choice is fixed.
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
    /// Hands the edited choice back; New Machine holds it until the VM exists.
    let onSave: (VPhoneLaunchpadPatchSelection) -> Void

    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: VPhoneLaunchpadPatchSelection
    @State private var catalog: Catalog?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var filter = ""
    /// Empty keeps the order the bundle applies the patches in; a header click
    /// replaces it.
    @State private var sortOrder: [KeyPathComparator<Catalog.Patch>] = []
    /// The row whose summary the detail pane reads.
    @State private var highlighted: String?
    @State private var confirmsBootEssential = false

    init(
        initial: VPhoneLaunchpadPatchSelection,
        onSave: @escaping (VPhoneLaunchpadPatchSelection) -> Void,
    ) {
        self.initial = initial
        self.onSave = onSave
        _selection = State(initialValue: initial)
    }

    private var essentialOff: [Catalog.Patch] {
        catalog.map { selection.bootEssentialOff(in: $0) } ?? []
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Patches")) {
            VStack(spacing: 0) {
                header
                Divider()
                list
                Divider()
                detailPane
            }
        } accessory: {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Done") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(catalog == nil)
        }
        .frame(width: 920, height: 680)
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
                // Sized to its content, so the label sits against the menu
                // and lines up with the summary under it.
                Picker("Preset", selection: presetBinding) {
                    ForEach(catalog?.presets ?? []) { preset in
                        Text(verbatim: preset.displayTitle).tag(preset.identifier)
                    }
                }
                .fixedSize()
                .disabled(catalog == nil || isLoading)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                VPhoneLaunchpadSearchField(text: $filter, prompt: String(localized: "Filter patches"))
                    .frame(width: 220)
            }
            if let summary = catalog?.preset(selection.preset)?.displaySummary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            let rows = catalog.patches(matching: filter).sorted(using: sortOrder)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A flat table sorted by the order the bundle applies the patches, which
    /// already runs one set after another. A header click regroups it; sections
    /// were tried first and make AppKit report a reentrant table delegate.
    private func table(_ rows: [Catalog.Patch]) -> some View {
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("On") { patch in
                Toggle("On", isOn: Binding(
                    get: { selection.isOn(patch) },
                    set: { selection.set(patch, on: $0) },
                ))
                .labelsHidden()
            }
            .width(36)

            TableColumn("Component", value: \.component) { patch in
                Text(verbatim: patch.component)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Effect", value: \.effect) { patch in
                Text(verbatim: patch.effect)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 40, ideal: 50)

            TableColumn("Name", value: \.name) { patch in
                Text(verbatim: patch.name)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(patch.identifier)
            }
            .width(min: 140, ideal: 240)

            // Most patches are boot-essential, so a mark on each would say
            // nothing. It shows only on one that is off.
            TableColumn("Patch", value: \.title) { patch in
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

            TableColumn("Applies To", value: \.applicability) { patch in
                if patch.isVersionGated {
                    Text(verbatim: patch.applicability).lineLimit(1)
                } else {
                    Text("All").foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .width(min: 80, ideal: 110)
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
                .font(.callout)
            }
            detail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        if let patch = catalog?.patch(highlighted) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: patch.title).font(.headline)
                Text(verbatim: patch.summary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: facts(patch).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 62, alignment: .topLeading)
        } else {
            Text("Select a patch to see what it changes.")
                .foregroundStyle(.secondary)
                .frame(height: 62, alignment: .topLeading)
        }
    }

    /// The line under a patch's summary: where it comes from, what it
    /// applies to, and whether the machine boots without it.
    private func facts(_ patch: Catalog.Patch) -> [String] {
        var facts = [patch.patchSetName, patch.target]
        if patch.isVersionGated {
            facts.append(patch.applicability)
        }
        if patch.bootEssential {
            facts.append(String(localized: "Required to boot"))
        }
        return facts
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
        parts.append(String(localized: "Fixed once the machine is installed"))
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func load(preset: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try await Catalog.read(
                using: model.bundles.commandLine(),
                machine: nil,
                preset: preset,
            )
            // A second switch of the picker may have overtaken this read.
            guard preset == selection.preset else {
                return
            }
            selection.preset = catalog.activePreset
            selection.normalize(against: catalog)
            self.catalog = catalog
            // The detail pane reserves its space either way, so it starts with
            // something to read rather than a gap.
            highlighted = highlighted ?? catalog.patches.first?.identifier
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
