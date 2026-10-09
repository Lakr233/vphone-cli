import AppKit
import SwiftUI

struct VPhoneLaunchpadHostSetupView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VPhoneLaunchpadMenuBar.key) private var showsInMenuBar = false
    @State private var showsSkillInstall = false

    private var host: VPhoneLaunchpadHostSetup {
        model.host
    }

    var body: some View {
        @Bindable var host = host
        VPhoneLaunchpadSheet(Text("Host Setup")) {
            form
        } accessory: {
            Button("Check Again") {
                Task { await model.refreshHost() }
            }
            .help("Run every check again")
            .disabled(host.isChecking)
            Button("Install Skill…") { showsSkillInstall = true }
                .help("Give your coding agent the vphone skill")
        } actions: {
            // Straight on to the next stage while it is not ready.
            if host.requiredPassed, !model.bundles.isReady {
                Button("Continue") { model.present(.coreBundle) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsSkillInstall) {
            VPhoneLaunchpadSkillInstallView()
        }
        .errorAlert($host.actionError)
    }

    private var form: some View {
        Form {
            Section {
                ForEach(host.checks) { check in
                    row(check)
                }
            } header: {
                HStack {
                    Text("Checks")
                    Spacer()
                    Text("\(host.passedCount) of \(host.checks.count) passed")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if host.checks.contains(where: { $0.kind == .developerTools && $0.status != .passed }) {
                    Text("Allow vphone-launchpad in Privacy & Security → Developer Tools.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Keep in Menu Bar", isOn: $showsInMenuBar)
            }
        }
        .formStyle(.grouped)
        .vphoneFittedHeight(limit: VPhoneLaunchpadSheetSize.maximum - VPhoneLaunchpadSheetSize.chrome)
    }

    /// Icon, title, then detail and any action pinned to the trailing edge.
    /// A plain HStack rather than LabeledContent: LabeledContent splits the
    /// row into columns and truncated the detail while leaving the button
    /// short of the edge.
    private func row(_ check: VPhoneLaunchpadHostCheck) -> some View {
        let isSkipped = host.isSkipped(check)
        return HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: isSkipped ? .warning : check.status)
            Text(check.title)
                .layoutPriority(1)
            Spacer(minLength: 16)
            Text(isSkipped ? String(localized: "Skipped · \(check.detail)") : check.detail)
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
        case .libraryVolume where VPhoneLaunchpadMachineLocations.environmentRoot == nil:
            HStack {
                skipButton(check)
                Button("Change…") { chooseLibrary() }
                    .help("Choose the folder new machines are created in")
            }
        case .developerTools where check.status != .passed:
            if host.canRequestDeveloperTools {
                HStack {
                    Button("Open Settings") {
                        Task { await host.requestDeveloperTools() }
                    }
                    Button("Relaunch") { VPhoneLaunchpadHostSetup.relaunch() }
                        .help("Quit and open Launchpad again, if access granted in Settings does not show here")
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
            skipButton(check)
        }
    }

    @ViewBuilder
    private func skipButton(_ check: VPhoneLaunchpadHostCheck) -> some View {
        if host.isSkipped(check) {
            Button("Don’t Skip") { host.setSkipped(check.kind, false) }
        } else if host.canSkip(check) {
            Button("Skip") { host.setSkipped(check.kind, true) }
                .help("Continue without this check. The Core Bundle still runs its own checks.")
        }
    }

    // MARK: - Library

    /// Makes another folder the default library from the next launch. The
    /// machines are not moved: the alert says to move them, and Launchpad
    /// relaunches to list the new library.
    private func chooseLibrary() {
        let current = host.libraryRoot
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Library")
        panel.message = String(localized: "New machines are created in this folder. Machines already in the current library are not moved.")
        panel.prompt = String(localized: "Use as Library")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        panel.present { url in
            let root = VPhoneLaunchpadMachineLocations.canonical(url)
            guard root != VPhoneLaunchpadMachineLocations.canonical(current) else {
                return
            }
            let failure = String(localized: "Unable to Use \(VPhoneLaunchpadHostSetup.abbreviated(url))")
            if let problem = VPhoneLaunchpadMachineLocations.problem(with: root) {
                host.actionError = VPhoneLaunchpadError(failure, detail: problem)
                return
            }
            guard VPhoneLaunchpadMachineLocations.supportsCloning(root) || confirmWithoutCloning(url) else {
                return
            }
            do {
                try VPhoneLaunchpadMachineLocations.rememberLibrary(url)
            } catch {
                host.actionError = VPhoneLaunchpadError(failure, detail: error.localizedDescription)
                return
            }
            announceChange(from: current, to: url)
        }
    }

    /// Templates, clones and snapshots are APFS clones: without them every
    /// one is a full copy.
    private func confirmWithoutCloning(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "This Volume Cannot Clone Files")
        alert.informativeText = String(localized: "Machines in \(VPhoneLaunchpadHostSetup.abbreviated(url)) are slower to create from templates, clone and snapshot, because each copy writes the whole disk instead of sharing it, and they take much more space.")
        alert.addButton(withTitle: String(localized: "Use Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func announceChange(from old: URL, to new: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Library Changed")
        alert.informativeText = String(localized: "New machines are created in \(VPhoneLaunchpadHostSetup.abbreviated(new)). Launchpad does not move machines: to keep using the ones in \(VPhoneLaunchpadHostSetup.abbreviated(old)), quit Launchpad and move their folders into the new library yourself. Launchpad relaunches to use the new library.")
        alert.addButton(withTitle: String(localized: "Relaunch"))
        alert.addButton(withTitle: String(localized: "Show Current Library"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([old])
        }
        VPhoneLaunchpadHostSetup.relaunch()
    }
}
