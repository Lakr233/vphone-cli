import SwiftUI

struct VPhoneLaunchpadHostSetupView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model

    private var host: VPhoneLaunchpadHostSetup {
        model.host
    }

    var body: some View {
        Form {
            Section {
                ForEach(host.required) { check in
                    row(check)
                }
            } header: {
                HStack {
                    Text("Required")
                    Spacer()
                    Text("\(host.passedRequiredCount) of \(host.required.count) passed")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if !host.requiredPassed {
                    VStack(alignment: .leading, spacing: 4) {
                        if host.checks.contains(where: { $0.kind == .developerTools && $0.status != .passed }) {
                            Text("Allow vphone-launchpad in Privacy & Security → Developer Tools, then click Reopen.")
                        }
                        Text("Core Bundle appears once every required check passes.")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(host.advisory) { check in
                    row(check)
                }
            } header: {
                Text("Advisory")
            } footer: {
                Text("Advisory checks do not block setup.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshDeveloperTools()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshHost() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .help("Run every check again")
                .disabled(host.isChecking)
            }
        }
    }

    /// Icon, title, then detail and any action pinned to the trailing edge.
    /// A plain HStack rather than LabeledContent: LabeledContent splits the
    /// row into columns and truncated the detail while leaving the button
    /// short of the edge.
    private func row(_ check: VPhoneLaunchpadHostCheck) -> some View {
        HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: check.status)
            Text(check.title)
                .layoutPriority(1)
            Spacer(minLength: 16)
            Text(check.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(check.detail)
            action(for: check)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func action(for check: VPhoneLaunchpadHostCheck) -> some View {
        switch check.kind {
        case .developerTools where check.status != .passed:
            HStack(spacing: 8) {
                if host.canRequestDeveloperTools {
                    Button("Open Settings") {
                        Task { await host.requestDeveloperTools() }
                    }
                }
                if host.needsRelaunch {
                    Button("Reopen") {
                        host.relaunch()
                    }
                }
            }
        case .helper where check.status == .pending:
            Button(host.helper.state == .notInstalled ? "Install…" : "Update…") {
                Task {
                    await host.installHelper()
                    await model.refreshHost()
                }
            }
        default:
            EmptyView()
        }
    }
}
