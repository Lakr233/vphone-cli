import AppKit
import SwiftUI

// MARK: - Settings

struct VPhoneLaunchpadMachineSettingsView: View {
    let machine: VPhoneLaunchpadMachine
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cpu = 8
    @State private var memoryMB = 8192
    @State private var network = "nat"
    @State private var bridgeInterface = ""

    private var currentNetwork: String {
        machine.network.mode == "hostOnly" ? "none" : machine.network.mode
    }

    var body: some View {
        Form {
            Section {
                Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
            } header: {
                Text("Hardware")
            }
            Section("Network") {
                Picker("Mode", selection: $network) {
                    Text("NAT").tag("nat")
                    Text("Bridged").tag("bridged")
                    Text("None").tag("none")
                }
                if network == "bridged" {
                    TextField("Interface", text: $bridgeInterface, prompt: Text("First available"))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(machine.name) Settings")
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .onAppear {
            cpu = machine.cpuCount
            memoryMB = machine.memoryMB
            network = currentNetwork
            bridgeInterface = machine.network.bridgeInterface ?? ""
        }
    }

    private func save() {
        let bridgeChanged = bridgeInterface != (machine.network.bridgeInterface ?? "")
        Task {
            await model.machines.configure(
                machine.name,
                cpu: cpu == machine.cpuCount ? nil : cpu,
                memoryMB: memoryMB == machine.memoryMB ? nil : memoryMB,
                network: network == currentNetwork && !bridgeChanged ? nil : network,
                bridgeInterface: network == "bridged" ? bridgeInterface : nil,
            )
        }
        dismiss()
    }
}

// MARK: - Rename and clone

struct VPhoneLaunchpadNameSheet: View {
    let title: LocalizedStringKey
    let action: LocalizedStringKey
    let initial: String
    var note: LocalizedStringKey?
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var isValid: Bool {
        VPhoneLaunchpadNames.isValidMachineName(name) && name != initial
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } footer: {
                Text(note ?? "Letters, digits, dots, dashes and underscores.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action) {
                    onConfirm(name)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .onAppear { name = initial }
    }
}

// MARK: - Export

struct VPhoneLaunchpadExportView: View {
    let name: String
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var densest = false
    @State private var includeIPSW = false

    var body: some View {
        Form {
            Section {
                Toggle("Densest compression", isOn: $densest)
                Toggle("Include the restore IPSW directory", isOn: $includeIPSW)
            } footer: {
                Text(densest
                    ? "Writes a .txz archive with xz -9. Smaller, and much slower."
                    : "Writes a .tzst archive with zstd -3.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Export \(name)")
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Choose Location…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export \(name)")
        panel.nameFieldStringValue = "\(name).\(densest ? "txz" : "tzst")"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let densest = densest
        let includeIPSW = includeIPSW
        Task { await model.machines.export(name, to: url, densest: densest, includeIPSW: includeIPSW) }
        dismiss()
    }
}
