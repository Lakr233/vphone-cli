import AppKit
import SwiftUI

// MARK: - Templates

/// Every library's machine templates, from `vm template list --json`, with
/// Delete. New Machine builds a template the first time a combination of
/// firmware, preset, disk size and slimming is asked for, and clones every
/// later machine with that combination from it.
struct VPhoneLaunchpadTemplatesView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<VPhoneLaunchpadTemplate.ID> = []
    /// Empty keeps the order `vm template list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadTemplate>] = []
    /// The templates the delete confirmation is for; empty when it is closed.
    @State private var deletion: [VPhoneLaunchpadTemplate] = []
    @State private var buildDeletion: (libraryRoot: String, name: String)?
    @State private var isDeleting = false
    @State private var actionError: VPhoneLaunchpadError?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var templates: [VPhoneLaunchpadTemplate] {
        (library.templates ?? []).sorted(using: sortOrder)
    }

    private var selected: [VPhoneLaunchpadTemplate] {
        templates.filter { selection.contains($0.id) }
    }

    /// Builds no create holds any more.
    private var leftovers: [(libraryRoot: String, build: VPhoneLaunchpadTemplateList.Building)] {
        library.templateBuilds.filter { !$0.build.active }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Templates")) {
            VStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if selected.count == 1 {
                    Divider()
                    detail(selected[0])
                }
                ForEach(leftovers, id: \.build.path) { leftover in
                    Divider()
                    HStack {
                        Label("A template build stopped before it finished: \(leftover.build.name)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Delete…") { buildDeletion = (leftover.libraryRoot, leftover.build.name) }
                            .disabled(isDeleting)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        } accessory: {
            Button("Delete…") { deletion = selected }
                .disabled(selected.isEmpty || isDeleting)
                .help(String(localized: "Delete the selected templates. Machines created from them keep working."))
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 480)
        .task { await reload() }
        .confirmationDialog(
            deletion.count == 1 ? String(localized: "Delete template \(deletion[0].id)?") : String(localized: "Delete \(deletion.count) Templates?"),
            isPresented: Binding(get: { !deletion.isEmpty }, set: {
                if !$0 {
                    deletion = []
                }
            }),
            presenting: deletion,
        ) { templates in
            Button("Delete", role: .destructive) {
                Task {
                    for template in templates {
                        guard await delete(template.id, in: template.libraryRoot) else {
                            break
                        }
                    }
                }
            }
        } message: { templates in
            Text(templates.map(deletionMessage).joined(separator: "\n\n"))
        }
        .confirmationDialog(
            String(localized: "Delete the unfinished template build?"),
            isPresented: Binding(get: { buildDeletion != nil }, set: {
                if !$0 {
                    buildDeletion = nil
                }
            }),
        ) {
            Button("Delete", role: .destructive) {
                if let build = buildDeletion {
                    Task { await delete(build.name, in: build.libraryRoot) }
                }
            }
        } message: {
            Text("Its restored disk is deleted. A machine that needs this template builds it again.")
        }
        .errorAlert($actionError)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if library.templates == nil {
            if let error = library.templatesError {
                ContentUnavailableView("Unable to List Templates", systemImage: "exclamationmark.triangle", description: Text(verbatim: error))
            } else {
                ProgressView().controlSize(.small)
            }
        } else if templates.isEmpty {
            ContentUnavailableView {
                Label("No Templates", systemImage: "square.stack.3d.up")
            } description: {
                Text("New Machine builds a template the first time it creates a machine from a firmware, and clones every later machine with the same options from it.")
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(templates, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Template", value: \.key.device) { template in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: template.key.device)
                    Text(verbatim: template.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .help(template.path)
            }
            .width(min: 70, ideal: 84)
            TableColumn("OS", value: \.key.iOSVersion) { template in
                Text(verbatim: "\(template.key.osName) \(template.key.iOSVersion) (\(template.key.iOSBuild))")
                    .help(Text(verbatim: "cloudOS \(template.key.cloudOSVersion) (\(template.key.cloudOSBuild))"))
            }
            .width(min: 100, ideal: 110)
            TableColumn("Preset", value: \.key.patchPreset) { template in
                Text(verbatim: "\(template.key.patchPreset), \(template.key.diskSizeGB) GB")
            }
            .width(min: 70, ideal: 84)
            TableColumn("Size", value: \.allocatedBytes) { template in
                Text(verbatim: VPhoneLaunchpadDiskUsage.format(template.allocatedBytes))
                    .monospacedDigit()
                    .help(sizeHelp(template))
            }
            .width(min: 50, ideal: 56)
            .alignment(.numeric)
            TableColumn("Machines", value: \.machinesOrder) { template in
                Text(verbatim: template.machines.isEmpty ? "—" : template.machines.joined(separator: ", "))
                    .foregroundStyle(template.machines.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(template.machines.joined(separator: ", "))
            }
            .width(min: 50, ideal: 60)
            TableColumn("State", value: \.staleOrder) { template in
                // The icon alone: the detail below says what is outdated.
                if template.stale {
                    VPhoneLaunchpadStatusIcon(status: .warning)
                        .help(String(localized: "Outdated") + "\n" + template.staleReasons.joined(separator: "\n"))
                } else {
                    VPhoneLaunchpadStatusIcon(status: .passed)
                        .help(String(localized: "Current"))
                }
            }
            .width(40)
        }
        .contextMenu(forSelectionType: VPhoneLaunchpadTemplate.ID.self) { ids in
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(templates.filter { ids.contains($0.id) }.map(\.url))
            }
            .disabled(ids.isEmpty)
            Divider()
            Button("Delete…", role: .destructive) { deletion = templates.filter { ids.contains($0.id) } }
                .disabled(ids.isEmpty || isDeleting)
        }
        .onDeleteCommand {
            if !isDeleting {
                deletion = selected
            }
        }
        .vphoneFocusedOnAppear()
    }

    /// The selected template's details that do not fit a column.
    private func detail(_ template: VPhoneLaunchpadTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if template.stale {
                Label {
                    Text("Outdated: \(template.staleReasons.joined(separator: "; ")). New machines get a new template; this one only takes space.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            // Slimming and the date are here rather than in columns, which the
            // sheet has no room for.
            Text(verbatim: [template.key.slimming.summary, String(localized: "Created \(template.created.formatted(date: .abbreviated, time: .shortened))")].filter { !$0.isEmpty }.joined(separator: " · "))
                .help(slimmingHelp(template.key.slimming))
            if let sources = template.sources {
                Text("Built from \(URL(string: sources.iPhone)?.lastPathComponent ?? sources.iPhone) and cloudOS \(template.key.cloudOSVersion) (\(template.key.cloudOSBuild)).")
            }
            Text("Built with Core Bundle \(template.builtWithBundleVersion ?? "—"); every machine from it shares its SEP root secret and Data volume keys.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Text

    private func slimmingHelp(_ slimming: VPhoneLaunchpadTemplate.Slimming) -> String {
        var lines: [String] = []
        if slimming.tier != "none" {
            lines.append(String(localized: "Trim: \(slimming.trimTier)"))
        }
        lines.append(String(localized: "Service profile: \(slimming.serviceProfile)"))
        if !slimming.removedApps.isEmpty {
            lines.append(String(localized: "Removed: \(slimming.removedApps.map(VPhoneLaunchpadSlimming.appName).joined(separator: ", "))"))
        }
        return lines.joined(separator: "\n")
    }

    private func sizeHelp(_ template: VPhoneLaunchpadTemplate) -> String {
        guard let exclusive = library.usage(of: template)?.exclusive else {
            return String(localized: "Allocated on disk.")
        }
        return String(localized: "Allocated on disk; deleting it frees about \(VPhoneLaunchpadDiskUsage.format(exclusive)), the blocks no machine shares, once no local Time Machine snapshot keeps them.")
    }

    private func deletionMessage(_ template: VPhoneLaunchpadTemplate) -> String {
        var parts: [String] = []
        if template.machines.isEmpty {
            parts.append(String(localized: "No machine was created from it."))
        } else {
            parts.append(String(localized: "\(template.machines.joined(separator: ", ")) keep working: they share its blocks but do not need it."))
        }
        if let exclusive = library.usage(of: template)?.exclusive {
            parts.append(String(localized: "Deleting it frees about \(VPhoneLaunchpadDiskUsage.format(exclusive)), once no local Time Machine snapshot keeps those blocks; the blocks its machines share are freed once they change or are deleted."))
        }
        parts.append(String(localized: "The next machine with its options builds a new template, which takes a restore."))
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    private func reload() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                library.applyPreviewTemplates()
                if selection.isEmpty, let first = VPhoneLaunchpadPreview.templates.first {
                    selection = [first.id]
                }
                return
            }
        #endif
        await library.refreshTemplates()
        selection.formIntersection(templates.map(\.id))
    }

    /// False when it failed, so a batch stops there.
    @discardableResult
    private func delete(_ name: String, in root: String) async -> Bool {
        guard !isDeleting else {
            return false
        }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await library.deleteTemplate(name, in: root)
        } catch is CancellationError {
            return false
        } catch {
            actionError = VPhoneLaunchpadError(actionFailure: error)
            await reload()
            return false
        }
        await reload()
        return true
    }
}

extension VPhoneLaunchpadTemplate {
    /// The Machines column's order: unused templates first, then by the names.
    var machinesOrder: String {
        machines.joined(separator: ", ")
    }

    /// The State column's order: current, then outdated.
    var staleOrder: Int {
        stale ? 1 : 0
    }
}
