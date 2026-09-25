import AppKit
import SwiftUI

// MARK: - State label

/// A machine's run state as the table and the inspector show it.
struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadMachineLibrary.RunState

    var body: some View {
        let (status, text): (VPhoneLaunchpadStatus, String) = switch state {
        case .running: (.passed, String(localized: "Running"))
        case .stopped: (.pending, String(localized: "Stopped"))
        case let .busy(activity): (.running, activity)
        }
        Label {
            Text(text).lineLimit(1)
        } icon: {
            VPhoneLaunchpadStatusIcon(status: status)
        }
    }
}

// MARK: - Inspector

/// The trailing inspector for the selected machine. Values are split into
/// short rows, since the column is narrow, and long ones truncate in the
/// middle.
struct VPhoneLaunchpadMachineInspector: View {
    let machine: VPhoneLaunchpadMachine
    let onShowProgress: (String) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        Form {
            Section {
                if let creation = library.creations[machine.name] {
                    creationSummary(creation)
                }
                LabeledContent("State") {
                    VPhoneLaunchpadMachineStateLabel(state: library.state(of: machine.name))
                }
                if let started = library.startedAt[machine.name] {
                    LabeledContent("Started", value: started.formatted(date: .omitted, time: .shortened))
                }
                if let variant = machine.restoreInfo?.variant {
                    LabeledContent("Variant", value: variant)
                }
            } header: {
                Text(machine.name)
                    .font(.headline)
            }

            Section("Firmware") {
                if let info = machine.restoreInfo {
                    LabeledContent("iOS", value: "\(info.ios.version) (\(info.ios.build))")
                    LabeledContent("cloudOS", value: "\(info.cloudOS.version) (\(info.cloudOS.build))")
                } else {
                    Text("Not restored").foregroundStyle(.secondary)
                }
            }

            Section("Hardware") {
                LabeledContent("CPU", value: String(localized: "\(machine.cpuCount) cores"))
                LabeledContent("Memory", value: VPhoneLaunchpadMachinesView.memory(machine.memoryMB))
                LabeledContent("Disk", value: VPhoneLaunchpadMachinesView.disk(machine.diskSizeBytes))
                LabeledContent("Network", value: machine.networkDescription)
            }

            Section("Identity") {
                if let udid = machine.udid {
                    value("UDID", udid)
                }
                value(
                    "Location",
                    VPhoneLaunchpadHostSetup.abbreviated(library.libraryRoot.appendingPathComponent(machine.name)),
                )
            }

            Section("Console") {
                VPhoneLaunchpadLogView(lines: library.consoles[machine.name] ?? [])
                    .frame(minHeight: 160)
            }

            Section("Recent Commands") {
                commands
            }
        }
        .formStyle(.grouped)
        .onAppear { library.loadConsoleIfNeeded(machine.name) }
        .onChange(of: machine.name) { _, name in library.loadConsoleIfNeeded(name) }
    }

    private func value(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private func creationSummary(_ creation: VPhoneLaunchpadCreationPipeline) -> some View {
        LabeledContent {
            Button("Show Progress") { onShowProgress(creation.options.name) }
        } label: {
            if creation.isRunning {
                Label { Text("Creating: \(creation.current?.title ?? "")") } icon: { VPhoneLaunchpadStatusIcon(status: .running) }
            } else if creation.isFinished {
                Label { Text("Created") } icon: { VPhoneLaunchpadStatusIcon(status: .passed) }
            } else {
                Label { Text(creation.failure?.message ?? String(localized: "Creation stopped")) } icon: { VPhoneLaunchpadStatusIcon(status: .failed) }
            }
        }
    }

    @ViewBuilder
    private var commands: some View {
        let entries = Array(model.history.entries.suffix(12).reversed())
        if entries.isEmpty {
            Text("Commands Launchpad runs appear here.")
                .foregroundStyle(.secondary)
        }
        ForEach(entries) { entry in
            Label {
                Text(entry.text)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(entry.text)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: entry.status.map { $0 == 0 ? .passed : .failed } ?? .running)
            }
            .contextMenu {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
            }
        }
    }
}
