import SwiftUI

/// New Machine's System page: whether the machine is cloned from a
/// template, and how that template is slimmed. The switches are part of the
/// template's key: other switches make another template, and both stay.
/// Slim System itself is on the basic page.
struct VPhoneLaunchpadSlimmingSections: View {
    @Binding var usesTemplate: Bool
    @Binding var slimming: VPhoneLaunchpadSlimming
    @State private var choosesApps = false

    var body: some View {
        Section {
            Toggle("Create from a template", isOn: $usesTemplate)
        } header: {
            Text("Template")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(usesTemplate
                    ? "Machines from one template share its SEP root secret and Data volume keys. Turn this off for a machine that needs keys of its own."
                    : "The machine is restored on its own, with keys of its own. It is not slimmed, and starts at Setup Assistant.")
                if usesTemplate, !slimming.slim {
                    Text("Slim System is off, so the template keeps every file, service and app.")
                }
            }
            .foregroundStyle(.secondary)
        }

        if usesTemplate {
            filesSection
            servicesSection
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
