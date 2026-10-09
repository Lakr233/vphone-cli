import SwiftUI

/// New Machine's Template and Slimming pages: whether the machine is cloned
/// from a template, and how that template is slimmed. The switches are part
/// of the template's key: other switches make another template, and both
/// stay.
struct VPhoneLaunchpadSlimmingSections: View {
    enum Part {
        case template, slimming
    }

    let part: Part
    @Binding var usesTemplate: Bool
    /// Whether a template exists for the chosen firmware; nil for custom
    /// IPSWs, which the list cannot be matched against.
    var templateAvailable: Bool?
    @Binding var slimming: VPhoneLaunchpadSlimming
    @State private var choosesApps = false

    var body: some View {
        switch part {
        case .template:
            templateSection
        case .slimming:
            Section {
                Toggle("Slim System", isOn: $slimming.slim)
            } footer: {
                if !usesTemplate, slimming.slim {
                    Text("Without a template the machine is slimmed on its own, with a setup boot of its own. Setup Assistant is skipped.")
                        .foregroundStyle(.secondary)
                }
            }
            filesSection
            servicesSection
        }
    }

    private var templateSection: some View {
        Section {
            Toggle("Use Template", isOn: $usesTemplate)
        } header: {
            Text("Template")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if templateAvailable == false {
                    Text("No template is available for this firmware. Turning this on saves a sample of the machine in the template library.")
                }
                Text(usesTemplate
                    ? "Machines from one template share its SEP root secret and Data volume keys. Turn this off for a machine that needs keys of its own."
                    : slimming.slim
                    ? "The machine is restored on its own, with keys of its own."
                    : "The machine is restored on its own, with keys of its own. It starts at Setup Assistant.")
                if usesTemplate, !slimming.slim {
                    Text("Slim System is off, so the template keeps every file, service and app.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            Picker("Trim", selection: $slimming.trim) {
                ForEach(VPhoneLaunchpadSlimming.TrimTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            if slimming.trim == .standard {
                TextField("Kept Languages", text: $slimming.keptLanguages, prompt: Text(verbatim: VPhoneLaunchpadSlimming.defaultLanguages))
            }
        } header: {
            Text("System Files")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trimNote).foregroundStyle(.secondary)
                if let problem = slimming.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
        }
        .disabled(!slimming.slim)
    }

    private var trimNote: String {
        switch slimming.trim {
        case .none:
            String(localized: "Nothing is deleted from the System volume.")
        case .conservative:
            String(localized: "Deletes the software update ramdisk and baseband firmware, about 0.4 GB. It cannot be undone: the trim is part of the template.")
        case .standard:
            String(localized: "Also deletes the AirPods pairing assets, watch faces and the language data of languages not kept, about 1.2 GB. It cannot be undone: the trim is part of the template.")
        }
    }

    // MARK: - Services and apps

    /// Apple Account is not offered: the guest refuses its sign-in either
    /// way, so the trimmed profile always turns its daemons off.
    private var servicesSection: some View {
        Section {
            Toggle("Turn off unneeded services", isOn: $slimming.trimsServices)
            LabeledContent("Remove system apps") {
                HStack {
                    Button("Choose…") { choosesApps = true }
                        .disabled(!slimming.removesApps)
                        .popover(isPresented: $choosesApps, arrowEdge: .trailing) {
                            appsPopover
                        }
                    Toggle("Remove system apps", isOn: $slimming.removesApps)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        } header: {
            Text("Services and Apps")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("About 140 launch daemons a research machine rarely needs, Apple Account's among them.")
                if slimming.removesApps {
                    Text("^[\(slimming.removedApps.count) system app](inflect: true) removed; Camera and Phone are never removed.")
                } else {
                    Text("No system app is removed.")
                }
                Text("Each machine can turn services back on and restore apps in Guest System.")
            }
            .foregroundStyle(.secondary)
        }
        .disabled(!slimming.slim)
    }

    private var appsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checked apps are removed.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                let apps = VPhoneLaunchpadSlimming.removableApps
                ForEach(Array(stride(from: 0, to: apps.count, by: 2)), id: \.self) { index in
                    GridRow {
                        ForEach(apps[index ..< min(index + 2, apps.count)]) { app in
                            Toggle(isOn: removes(app.id)) {
                                Text(verbatim: app.name)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func removes(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { !slimming.keptApps.contains(bundleID) },
            set: { removed in
                if removed {
                    slimming.keptApps.remove(bundleID)
                } else {
                    slimming.keptApps.insert(bundleID)
                }
            },
        )
    }
}
