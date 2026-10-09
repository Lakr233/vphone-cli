import SwiftUI

/// The patch sections of New Machine's Patches tab, the network section of
/// its Hardware tab and the restore options of its Storage tab, as sections
/// of New Machine's form. It edits New Machine's own state.
struct VPhoneLaunchpadNewMachineAdvancedView: View {
    var page: VPhoneLaunchpadNewMachineView.Page
    /// A template never keeps the restore files.
    var usesTemplate: Bool
    @Binding var network: String
    @Binding var patches: VPhoneLaunchpadPatchSelection
    @Binding var keepArtifacts: Bool
    let patchCatalog: VPhoneLaunchpadPatchCatalog?
    let patchCatalogError: String?
    /// New Machine owns the catalog, which is read again for each preset.
    let reloadPatches: () -> Void
    /// The Core Bundle chosen in New Machine, whose patches the editor lists.
    /// Nil reads the default version's.
    var bundleVersion: String?

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var showsPatchSettings = false

    /// The network modes `vm create --network` takes, with their titles.
    static var networkModes: [(tag: String, title: String)] {
        [
            ("nat", String(localized: "NAT")),
            ("bridged", String(localized: "Bridged")),
            ("tunnel", String(localized: "Tunnel")),
            ("none", String(localized: "None")),
        ]
    }

    /// What `mode` does, for the footer under its picker.
    static func networkDescription(_ mode: String) -> String {
        switch mode {
        case "nat": String(localized: "The guest shares this Mac's connection through Virtualization's built-in NAT. Its traffic skips a VPN on the Mac.")
        case "bridged": String(localized: "The guest joins the network of one of this Mac's interfaces with an address of its own, so other devices on that network can reach it.")
        case "tunnel": String(localized: "Traffic leaves through this Mac's own connections, so it follows the Mac's VPN.")
        case "none": String(localized: "The guest has no network device and stays offline.")
        default: ""
        }
    }

    var body: some View {
        switch page {
        case .patches:
            patchSection
        case .hardware:
            Section {
                Picker("Mode", selection: $network) {
                    ForEach(Self.networkModes, id: \.tag) { mode in
                        Text(verbatim: mode.title).tag(mode.tag)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text(Self.networkDescription(network))
                    .foregroundStyle(.secondary)
            }
        case .storage:
            Section {
                Toggle("Keep prepared restore files", isOn: $keepArtifacts)
                    .disabled(usesTemplate)
            } header: {
                Text("Options")
            } footer: {
                if usesTemplate {
                    Text("A template never keeps them.").foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
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
                        .sheet(isPresented: $showsPatchSettings) {
                            VPhoneLaunchpadPatchSettingsView(initial: patches, bundleVersion: bundleVersion) { selection in
                                patches = selection
                                reloadPatches()
                            }
                            .environment(model)
                        }
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
            if usesTemplate, let patchCatalog, !patchCatalog.guestOverrides(patches).isEmpty {
                Text("Guest patch changes are applied to this machine after it is cloned. The template keeps the preset’s, so machines that do not change them share it.")
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
