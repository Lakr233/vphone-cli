import SwiftUI

// MARK: - Change Core Bundle

/// Binds one or more machines to another installed Core Bundle. The host
/// programs follow at the next start; the guest environment can be updated
/// now on stopped machines. The boot chain stays as created.
struct VPhoneLaunchpadChangeBundleView: View {
    let machines: [VPhoneLaunchpadMachine]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var version = ""
    @State private var updatesEnvironment = true

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var title: Text {
        machines.count == 1
            ? Text("Change Core Bundle of \(machines[0].name)")
            : Text("Change Core Bundle of \(machines.count) Machines")
    }

    /// Nothing to do when every machine already runs with `version` and
    /// its guest environment is left alone.
    private var canApply: Bool {
        !version.isEmpty && (updatesEnvironment || machines.contains { library.bundleVersion(for: $0.path) != version })
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            Form {
                Section("Current") {
                    ForEach(machines) { machine in
                        LabeledContent(machine.name) {
                            Text(verbatim: library.bundleVersion(for: machine.path) ?? "—")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Section {
                    Picker("Core Bundle", selection: $version) {
                        ForEach(model.bundles.selectableVersions, id: \.self) { version in
                            if version == model.bundles.defaultVersion {
                                Text("\(version) (Default)").tag(version)
                            } else {
                                Text(verbatim: version).tag(version)
                            }
                        }
                    }
                    Toggle("Update guest environment", isOn: $updatesEnvironment)
                } footer: {
                    Text("Host programs change at the next start. The guest environment is updated now on stopped machines; running machines keep theirs until it is updated later. Guest patches follow each machine’s patch choice when its guest environment is updated. The boot chain stays as it was built.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // The machines' own version when they share one, else the default.
            let current = Set(machines.map { library.bundleVersion(for: $0.path) })
            let versions = model.bundles.selectableVersions
            if current.count == 1, let shared = current.first ?? nil, versions.contains(shared) {
                version = shared
            } else {
                version = model.bundles.defaultVersion.flatMap { versions.contains($0) ? $0 : nil } ?? versions.first ?? ""
            }
        }
    }

    private func apply() {
        // setBundle leaves out machines with no guest environment to update.
        let version = version
        let library = library
        let paths = machines.map(\.path)
        let updatesEnvironment = updatesEnvironment
        Task {
            await library.setBundle(version, for: paths, updateEnvironment: updatesEnvironment)
        }
        dismiss()
    }
}
