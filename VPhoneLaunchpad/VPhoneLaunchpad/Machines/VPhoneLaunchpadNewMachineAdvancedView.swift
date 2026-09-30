import SwiftUI

/// New Machine's second page: network, patches and restore options. It edits
/// New Machine's own state, so Done only closes it.
struct VPhoneLaunchpadNewMachineAdvancedView: View {
    @Binding var network: String
    @Binding var patches: VPhoneLaunchpadPatchSelection
    @Binding var keepArtifacts: Bool
    let patchCatalog: VPhoneLaunchpadPatchCatalog?
    let patchCatalogError: String?
    /// New Machine owns the catalog, which is read again for each preset.
    let reloadPatches: () -> Void

    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsPatchSettings = false

    static func networkTitle(_ mode: String) -> String {
        switch mode {
        case "bridged": String(localized: "Bridged")
        case "none": String(localized: "None")
        default: String(localized: "NAT")
        }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Advanced Options")) {
            Form {
                Section("Network") {
                    Picker("Mode", selection: $network) {
                        Text("NAT").tag("nat")
                        Text("Bridged").tag("bridged")
                        Text("None").tag("none")
                    }
                }

                patchSection

                Section("Options") {
                    Toggle("Keep prepared restore files", isOn: $keepArtifacts)
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsPatchSettings) {
            VPhoneLaunchpadPatchSettingsView(initial: patches) { selection in
                patches = selection
                reloadPatches()
            }
            .environment(model)
        }
    }

    // MARK: - Patches

    private var patchSection: some View {
        Section {
            if let patchCatalog {
                Picker("Preset", selection: presetBinding) {
                    ForEach(patchCatalog.presets) { preset in
                        Text(verbatim: preset.displayTitle).tag(preset.identifier)
                    }
                }
                LabeledContent("Patches") {
                    Button("Patch Settings…") { showsPatchSettings = true }
                }
            } else if let patchCatalogError {
                Label(patchCatalogError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the bundle's patches…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Patches")
        } footer: {
            patchNote
        }
    }

    @ViewBuilder
    private var patchNote: some View {
        let essentialOff = patchCatalog.map { patches.bootEssentialOff(in: $0) } ?? []
        VStack(alignment: .leading, spacing: 4) {
            if let summary = patchCatalog?.preset(patches.preset)?.displaySummary, !summary.isEmpty {
                Text(verbatim: summary).foregroundStyle(.secondary)
            }
            if patches.hasOverrides {
                Text("Differs from the preset: \(patches.blocked.count) off, \(patches.allowed.count) on.")
                    .foregroundStyle(.secondary)
            }
            if !essentialOff.isEmpty {
                Label {
                    Text("^[\(essentialOff.count) boot-essential patch](inflect: true) off: \(essentialOff.map(\.identifier).joined(separator: ", "))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
        }
    }

    /// Switching preset here re-bases the overrides for the same reason the editor
    /// does: they are read as a difference from whichever preset is active.
    private var presetBinding: Binding<String> {
        Binding(
            get: { patches.preset },
            set: { identifier in
                guard identifier != patches.preset else {
                    return
                }
                patches = VPhoneLaunchpadPatchSelection(preset: identifier)
                reloadPatches()
            },
        )
    }
}
