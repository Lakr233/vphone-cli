import SwiftUI

struct VPhoneDeviceInfoView: View {
    @Bindable var model: VPhoneDeviceInfoModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            VPhoneGuestToolStatusBar(
                isConnected: model.control.isConnected,
                activity: model.isLoading && !model.hasInfo
                    ? String(localized: "Reading device information…", bundle: VPhoneLocalization.bundle)
                    : nil,
                status: model.status,
            )
        }
        .toolbar { toolbar }
        .guestToolShortcuts([
            VPhoneGuestToolShortcut(key: "r", isEnabled: !model.isLoading) {
                Task { await model.refresh() }
            },
            VPhoneGuestToolShortcut(key: "c", modifiers: [.command, .shift], isEnabled: model.canCopyJSON) {
                model.copyJSON()
            },
        ])
        // Restarts when Auto Refresh changes and stops when the window closes.
        .task(id: model.autoRefresh) {
            if !model.hasInfo, model.control.isConnected {
                await model.refresh()
            }
            while model.autoRefresh, !Task.isCancelled {
                try? await Task.sleep(for: VPhoneDeviceInfoModel.autoRefreshInterval)
                guard model.autoRefresh, !Task.isCancelled else { break }
                guard model.control.isConnected else { continue }
                await model.refresh(polling: model.hasInfo)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.autoRefresh) {
                Label("Auto Refresh", systemImage: "timer")
            }
            .toggleStyle(.button)
            .help("Refresh every 5 seconds while this window is open")

            Button("Copy as JSON", systemImage: "curlybraces") { model.copyJSON() }
                .help("Copy the raw device.info response as JSON (⇧⌘C)")
                .disabled(!model.canCopyJSON)

            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .help("Read the device information again (⌘R)")
                .disabled(model.isLoading)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.hasInfo {
            readout
        } else if model.isLoading {
            ProgressView()
        } else if !model.control.isConnected {
            VPhonePanelEmptyState(
                title: "Guest Not Connected",
                systemImage: "iphone.slash",
                message: "Device information appears once vphoned connects. Start the VM, then choose Refresh.",
            )
        } else {
            VPhonePanelEmptyState(
                title: "No Device Information",
                systemImage: "iphone",
                message: "Choose Refresh to read the device again.",
            )
        }
    }

    private var readout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 6) {
                    ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                        GridRow {
                            sectionHeader(section.title, divided: index > 0)
                                .gridCellColumns(3)
                        }
                        ForEach(section.rows) { row in
                            GridRow {
                                Text(row.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .gridColumnAlignment(.trailing)
                                    .padding(.trailing, 6)
                                VPhoneDeviceInfoToneDot(tone: row.tone)
                                VPhoneDeviceInfoValue(row: row) { model.copyValue(row.value) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(String(localized: "Network", bundle: VPhoneLocalization.bundle), divided: true)
                    networkTable
                }
            }
            .padding(16)
        }
    }

    private func sectionHeader(_ title: String, divided: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if divided {
                Divider()
                    .padding(.top, 4)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Network

    @ViewBuilder
    private var networkTable: some View {
        let rows = model.sortedAddresses
        if rows.isEmpty {
            Text("The guest reported no IPv4 or IPv6 addresses.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Table(rows, selection: $model.selectedAddresses, sortOrder: $model.addressSortOrder) {
                TableColumn("Interface", value: \.interface) { row in
                    VPhonePanelMonoText(row.interface)
                }
                .width(min: 56, ideal: 72, max: 96)
                TableColumn("Family", value: \.family) { row in
                    VPhonePanelMonoText(row.family, secondary: true)
                }
                .width(min: 44, ideal: 52, max: 60)
                TableColumn("Address", value: \.address) { row in
                    VPhonePanelMonoText(row.address)
                }
                .width(min: 140, ideal: 280)
            }
            .contextMenu(forSelectionType: VPhoneDeviceNetworkAddress.ID.self) { ids in
                Button("Copy Address") { model.copyAddresses(ids, full: false) }
                    .disabled(ids.isEmpty)
                Button("Copy Row") { model.copyAddresses(ids, full: true) }
                    .disabled(ids.isEmpty)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            // Sized to its rows so the readout scrolls as one page; long
            // lists scroll inside the table past twelve rows.
            .frame(height: 28 + 24 * CGFloat(min(rows.count, 12)))
            .accessibilityLabel("Network addresses")
        }
    }
}

// MARK: - Value

/// A selectable monospace value with an optional capacity bar.
private struct VPhoneDeviceInfoValue: View {
    let row: VPhoneDeviceInfoRow
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            valueText
            if let gauge = row.gauge {
                VPhoneDeviceInfoCapacityBar(fraction: gauge, color: row.tone?.color ?? .accentColor)
                    .frame(maxWidth: 240)
            }
        }
        .contextMenu {
            Button("Copy") { copy() }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var valueText: some View {
        let text = Text(row.value)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        if row.truncatesMiddle {
            text
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.value)
        } else {
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Capacity Bar

private struct VPhoneDeviceInfoCapacityBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Tone Dot

/// The status dot column, kept even when empty so every value starts at the
/// same x.
private struct VPhoneDeviceInfoToneDot: View {
    let tone: VPhoneDeviceInfoRow.Tone?

    var body: some View {
        Circle()
            .fill(tone?.color ?? .clear)
            .frame(width: 6, height: 6)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}
