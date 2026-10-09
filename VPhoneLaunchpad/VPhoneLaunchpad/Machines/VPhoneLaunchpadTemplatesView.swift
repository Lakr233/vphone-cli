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
        VPhoneLaunchpadSheet(Text("Templates"), width: VPhoneLaunchpadSheetSize.wide) {
            VStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if selected.count == 1, selected[0].stale {
                    Divider()
                    outdatedNote(selected[0])
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

    /// One line per template. Machines do not depend on their template, so
    /// no column looks them up.
    private var table: some View {
        Table(templates, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Device", value: \.key.device) { template in
                Text(verbatim: template.key.device)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Template", value: \.id) { template in
                Text(verbatim: template.id)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .help(origin(template))
            }
            .width(min: 90, ideal: 110)
            TableColumn("OS", value: \.key.iOSVersion) { template in
                Text(verbatim: "\(template.key.osName) \(template.key.iOSVersion) (\(template.key.iOSBuild))")
                    .help(Text(verbatim: "cloudOS \(template.key.cloudOSVersion) (\(template.key.cloudOSBuild))"))
            }
            .width(min: 110, ideal: 140)
            TableColumn("Preset", value: \.key.patchPreset) { template in
                Text(verbatim: template.key.patchPreset)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Disk", value: \.key.diskSizeGB) { template in
                Text(verbatim: "\(template.key.diskSizeGB) GB")
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 56)
            .alignment(.numeric)
            TableColumn("Slimming", value: \.key.slimming.summary) { template in
                Text(verbatim: template.key.slimming.summary)
                    .help(slimmingHelp(template.key.slimming))
            }
            .width(min: 100, ideal: 170)
            TableColumn("Size", value: \.allocatedBytes) { template in
                Text(verbatim: VPhoneLaunchpadDiskUsage.format(template.allocatedBytes))
                    .monospacedDigit()
                    .help(sizeHelp(template))
            }
            .width(min: 50, ideal: 60)
            .alignment(.numeric)
            TableColumn("State", value: \.staleOrder) { template in
                // The icon alone: the line below the table says what is outdated.
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

    /// What the identifier's tooltip says: when, from what and with which
    /// bundle the template was built.
    private func origin(_ template: VPhoneLaunchpadTemplate) -> String {
        var lines = [String(localized: "Created \(template.created.formatted(date: .abbreviated, time: .shortened))")]
        if let sources = template.sources {
            lines.append(String(localized: "Built from \(URL(string: sources.iPhone)?.lastPathComponent ?? sources.iPhone) and cloudOS \(template.key.cloudOSVersion) (\(template.key.cloudOSBuild))."))
        }
        lines.append(String(localized: "Built with Core Bundle \(template.builtWithBundleVersion ?? "—"); every machine from it shares its SEP root secret and Data volume keys."))
        lines.append(template.path)
        return lines.joined(separator: "\n")
    }

    /// The one line under the table, for a selected outdated template.
    private func outdatedNote(_ template: VPhoneLaunchpadTemplate) -> some View {
        Label {
            Text("Outdated: \(template.staleReasons.joined(separator: "; ")). New machines get a new template; this one only takes space.")
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
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
        parts.append(String(localized: "Machines created from it keep working: they share its blocks but do not need it."))
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
    /// The State column's order: current, then outdated.
    var staleOrder: Int {
        stale ? 1 : 0
    }
}
