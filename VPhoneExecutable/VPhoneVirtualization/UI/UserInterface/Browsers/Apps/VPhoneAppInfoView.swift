import SwiftUI

// MARK: - App Info Inspector

/// The trailing inspector: `apps.info`, `apps.binary`, URL schemes and the
/// CoreTelephony network policy of the selected app.
struct VPhoneAppInfoView: View {
    let model: VPhoneAppBrowserModel

    var body: some View {
        if let detail = model.detail, model.selectedApp?.id == detail.bundleID {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(detail)
                    bundleSection(detail)
                    containerSection(detail)
                    schemeSection(detail)
                    binarySection(detail)
                    entitlementSection(detail)
                    networkSection(detail)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.selection.count > 1 {
            VPhonePanelEmptyState(
                title: "Multiple Apps Selected",
                systemImage: "square.stack",
                message: "Select one app to see its info.",
            )
        } else {
            VPhonePanelEmptyState(
                title: "No App Selected",
                systemImage: "info.circle",
                message: "Select an app to see its bundle, binary and data container.",
            )
        }
    }

    // MARK: - Header

    private func header(_ detail: VPhoneAppDetail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(detail.bundleID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if model.isLoadingDetail {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Sections

    private func bundleSection(_ detail: VPhoneAppDetail) -> some View {
        VPhoneAppInfoSection(title: "Bundle", error: detail.infoError) {
            VPhoneAppInfoGrid(rows: [
                ("Version", detail.version),
                ("Build", detail.build),
                ("Type", detail.type),
                ("Signer", detail.signer),
                ("Minimum OS", detail.minimumOS),
                ("SDK", detail.sdk),
                ("Path", detail.bundlePath),
                ("Executable", detail.executable),
            ])
        }
    }

    private func containerSection(_ detail: VPhoneAppDetail) -> some View {
        VPhoneAppInfoSection(title: "Data Container") {
            if detail.dataPath.isEmpty {
                placeholder(detail.hasInfo ? "This app has no data container." : "Loading…")
            } else {
                VPhoneAppInfoValue(value: detail.dataPath)
                HStack(spacing: 8) {
                    Button("Show in Files") { model.reveal(path: detail.dataPath) }
                        .help("Open the File Browser at the data container")
                    Button("Copy Path") { model.copy([detail.dataPath]) }
                }
                .controlSize(.small)
            }
            if !detail.groupContainers.isEmpty {
                Text("App Groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(detail.groupContainers) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        VPhoneAppInfoValue(value: group.identifier)
                        VPhoneAppInfoValue(value: group.path, secondary: true)
                    }
                    .contextMenu {
                        Button("Show in Files") { model.reveal(path: group.path) }
                        Button("Copy Path") { model.copy([group.path]) }
                    }
                }
            }
        }
    }

    private func schemeSection(_ detail: VPhoneAppDetail) -> some View {
        VPhoneAppInfoSection(title: "URL Schemes") {
            if detail.urlSchemes.isEmpty {
                placeholder(detail.hasInfo ? "This app declares no URL schemes." : "Loading…")
            } else {
                VPhoneAppInfoValue(value: detail.urlSchemes.map { "\($0)://" }.joined(separator: "\n"))
            }
        }
    }

    private func binarySection(_ detail: VPhoneAppDetail) -> some View {
        VPhoneAppInfoSection(title: "Mach-O", error: detail.binaryError) {
            VPhoneAppInfoGrid(rows: [
                ("Encrypted", detail.encrypted.map { $0 ? String(localized: "Yes (FairPlay)", bundle: VPhoneLocalization.bundle) : String(localized: "No", bundle: VPhoneLocalization.bundle) } ?? ""),
                ("Entitlements", detail.hasBinary || detail.hasInfo ? String(detail.entitlements.count) : ""),
            ])
            if let error = detail.signingError {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func entitlementSection(_ detail: VPhoneAppDetail) -> some View {
        VPhoneAppInfoSection(title: "Entitlements") {
            if detail.entitlements.isEmpty {
                placeholder(detail.hasBinary || detail.hasInfo ? "The binary has no entitlements." : "Loading…")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detail.entitlements) { entitlement in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entitlement.key)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text(entitlement.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    }
                }
                Button("Copy as Property List") { model.copy([detail.entitlementsPlist]) }
                    .controlSize(.small)
                    .help("Copy the entitlements as an XML property list")
            }
        }
    }

    private func networkSection(_ detail: VPhoneAppDetail) -> some View {
        VPhoneAppInfoSection(title: "Network Policy", error: detail.networkPolicyError) {
            if let policy = detail.networkPolicy {
                Label {
                    Text(policy.allowed ? "Wi-Fi and cellular data allowed" : "Network access may be restricted")
                } icon: {
                    Image(systemName: policy.allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(policy.allowed ? .green : .orange)
                }
                .font(.system(size: 11))
                if !policy.entries.isEmpty {
                    VPhoneAppInfoGrid(rows: policy.entries.map { ($0.title, $0.value) }, localizeTitles: false)
                }
                Button("Repair") { Task { await model.repairNetworkPolicy() } }
                    .controlSize(.small)
                    .disabled(policy.allowed || model.isBusy || !model.control.isConnected)
                    .help("Allow Wi-Fi and cellular data for this app")
            } else if detail.networkPolicyError == nil {
                placeholder("Loading…")
            }
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Section

struct VPhoneAppInfoSection<Content: View>: View {
    let title: LocalizedStringKey
    var error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Divider()
            if let error {
                Label {
                    Text(error)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 11))
            }
            content
        }
    }
}

// MARK: - Key-Value Grid

/// Label and value rows; empty values are left out.
struct VPhoneAppInfoGrid: View {
    let rows: [(String, String)]
    var localizeTitles = true

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(rows.filter { !$0.1.isEmpty }, id: \.0) { title, value in
                GridRow {
                    Group {
                        if localizeTitles {
                            Text(LocalizedStringKey(title))
                        } else {
                            Text(verbatim: title)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                    VPhoneAppInfoValue(value: value)
                }
            }
        }
    }
}

/// A selectable monospaced value that wraps long paths instead of clipping.
struct VPhoneAppInfoValue: View {
    let value: String
    var secondary = false

    var body: some View {
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(secondary ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
