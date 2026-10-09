import SwiftUI

/// The last Core Bundle install, as a sheet of its own. It opens when an
/// install starts and again on launch if the last one did not finish. Hiding
/// it leaves the install running; Core Bundle offers it again until then.
struct VPhoneLaunchpadInstallView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var bundles: VPhoneLaunchpadCoreBundle {
        model.bundles
    }

    var body: some View {
        @Bindable var bundles = bundles
        VPhoneLaunchpadSheet(Text("Core Bundle Install")) {
            Form {
                if let progress = bundles.progress {
                    Section {
                        summary(progress)
                        if progress.status(.download) == .running {
                            ProgressView(value: Double(progress.received), total: Double(max(progress.size, 1)))
                                .labelsHidden()
                        }
                    }
                    Section("Steps") {
                        steps(progress)
                    }
                    if let error = progress.error {
                        Section("Error") {
                            errorDetail(error)
                        }
                    }
                } else {
                    Text("No install to show.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .vphoneFittedHeight(limit: VPhoneLaunchpadSheetSize.maximum - VPhoneLaunchpadSheetSize.chrome)
        } accessory: {
            if let progress = bundles.progress, !bundles.isInstalling {
                if progress.canSkip {
                    Button("Skip") { bundles.skipFailedChecks() }
                        .help("Use this version without the failed checks.")
                }
                if progress.error != nil {
                    Button("Retry") {
                        Task { await model.retryInstall() }
                    }
                    .disabled(!model.canInstallBundles && progress.status(.install) != .passed)
                }
            }
        } actions: {
            if bundles.isInstalling {
                Button("Hide") { dismiss() }
                    .help("The install keeps running. Core Bundle shows it again.")
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Done") {
                    bundles.dismissProgress()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(bundles.isInstalling)
    }

    // MARK: - Summary

    private func summary(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> some View {
        HStack(spacing: 8) {
            VPhoneLaunchpadStatusIcon(status: progress.overall)
            Text(verbatim: progress.version.map { "VPhone.bundle \($0)" } ?? progress.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(state(progress))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func state(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> String {
        switch progress.overall {
        case .running: String(localized: "Installing…")
        case .failed where progress.status(.install) == .passed: String(localized: "Checks failed")
        case .failed: String(localized: "Not installed")
        case .warning: String(localized: "Checks skipped")
        default: String(localized: "Installed")
        }
    }

    // MARK: - Details

    private func steps(_ progress: VPhoneLaunchpadCoreBundle.InstallProgress) -> some View {
        ForEach(progress.plan) { step in
            HStack(spacing: 8) {
                VPhoneLaunchpadStatusIcon(status: progress.status(step))
                Text(step.title)
                Spacer(minLength: 8)
                if step == .download, progress.status(.download) == .running {
                    Text("\(VPhoneLaunchpadCoreBundleView.size(progress.received)) of \(VPhoneLaunchpadCoreBundleView.size(progress.size))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if progress.status(step) == .warning {
                    Text("Skipped")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func errorDetail(_ error: VPhoneLaunchpadError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.message)
            if let detail = error.detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
