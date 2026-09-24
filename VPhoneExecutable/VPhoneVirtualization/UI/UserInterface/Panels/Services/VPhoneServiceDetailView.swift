import SwiftUI

/// Key facts for the selected service beside launchd's `print` description.
struct VPhoneServiceDetailView: View {
    let model: VPhoneServicesModel

    var body: some View {
        if let row = model.selectedRow {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    facts(row)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: 280)
                Divider()
                description(row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VPhonePanelEmptyState(
                title: "No Service Selected",
                systemImage: "doc.text.magnifyingglass",
                message: "Select a service to see launchd's description.",
            )
        }
    }

    // MARK: - Facts

    private func facts(_ row: VPhoneServiceRow) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            wrappingFact("Label", row.label)
            GridRow {
                title("State")
                VPhoneServiceStateLabel(isRunning: row.isRunning)
                    .font(.system(size: 11, design: .monospaced))
            }
            fact("PID", row.pidText)
            GridRow {
                title("Last Exit")
                Text(row.lastExit.text + (row.lastExitStatus.map { $0 == 0 ? "" : "  (\($0))" } ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(row.lastExit.isAbnormal ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .help(row.lastExit.help)
            }
            fact("Disabled", row.disabledText)
            fact("Domains", row.domainText.isEmpty ? "—" : row.domainText)
            wrappingFact("Program", row.program ?? "—")
            if let detail = model.detail, detail.label == row.label {
                fact("Printed From", detail.domain)
            }
        }
        .textSelection(.enabled)
    }

    private func fact(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            title(key)
            VPhonePanelMonoText(value)
        }
    }

    /// A long label or path, wrapped to three lines before it truncates.
    private func wrappingFact(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            title(key)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
    }

    private func title(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: VPhoneLocalization.bundle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: - Description

    @ViewBuilder
    private func description(_ row: VPhoneServiceRow) -> some View {
        if let detail = model.detail, detail.label == row.label {
            ScrollView {
                Text(detail.text.isEmpty ? String(localized: "launchd returned an empty description.", bundle: VPhoneLocalization.bundle) : detail.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(detail.text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("launchd description of \(row.label)")
        } else if let error = model.detailError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
