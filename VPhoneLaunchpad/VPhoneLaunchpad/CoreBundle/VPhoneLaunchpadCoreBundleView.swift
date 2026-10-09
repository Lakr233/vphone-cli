import SwiftUI
import UniformTypeIdentifiers

struct VPhoneLaunchpadCoreBundleView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removal: String?

    private var bundles: VPhoneLaunchpadCoreBundle {
        model.bundles
    }

    private var notInstalled: [VPhoneLaunchpadRelease] {
        bundles.releases.filter { release in !bundles.installed.contains { $0.version == release.version } }
    }

    var body: some View {
        @Bindable var bundles = bundles
        VPhoneLaunchpadSheet(Text("Core Bundle")) {
            Form {
                if !bundles.installed.isEmpty {
                    installedSection
                }
                availableSection
            }
            .formStyle(.grouped)
        } accessory: {
            Button("Check for Updates") {
                Task { await bundles.refresh() }
            }
            .help("Reload releases and builds, and run host preflight again.")
            .disabled(bundles.isInstalling)
            Button("Install Local Build…") {
                chooseLocalBuild()
            }
            .help(model.canInstallBundles
                ? "Install a VPhone.bundle folder or .zip built on this Mac."
                : "Installing needs the privileged helper and Developer Tools access.")
            .disabled(!model.canInstallBundles)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 520)
        .errorAlert($bundles.actionError)
        .confirmationDialog(
            "Remove VPhone.bundle \(removal ?? "")?",
            isPresented: Binding(get: { removal != nil }, set: {
                if !$0 {
                    removal = nil
                }
            }),
        ) {
            Button("Remove", role: .destructive) {
                if let version = removal {
                    Task { await model.removeBundle(version) }
                }
            }
        } message: {
            let users = removal.map(model.machines.machineNames(boundTo:)) ?? []
            if users.isEmpty {
                Text("Machines are not affected. You can install this version again later.")
            } else {
                Text("\(users.formatted(.list(type: .and))) use this version and will be marked Damaged until you choose another Core Bundle for them or install it again.")
            }
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        Section {
            ForEach(bundles.installed) { bundle in
                installedRow(bundle)
            }
        } header: {
            Text("Installed")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("New machines use the default version. Each machine keeps its own Core Bundle, which you change from the machine list.")
                Text("Stored in \(VPhoneLaunchpadBundleStore.root.path) and managed by the helper.")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func installedRow(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> some View {
        let isDefault = bundle.version == bundles.defaultVersion
        let users = model.machines.machineNames(boundTo: bundle.version)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "VPhone.bundle \(bundle.version)")
                    if isDefault {
                        Text("Default")
                            .foregroundStyle(.green)
                            .help("Used for new machines.")
                    }
                }
                Group {
                    if VPhoneLaunchpadLocalBundle.isLocal(version: bundle.version) {
                        if let build = Self.localBuild(bundle.version) {
                            Text("Local build \(build) · Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .shortened)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                        } else {
                            Text("Local build · Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .shortened)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                        }
                    } else if bundle.version != VPhoneLaunchpadNames.bundleVersion(of: bundle.version) {
                        Text("GitHub Actions build · Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .shortened)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                    } else {
                        Text("Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .omitted)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                    }
                    usersLabel(users)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Label {
                Text(checkSummary(bundle))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: checkStatus(bundle))
            }
            .font(.callout)
            .help(checkHelp(bundle))
            Menu {
                Button("Set as Default") { Task { await bundles.setDefault(bundle.version) } }
                    .disabled(isDefault || !VPhoneLaunchpadNames.isCompatibleBundleVersion(bundle.version))
                Button("Run Preflight Again") { Task { await bundles.verify(bundle.version) } }
                    .disabled(!VPhoneLaunchpadNames.isCompatibleBundleVersion(bundle.version))
                if bundles.isAccepted(bundle.version) {
                    Button("Require Preflight") { bundles.setAccepted(bundle.version, false) }
                } else if bundle.preflight == .failed, VPhoneLaunchpadNames.isCompatibleBundleVersion(bundle.version) {
                    Button("Use Without Preflight") { bundles.setAccepted(bundle.version, true) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([VPhoneLaunchpadBundleStore.bundle(version: bundle.version)])
                }
                Divider()
                Button("Remove…", role: .destructive) { removal = bundle.version }
                    .disabled(bundles.isInstalling)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Names a few machines; past that, a count with the names in the help.
    @ViewBuilder
    private func usersLabel(_ users: [String]) -> some View {
        if users.isEmpty {
            Text("Not used by any machine")
        } else if users.count <= 3 {
            Text("Used by \(users.formatted(.list(type: .and)))")
        } else {
            Text("Used by \(users.count) machines")
                .help(users.formatted(.list(type: .and)))
        }
    }

    /// The build identifier of a `-local.<build>` version; nil for the bare
    /// `-local` an older Launchpad used.
    static func localBuild(_ version: String) -> String? {
        guard VPhoneLaunchpadLocalBundle.isLocal(version: version),
              let marker = version.range(of: "\(VPhoneLaunchpadLocalBundle.versionSuffix).", options: .backwards)
        else { return nil }
        return String(version[marker.upperBound...])
    }

    /// Policy exception and preflight folded into one status: the worst of
    /// the two, with a skipped preflight shown as a warning.
    private func checkStatus(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> VPhoneLaunchpadStatus {
        if bundle.policy == .running || bundle.preflight == .running {
            return .running
        }
        if bundle.policy == .passed, bundle.preflight == .passed {
            return .passed
        }
        if bundles.isAccepted(bundle.version) {
            return .warning
        }
        return bundle.policy == .pending && bundle.preflight == .pending ? .pending : .failed
    }

    private func checkSummary(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> String {
        switch checkStatus(bundle) {
        case .running: String(localized: "Checking…")
        case .passed: String(localized: "Preflight passed")
        case .warning: String(localized: "Preflight skipped")
        case .pending: String(localized: "Not checked")
        case .failed: bundle.policy != .passed ? String(localized: "Not allowed to run") : String(localized: "Preflight failed")
        }
    }

    private func checkHelp(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> String {
        let policy = bundle.policy == .passed ? String(localized: "Allowed to run.") : String(localized: "Not allowed to run.")
        return bundle.preflightDetail.isEmpty ? policy : "\(policy)\n\(bundle.preflightDetail)"
    }

    // MARK: - Available

    private var availableSection: some View {
        Section {
            if let error = bundles.releasesError, bundles.releases.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if bundles.releases.isEmpty, bundles.isFetchingReleases {
                loadingRow("Loading releases…")
            } else if bundles.releases.isEmpty {
                Text("No versions available.")
                    .foregroundStyle(.secondary)
            } else if notInstalled.isEmpty {
                Text("Every release is installed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notInstalled) { release in
                    releaseRow(release, prominent: release == bundles.availableUpdate)
                }
            }
        } header: {
            Text("Available")
        }
    }

    private func loadingRow(_ title: LocalizedStringKey) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func releaseRow(_ release: VPhoneLaunchpadRelease, prominent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "VPhone.bundle \(release.version)")
                    if release.isPrerelease {
                        Text("Pre-release")
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: "\(release.publishedAt.formatted(date: .abbreviated, time: .omitted)) · \(Self.size(release.size)) · SHA-256 \(Self.shortDigest(release.sha256))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if prominent {
                Button("Download and Install") { Task { await model.installBundle(release) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canInstallBundles)
            } else {
                Button("Download and Install") { Task { await model.installBundle(release) } }
                    .disabled(!model.canInstallBundles)
            }
        }
        .help(model.canInstallBundles ? "" : "Installing needs the privileged helper and Developer Tools access.")
    }

    // MARK: - Local build

    private func chooseLocalBuild() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Install Local Build")
        panel.message = String(localized: "Choose a VPhone.bundle folder or a .zip that contains one.")
        panel.prompt = String(localized: "Install")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .bundle]
        panel.present { url in
            Task { await model.installLocalBundle(url) }
        }
    }

    // MARK: - Formatting

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func shortDigest(_ digest: String) -> String {
        "\(digest.prefix(8))…"
    }
}
