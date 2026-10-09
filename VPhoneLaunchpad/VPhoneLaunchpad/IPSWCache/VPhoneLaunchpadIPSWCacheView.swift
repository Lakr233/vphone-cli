import AppKit
import SwiftUI

// MARK: - Downloaded Firmware

/// The IPSWs `fw prepare` has downloaded, with Delete. The files are those in
/// the shared IPSW cache and in the `ipsws` folder beside each library,
/// named by their BuildManifest and, when the default Core Bundle's `fw
/// catalog` lists them, by the catalog. A machine uses an IPSW when its
/// restore-info.json names that release (and its product type is among the
/// IPSW's), or when its creation was given the IPSW as a source.
struct VPhoneLaunchpadIPSWCacheView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil until the first scan answers.
    @State private var scan: VPhoneLaunchpadIPSWCache.Scan?
    @State private var catalog: VPhoneLaunchpadIPSWCatalogNames?
    @State private var selection: Set<VPhoneLaunchpadIPSWRow.ID> = []
    /// Empty keeps the order the rows are built in; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadIPSWRow>] = []
    /// The rows the delete confirmation is for; empty when it is closed.
    @State private var deletion: [VPhoneLaunchpadIPSWRow] = []
    @State private var isDeleting = false
    @State private var actionError: VPhoneLaunchpadError?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var rows: [VPhoneLaunchpadIPSWRow] {
        guard let scan else {
            return []
        }
        return VPhoneLaunchpadIPSWRows.rows(scan.ipsws, catalog: catalog, uses: uses(scan), isCreating: library.hasActiveCreation)
            .sorted(using: sortOrder)
    }

    private var selected: [VPhoneLaunchpadIPSWRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// What deleting the selection would break, for the first row it would.
    private var deletionWarning: String? {
        selected.lazy.compactMap(\.deletionWarning).first
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Downloaded Firmware"), width: VPhoneLaunchpadSheetSize.wide) {
            VStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let warning = deletionWarning {
                    Divider()
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        } accessory: {
            Button("Delete…") { confirmDeletion() }
                .disabled(selected.isEmpty || isDeleting)
                .help("Delete the selected IPSWs from the IPSW cache.")
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 440)
        // Again whenever the machines or creations change, and every few
        // seconds while a creation runs, since its download grows.
        .task(id: scanKey) {
            await rescan()
            while library.hasActiveCreation, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await rescan()
            }
        }
        .task(id: model.bundles.defaultVersion) { await loadCatalog() }
        .confirmationDialog(
            deletion.count == 1 ? String(localized: "Delete \(deletion[0].title)?") : String(localized: "Delete \(deletion.count) IPSWs?"),
            isPresented: Binding(get: { !deletion.isEmpty }, set: {
                if !$0 {
                    deletion = []
                }
            }),
            presenting: deletion,
        ) { rows in
            Button(String(localized: "Delete \(Self.size(rows.reduce(0) { $0 + $1.size }))"), role: .destructive) {
                Task { await delete(rows) }
            }
        } message: { rows in
            Text(rows.map(VPhoneLaunchpadIPSWRows.deletionMessage).joined(separator: "\n\n"))
        }
        .errorAlert($actionError)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if scan == nil {
            ProgressView()
                .controlSize(.small)
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No Downloaded Firmware", systemImage: "briefcase")
            } description: {
                Text("The IPSWs a machine is created from are downloaded into the IPSW cache and listed here.")
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Image", value: \.title) { row in
                Text(row.isDownloading ? String(localized: "\(row.title) (partial download)") : row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.fileName)
            }
            .width(min: 140, ideal: 230)
            TableColumn("Kind", value: \.kindLabel) { row in
                Text(verbatim: row.kindLabel)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Device", value: \.devices) { row in
                Text(verbatim: row.devices)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.devices)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Size", value: \.size) { row in
                Text(verbatim: Self.size(row.size))
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 64)
            .alignment(.numeric)
            TableColumn(Text(verbatim: "")) { row in
                Button {
                    showInFinder(row)
                } label: {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            .width(20)
        }
        .contextMenu(forSelectionType: VPhoneLaunchpadIPSWRow.ID.self) { ids in
            Button("Show in Finder") { showInFinder(ids) }
                .disabled(ids.isEmpty)
            Divider()
            Button("Delete…", role: .destructive) {
                selection = ids
                confirmDeletion()
            }
            .disabled(ids.isEmpty || isDeleting)
        }
        .onDeleteCommand { confirmDeletion() }
        .vphoneFocusedOnAppear()
    }

    private func showInFinder(_ row: VPhoneLaunchpadIPSWRow) {
        showInFinder([row.id])
    }

    private func showInFinder(_ ids: Set<VPhoneLaunchpadIPSWRow.ID>) {
        let urls = (scan?.ipsws ?? []).filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Data

    /// Changes when a scan, or the uses read from the library, would change.
    private var scanKey: [String] {
        let machines = library.machines.map { machine in
            "\(machine.libraryRoot)/\(machine.name):\(machine.restoreInfo.map { "\($0.ios.build)+\($0.cloudOS.build)" } ?? "")"
        }
        let creations = library.creations.map { path, creation in
            "\(path.libraryRoot)/\(path.name):\(creation.isRunning):\(creation.isFinished)"
        }
        return [library.hasListed ? "listed" : "unlisted"] + library.roots + machines + creations.sorted()
    }

    private func rescan() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                scan = VPhoneLaunchpadPreview.ipswScan
                if selection.isEmpty, let preview = VPhoneLaunchpadPreview.ipswSelection {
                    selection = [preview]
                }
                return
            }
        #endif
        do {
            let scan = try await VPhoneLaunchpadIPSWCache.scan(
                libraryRoots: library.roots,
                machineFolders: library.machines.map(\.path.url),
            )
            self.scan = scan
            selection.formIntersection(scan.ipsws.map(\.id))
        } catch {
            // Cancelled: the sheet closed or the machines changed again.
        }
    }

    /// Each listed machine, with the sources of its creation if it has one,
    /// then each creation whose machine is not listed yet.
    private func uses(_ scan: VPhoneLaunchpadIPSWCache.Scan) -> [VPhoneLaunchpadIPSWUse] {
        var uses: [VPhoneLaunchpadIPSWUse] = []
        for machine in library.machines {
            let creation = library.creations[machine.path]
            uses.append(VPhoneLaunchpadIPSWUse(
                machine: machine.name,
                productType: scan.productTypes[machine.path.url.path],
                ios: machine.restoreInfo.map { .init(version: $0.ios.version, build: $0.ios.build) },
                cloudOS: machine.restoreInfo.map { .init(version: $0.cloudOS.version, build: $0.cloudOS.build) },
                sources: creation.map { [$0.options.iphoneSource, $0.options.cloudOSSource] } ?? [],
                isCreating: creation?.isRunning == true,
                needsSources: creation.map { !$0.isFinished } ?? false,
            ))
        }
        for (path, creation) in library.creations where !library.machines.contains(where: { $0.path == path }) {
            uses.append(VPhoneLaunchpadIPSWUse(
                machine: path.name,
                sources: [creation.options.iphoneSource, creation.options.cloudOSSource],
                isCreating: creation.isRunning,
                needsSources: !creation.isFinished,
            ))
        }
        return uses
    }

    // MARK: - Catalog

    /// The catalog names of each Core Bundle version, read once per session.
    private static var catalogs: [String: VPhoneLaunchpadIPSWCatalogNames] = [:]

    private func loadCatalog() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                catalog = VPhoneLaunchpadPreview.catalog.map(VPhoneLaunchpadIPSWCatalogNames.init)
                return
            }
        #endif
        guard let version = model.bundles.defaultVersion,
              let commandLine = model.bundles.commandLine(version: version)
        else {
            return
        }
        if let known = Self.catalogs[version] {
            catalog = known
            return
        }
        // Without a catalog the rows are named from their manifests.
        guard let result = try? await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false),
              result.succeeded, let data = result.jsonData,
              let report = try? JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data)
        else {
            return
        }
        let names = VPhoneLaunchpadIPSWCatalogNames(report)
        Self.catalogs[version] = names
        catalog = names
    }

    // MARK: - Deleting

    /// Always asks first; the confirmation says what the deletion breaks.
    private func confirmDeletion() {
        let rows = selected
        guard !rows.isEmpty, !isDeleting else {
            return
        }
        deletion = rows
    }

    /// Stops at the first IPSW that cannot be removed.
    private func delete(_ rows: [VPhoneLaunchpadIPSWRow]) async {
        guard !isDeleting, let scan else {
            return
        }
        isDeleting = true
        defer { isDeleting = false }
        for row in rows {
            guard let file = scan.ipsws.first(where: { $0.id == row.id }) else {
                continue
            }
            let failure = String(localized: "Unable to Delete \(row.title)")
            do {
                try await VPhoneLaunchpadIPSWCache.removeIPSW(file.url, cacheDirectories: scan.cacheDirectories)
            } catch {
                actionError = VPhoneLaunchpadError(failure, detail: error.localizedDescription)
                break
            }
        }
        await rescan()
    }
}

extension VPhoneLaunchpadIPSWCatalogNames {
    /// Every iOS, iPadOS and cloudOS image the catalog names.
    init(_ catalog: VPhoneLaunchpadFirmwareCatalog) {
        self.init(images: catalog.guests.flatMap { device in
            device.pairings.flatMap { pairing in
                [(pairing.ios.name, pairing.ios.url), (pairing.recommendedCloudOS.name, pairing.recommendedCloudOS.url)]
            }
        })
    }
}
