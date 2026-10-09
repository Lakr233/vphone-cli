import SwiftUI

// MARK: - State read from the guest

/// One backup `apps.removed_system` lists.
nonisolated struct VPhoneLaunchpadRemovedApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let restorable: Bool

    static func list(_ result: [String: Any]) -> [Self] {
        let backups = result["backups"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return backups.compactMap { backup in
            guard let bundleID = backup["bundle_id"] as? String, seen.insert(bundleID).inserted else {
                return nil
            }
            let app = (backup["app"] as? String).map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            let known = VPhoneLaunchpadSlimming.removableApps.first { $0.id == bundleID }?.name
            return Self(id: bundleID, name: known ?? app ?? bundleID, restorable: backup["restorable"] as? Bool ?? true)
        }
    }
}

// MARK: - Sheet

/// What a template's slimming left in one machine's guest, and how to undo
/// it there: the service profile, switched at once and taking effect when the
/// guest restarts, and the removed system apps, restored from the backups the
/// removal kept. Both go through vphoned, so the machine must be running.
struct VPhoneLaunchpadGuestSystemView: View {
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile: VPhoneLaunchpadServiceProfile?
    /// A change the guest takes on only when it restarts, kept by the library
    /// until it has (`VPhoneLaunchpadPendingRestart`).
    @State private var restartPending = false
    /// Waits for the guest to come back after Restart Guest.
    @State private var restartTask: Task<Void, Never>?
    @State private var chosenProfile = "trimmed"
    @State private var removedApps: [VPhoneLaunchpadRemovedApp]?
    @State private var selectedApps: Set<String> = []
    @State private var loadError: String?
    @State private var isWorking = false
    /// What the last change did, under its section.
    @State private var profileNote: String?
    @State private var appsNote: String?
    @State private var error: VPhoneLaunchpadError?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var isRunning: Bool {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return VPhoneLaunchpadPreview.guestSystemRunning
            }
        #endif
        return library.state(of: machine) == .running
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("\(machine.name) Guest System")) {
            Form {
                if !isRunning {
                    Section {
                        Label("Start \(machine.name) to change these. They change the guest itself, through vphoned.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                } else if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Spacer()
                            Button("Try Again") { Task { await load() } }
                        }
                    }
                } else {
                    servicesSection
                    appsSection
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .fixedSize(horizontal: false, vertical: true)
        .task(id: isRunning) {
            if isRunning {
                await load()
            }
        }
        .onDisappear { restartTask?.cancel() }
        .errorAlert($error)
    }

    // MARK: - Services

    private var servicesSection: some View {
        Section {
            if let profile {
                Picker("Service Profile", selection: $chosenProfile) {
                    Text("Trimmed").tag("trimmed")
                    Text("None").tag("none")
                }
                HStack {
                    if needsRestart {
                        Label("Restart required", systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    Spacer()
                    if needsRestart {
                        Button("Restart Guest") {
                            restartTask = Task { await restartGuest() }
                        }
                        .disabled(isWorking)
                    }
                    Button("Apply") { Task { await applyProfile() } }
                        .disabled(isWorking || chosenProfile == profile.profile || (!profile.supported && chosenProfile == "trimmed"))
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        } header: {
            Text("Services")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trimmed turns off about 140 launch daemons a research machine rarely needs; None turns back on only those it turned off. Either takes effect when the guest restarts.")
                if profile?.supported == false {
                    Text("This iOS version has no trimmed list.")
                }
                if let profileNote {
                    Text(verbatim: profileNote)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The guest's own word, or a change Launchpad applied that the guest
    /// no longer reports: switching to None clears its record.
    private var needsRestart: Bool {
        profile?.rebootRequired == true || restartPending
    }

    // MARK: - Apps

    private var appsSection: some View {
        Section {
            if let removedApps {
                if removedApps.isEmpty {
                    Text("No system app was removed.").foregroundStyle(.secondary)
                } else {
                    ForEach(removedApps) { app in
                        Toggle(isOn: Binding(
                            get: { selectedApps.contains(app.id) },
                            set: { selected in
                                if selected {
                                    selectedApps.insert(app.id)
                                } else {
                                    selectedApps.remove(app.id)
                                }
                            },
                        )) {
                            HStack {
                                Text(verbatim: app.name)
                                Spacer()
                                Text(verbatim: app.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!app.restorable)
                    }
                    HStack {
                        Spacer()
                        Button("Restore Selected") { Task { await restoreApps() } }
                            .disabled(isWorking || selectedApps.isEmpty)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        } header: {
            Text("Removed System Apps")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The template's setup boot removed these and kept a backup in the guest. A restored app returns to the Home Screen after SpringBoard restarts.")
                if let appsNote {
                    Text(verbatim: appsNote)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Calls

    private func load() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                profile = VPhoneLaunchpadServiceProfile(VPhoneLaunchpadPreview.serviceProfile)
                chosenProfile = profile?.profile ?? "trimmed"
                restartPending = VPhoneLaunchpadPreview.guestSystemRestartPending
                profileNote = restartPending ? String(localized: "\(0) turned off, \(141) turned back on.") : nil
                removedApps = VPhoneLaunchpadRemovedApp.list(VPhoneLaunchpadPreview.removedSystemApps)
                selectedApps = ["com.apple.news"]
                return
            }
        #endif
        loadError = nil
        do {
            let state = try await VPhoneLaunchpadServiceProfile(library.guestCall(machine, "services.profile"))
            profile = state
            chosenProfile = state.profile
            restartPending = await library.isGuestRestartPending(machine)
            removedApps = try await VPhoneLaunchpadRemovedApp.list(library.guestCall(machine, "apps.removed_system"))
            selectedApps.formIntersection(Set(removedApps?.map(\.id) ?? []))
        } catch {
            loadError = VPhoneLaunchpadError.message(for: error)
        }
    }

    private func applyProfile() async {
        guard let profile else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        var params: [String: Any] = ["profile": chosenProfile, "force": true]
        if chosenProfile == "trimmed" {
            params["groups"] = profile.groups
            params["allow"] = profile.allow
        }
        // The boot the change is made in, to tell when the guest has restarted.
        let boot = await library.guestBoot(machine)
        do {
            let result = try await library.guestCall(machine, "services.profile.apply", params)
            library.recordServiceProfileApply(machine, result: result, boot: boot)
            restartPending = library.pendingGuestRestarts[machine] != nil
            let disabled = (result["disabled"] as? [Any])?.count ?? 0
            let enabled = (result["enabled"] as? [Any])?.count ?? 0
            let failed = (result["failed"] as? [Any])?.count ?? 0
            var note = String(localized: "\(disabled) turned off, \(enabled) turned back on.")
            if failed > 0 {
                note += " " + String(localized: "\(failed) could not be changed.")
            }
            profileNote = note
            self.profile = try await VPhoneLaunchpadServiceProfile(library.guestCall(machine, "services.profile"))
        } catch {
            self.error = VPhoneLaunchpadError(String(localized: "Unable to Change the Service Profile"), detail: VPhoneLaunchpadError.message(for: error))
        }
    }

    /// Restarts the guest, then waits up to three minutes for it to answer
    /// from a new boot and reads its state again.
    private func restartGuest() async {
        isWorking = true
        defer { isWorking = false }
        let waiting = await VPhoneLaunchpadPendingRestart(boot: library.guestBoot(machine))
        do {
            _ = try await library.guestCall(machine, "system.reboot", ["force": true], timeout: 30)
            profileNote = String(localized: "The guest is restarting.")
        } catch {
            self.error = VPhoneLaunchpadError(String(localized: "Unable to Restart the Guest"), detail: VPhoneLaunchpadError.message(for: error))
            return
        }
        for _ in 0 ..< 60 {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isRunning else {
                return
            }
            if await waiting.hasRestarted(currentBoot: library.guestBoot(machine)) {
                profileNote = String(localized: "The guest has restarted.")
                library.forgetPendingRestart(machine)
                await load()
                return
            }
        }
    }

    private func restoreApps() async {
        isWorking = true
        defer { isWorking = false }
        let identifiers = selectedApps.sorted()
        do {
            let result = try await library.guestCall(machine, "apps.restore_system", ["bundle_ids": identifiers, "force": true])
            let results = result["results"] as? [[String: Any]] ?? []
            let restored = results.filter { $0["status"] as? String == "restored" }.count
            appsNote = String(localized: "^[\(restored) app](inflect: true) restored.")
            selectedApps = []
        } catch {
            self.error = VPhoneLaunchpadError(String(localized: "Unable to Restore the Apps"), detail: VPhoneLaunchpadError.message(for: error))
        }
        removedApps = try? await VPhoneLaunchpadRemovedApp.list(library.guestCall(machine, "apps.removed_system"))
    }
}
