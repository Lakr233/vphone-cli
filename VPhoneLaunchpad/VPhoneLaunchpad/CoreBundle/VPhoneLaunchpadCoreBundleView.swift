import SwiftUI

struct VPhoneLaunchpadCoreBundleView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var removal: String?

    private var bundles: VPhoneLaunchpadCoreBundle {
        model.bundles
    }

    private var notInstalled: [VPhoneLaunchpadRelease] {
        bundles.releases.filter { release in !bundles.installed.contains { $0.version == release.version } }
    }

    var body: some View {
        Form {
            if let progress = bundles.progress {
                progressSection(progress)
            }
            if bundles.installed.isEmpty {
                latestSection
            } else {
                installedSection
                if !notInstalled.isEmpty {
                    availableSection
                }
            }
            Section {
                LabeledContent("Location", value: VPhoneLaunchpadBundleStore.root.path)
                LabeledContent("Owner", value: "root:wheel, written only by the helper")
            } header: {
                Text("Store")
            } footer: {
                if bundles.installed.isEmpty {
                    Text("Machines appears once a bundle is installed and passes host preflight.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await bundles.refresh() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .help("List releases again and rerun host preflight")
                .disabled(bundles.isInstalling)
            }
        }
        .confirmationDialog(
            "Remove VPhone.bundle \(removal ?? "")?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        ) {
            Button("Remove", role: .destructive) {
                if let version = removal {
                    Task { await model.removeBundle(version) }
                }
            }
        } message: {
            Text("Machines are not affected. You can install this version again later.")
        }
    }

    // MARK: - Latest

    @ViewBuilder
    private var latestSection: some View {
        Section("Latest Release") {
            if let latest = bundles.releases.first {
                releaseRow(latest, prominent: true)
            } else if let error = bundles.releasesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading releases…").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Progress

    private func progressSection(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> some View {
        Section {
            if progress.status(.download) == .running {
                ProgressView(value: Double(progress.received), total: Double(max(progress.release.size, 1))) {
                    Text("Downloading")
                } currentValueLabel: {
                    Text("\(Self.size(progress.received)) of \(Self.size(progress.release.size))")
                }
            }
            ForEach(VPhoneLaunchpadCoreBundle.InstallStep.allCases) { step in
                Label {
                    Text(step.title)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: progress.status(step))
                }
            }
            if let error = progress.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.message).foregroundStyle(.red)
                    if let detail = error.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            HStack {
                Text("Installing \(progress.release.version)")
                Spacer()
                if !bundles.isInstalling {
                    Button("Dismiss") { bundles.dismissProgress() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        Section("Installed") {
            ForEach(bundles.installed) { bundle in
                installedRow(bundle)
            }
        }
    }

    private func installedRow(_ bundle: VPhoneLaunchpadCoreBundle.Installed) -> some View {
        let isActive = bundle.version == bundles.activeVersion
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // The version in use is the one with the green title.
                Text("VPhone.bundle \(bundle.version)")
                    .foregroundStyle(isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    .accessibilityValue(isActive ? "In use" : "")
                    .help(isActive ? "In use" : "")
                Text("Installed \(bundle.receipt.installedAt.formatted(date: .abbreviated, time: .omitted)) · SHA-256 \(Self.shortDigest(bundle.receipt.sha256))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label {
                Text(bundle.policy == .passed ? "Policy exception" : "No policy exception")
            } icon: {
                VPhoneLaunchpadStatusIcon(status: bundle.policy)
            }
            .font(.callout)
            Label {
                Text(bundle.preflight == .passed ? "Preflight passed" : bundle.preflightDetail.isEmpty ? "Preflight" : bundle.preflightDetail)
                    .lineLimit(1)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: bundle.preflight)
            }
            .font(.callout)
            .help(bundle.preflightDetail)
            Menu {
                Button("Use This Version") { Task { await bundles.use(bundle.version) } }
                    .disabled(isActive)
                Button("Run Preflight Again") { Task { await bundles.verify(bundle.version) } }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([VPhoneLaunchpadBundleStore.bundle(version: bundle.version)])
                }
                Divider()
                Button("Remove…", role: .destructive) { removal = bundle.version }
                    .disabled(bundles.isInstalling)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Available

    private var availableSection: some View {
        Section("Available") {
            ForEach(notInstalled) { release in
                releaseRow(release, prominent: release == bundles.availableUpdate)
            }
        }
    }

    private func releaseRow(_ release: VPhoneLaunchpadRelease, prominent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("VPhone.bundle \(release.version)")
                    if release.isPrerelease {
                        Text("Pre-release")
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(release.publishedAt.formatted(date: .abbreviated, time: .omitted)) · \(Self.size(release.size)) · SHA-256 \(Self.shortDigest(release.sha256))")
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

    // MARK: - Formatting

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func shortDigest(_ digest: String) -> String {
        "\(digest.prefix(8))…"
    }
}
