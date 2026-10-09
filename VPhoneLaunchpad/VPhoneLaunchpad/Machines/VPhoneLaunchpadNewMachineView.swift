import AppKit
import SwiftUI

/// The name, guest device and firmware pairing from `fw catalog` on the
/// basic page; hardware and network, the template, its slimming, the Core
/// Bundle and custom IPSWs, patches, and restore files on six tabs of an Advanced
/// Options sheet over it, behind one row that sums them up.
/// Every setting has a default, so Create works without opening it. Create
/// hands off to the pipeline sheet.
struct VPhoneLaunchpadNewMachineView: View {
    let onCreate: (VPhoneLaunchpadMachinePath) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Half the host's cores, at least two.
    static let defaultCPU = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    static let defaultMemoryMB = 8192
    static let defaultDiskSizeGB = 64
    static let defaultNetwork = "nat"

    @State private var name = ""
    /// The Core Bundle picked here; nil follows the default version.
    @State private var chosenVersion: String?
    /// The canonical library the machine is created in.
    @State private var location = VPhoneLaunchpadMachineLocations.defaultRoot
    @State private var catalog: VPhoneLaunchpadFirmwareCatalog?
    @State private var catalogError: String?
    /// The names of the IPSWs already in an IPSW cache, to mark the releases
    /// that need no download.
    @State private var downloaded: Set<String> = []
    /// The guest device's product type.
    @State private var guest: String?
    @State private var pairing: String?
    @State private var usesCustomSources = false
    @State private var iphoneSource = ""
    @State private var cloudOSSource = ""
    @State private var cpu = Self.defaultCPU
    @State private var memoryMB = Self.defaultMemoryMB
    @State private var diskSizeGB = Self.defaultDiskSizeGB
    @State private var network = Self.defaultNetwork
    @State private var patches = VPhoneLaunchpadPatchSelection()
    @State private var patchCatalog: VPhoneLaunchpadPatchCatalog?
    @State private var patchCatalogError: String?
    @State private var keepArtifacts = false
    /// Clone the machine from a template, built first when there is none.
    @State private var usesTemplate = true
    @State private var slimming = VPhoneLaunchpadSlimming()
    /// The page the Advanced Options sheet shows: the one last shown.
    @State private var page = Page.hardware
    @State private var showsAdvanced = false

    /// The basic page, then the advanced ones.
    enum Page: Hashable {
        case basic, hardware, template, slimming, firmware, patches, storage
    }

    private var selectedGuest: VPhoneLaunchpadFirmwareCatalog.Device? {
        catalog?.guests.first { $0.id == guest }
    }

    /// The version every step of the creation runs with, and the one the
    /// firmware and patch catalogs are read from.
    private var bundleVersion: String? {
        let selectable = model.bundles.selectableVersions
        if let chosenVersion, selectable.contains(chosenVersion) {
            return chosenVersion
        }
        return model.bundles.defaultVersion ?? selectable.first
    }

    private var selectedPairing: VPhoneLaunchpadFirmwareCatalog.Pairing? {
        selectedGuest?.pairings.first { $0.id == pairing }
    }

    private var sources: (String, String)? {
        if usesCustomSources {
            let iphone = iphoneSource.trimmingCharacters(in: .whitespaces)
            let cloudOS = cloudOSSource.trimmingCharacters(in: .whitespaces)
            return iphone.isEmpty || cloudOS.isEmpty ? nil : (iphone, cloudOS)
        }
        return selectedPairing.map { ($0.ios.url, $0.recommendedCloudOS.url) }
    }

    private var effectiveName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var machine: VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: location, name: effectiveName)
    }

    private func isTaken(_ machine: VPhoneLaunchpadMachinePath) -> Bool {
        model.machines.machines.contains(where: { $0.path == machine })
            || model.machines.creations[machine] != nil
            || FileManager.default.fileExists(atPath: machine.url.path)
    }

    /// A fruit no machine in `root` is named after yet, at random, filled into
    /// the field when the sheet opens. Once all are taken, `<fruit>-2`, then
    /// `-3` and on.
    private func suggestedName(in root: String) -> String {
        let suffixes = [""] + (2 ... 99).map { "-\($0)" }
        for suffix in suffixes {
            let free = Self.fruits.map { $0 + suffix }.filter { !isTaken(VPhoneLaunchpadMachinePath(libraryRoot: root, name: $0)) }
            if let name = free.randomElement() {
                return name
            }
        }
        return "machine"
    }

    private static let fruits = [
        "Apple", "Apricot", "Avocado", "Banana", "Blackberry", "Blueberry", "Cherry", "Coconut",
        "Cranberry", "Date", "Durian", "Fig", "Grape", "Guava", "Kiwi", "Kumquat",
        "Lemon", "Lime", "Lychee", "Mango", "Melon", "Mulberry", "Nectarine", "Olive",
        "Orange", "Papaya", "Peach", "Pear", "Persimmon", "Pineapple", "Plum", "Pomegranate",
    ]

    private var nameProblem: String? {
        if !VPhoneLaunchpadNames.isValidMachineName(effectiveName) {
            return String(localized: "Use letters, numbers, periods, hyphens, and underscores.")
        }
        if model.machines.machines.contains(where: { $0.path == machine }) || model.machines.creations[machine]?.isRunning == true {
            return String(localized: "A machine with this name already exists.")
        }
        if FileManager.default.fileExists(atPath: machine.url.path) {
            return String(localized: "A folder with this name already exists in this location.")
        }
        if !VPhoneLaunchpadMachineLocations.socketPathFits(root: location, name: effectiveName) {
            return String(localized: "The path is too long. Use a shorter name, or a location with a shorter path.")
        }
        return nil
    }

    private var locationProblem: String? {
        VPhoneLaunchpadMachineLocations.problem(with: location)
    }

    /// Why the location cannot hold the template build, or nil.
    private var templatePathProblem: String? {
        // The template is built in a machine named like `template-1a2b3c4d`.
        guard usesTemplate, !VPhoneLaunchpadMachineLocations.socketPathFits(root: location, name: "template-00000000") else {
            return nil
        }
        return String(localized: "The path is too long. Use a location with a shorter path.")
    }

    /// A setting on an advanced page that stops Create, and that page. The
    /// basic page names it under Advanced Options, which opens on it.
    private var advancedProblem: (page: Page, text: String)? {
        if let problem = locationProblem ?? templatePathProblem {
            return (.storage, problem)
        }
        if let problem = slimming.problem {
            return (.slimming, problem)
        }
        return nil
    }

    /// Whether a current template was built from the chosen device and
    /// release; nil for custom IPSWs and until the template list is read.
    private var templateAvailable: Bool? {
        guard !usesCustomSources, let guest, let pairing = selectedPairing, let templates = model.machines.templates else {
            return nil
        }
        return templates.contains { !$0.stale && $0.key.device == guest && $0.key.iOSBuild == pairing.build }
    }

    private var canCreate: Bool {
        nameProblem == nil && advancedProblem == nil && sources != nil && bundleVersion != nil
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("New Machine")) {
            Form {
                basicPage
            }
            .formStyle(.grouped)
            .vphoneFittedHeight(limit: VPhoneLaunchpadSheetSize.maximum - VPhoneLaunchpadSheetSize.chrome)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .fixedSize(horizontal: false, vertical: true)
        // A second sheet over this one, so the basic settings stay put behind it.
        .sheet(isPresented: $showsAdvanced) {
            advancedSheet
                .environment(model)
        }
        // Each bundle version has its own firmware pairings and patch sets.
        .task(id: bundleVersion) { await loadCatalog() }
        .task(id: bundleVersion) { await loadPatchCatalog() }
        .task { await loadDownloaded() }
        .task { await model.machines.refreshTemplates() }
        // Off when there is no template to clone; it can still be turned on
        // to build one.
        .onChange(of: templateAvailable, initial: true) {
            if let templateAvailable {
                usesTemplate = templateAvailable
            }
        }
        .onAppear {
            if let version = bundleVersion, let known = Self.catalogs[version] {
                apply(known)
            }
            let root = model.machines.preferredRoot
            location = root
            name = suggestedName(in: root)
            #if DEBUG
                if VPhoneLaunchpadPreview.isActive {
                    open(VPhoneLaunchpadPreview.newMachinePage)
                    patches = VPhoneLaunchpadPreview.newMachinePatches
                }
            #endif
        }
    }

    /// Opens the Advanced Options sheet on `target`; `.basic` closes it.
    private func open(_ target: Page) {
        if target == .basic {
            showsAdvanced = false
        } else {
            page = target
            showsAdvanced = true
        }
    }

    // MARK: - Advanced Options

    private var advancedSheet: some View {
        VPhoneLaunchpadSheet(Text("Advanced Options")) {
            VStack(spacing: 0) {
                advancedBar
                Form {
                    switch page {
                    case .basic, .hardware:
                        hardwarePage
                        advancedSections(.hardware)
                    case .template:
                        VPhoneLaunchpadSlimmingSections(part: .template, usesTemplate: $usesTemplate, templateAvailable: templateAvailable, slimming: $slimming)
                    case .slimming:
                        VPhoneLaunchpadSlimmingSections(part: .slimming, usesTemplate: $usesTemplate, templateAvailable: templateAvailable, slimming: $slimming)
                    case .firmware:
                        bundleSection
                        firmwareSourceSection
                    case .patches:
                        advancedSections(.patches)
                    case .storage:
                        // The machine goes in the default location; when that cannot
                        // hold it, this says why.
                        if let problem = locationProblem ?? templatePathProblem {
                            Section {
                                Text(problem).foregroundStyle(.red)
                            }
                        }
                        advancedSections(.storage)
                    }
                }
                .formStyle(.grouped)
            }
        } actions: {
            Button("Done") { showsAdvanced = false }
                .keyboardShortcut(.defaultAction)
        }
        // One height for every page; the form scrolls.
        .frame(height: 500)
    }

    // MARK: - Basic

    @ViewBuilder
    private var basicPage: some View {
        Section {
            TextField("Name", text: $name)
            firmwareChoice
        } footer: {
            if let nameProblem {
                Text(nameProblem).foregroundStyle(.red)
            } else {
                firmwareNote
            }
        }

        if model.bundles.selectableVersions.isEmpty {
            Section {
                Label("No Core Bundle is installed. Install one in Core Bundle.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }

        advancedSection
    }

    @ViewBuilder
    private var firmwareChoice: some View {
        if usesCustomSources {
            LabeledContent("Firmware") {
                HStack {
                    Text("Custom IPSWs").foregroundStyle(.secondary)
                    Button("Change…") { open(.firmware) }
                }
            }
        } else if let catalog {
            Picker("Device", selection: Binding(
                get: { guest },
                set: { choose($0) },
            )) {
                ForEach(catalog.guests) { guest in
                    let count = guest.pairings.count(where: isDownloaded)
                    Text(verbatim: count > 0 ? "\(guest.name) (\(count))" : guest.name).tag(Optional(guest.id))
                }
            } currentValueLabel: {
                // The count is for choosing; the closed menu names the device.
                Text(verbatim: selectedGuest?.name ?? "")
            }
            Picker(selectedGuest?.isPad == true ? "iPadOS" : "iOS", selection: $pairing) {
                ForEach((selectedGuest?.pairings ?? []).reversed()) { pairing in
                    let title = "\(pairing.ios.name) (\(pairing.build))"
                    Text(verbatim: isDownloaded(pairing) ? "\(title) ✓" : title).tag(Optional(pairing.id))
                }
            } currentValueLabel: {
                Text(verbatim: selectedPairing.map { "\($0.ios.name) (\($0.build))" + (isDownloaded($0) ? " ✓" : "") } ?? "")
            }
        } else {
            // The same rows as a loaded catalog, so the sheet keeps its
            // size when it arrives; the footer says what is happening.
            placeholderPicker("Device")
            placeholderPicker("iOS")
        }
    }

    /// Whether the pairing's iOS or iPadOS IPSW is downloaded, under the name
    /// `fw prepare` gives it or its own.
    private func isDownloaded(_ pairing: VPhoneLaunchpadFirmwareCatalog.Pairing) -> Bool {
        guard let url = URL(string: pairing.ios.url) else {
            return false
        }
        return downloaded.contains(VPhoneLaunchpadIPSW.cacheName(for: url)) || downloaded.contains(url.lastPathComponent)
    }

    private func loadDownloaded() async {
        guard let scan = try? await VPhoneLaunchpadIPSWCache.scan(libraryRoots: model.machines.roots, machineFolders: []) else {
            return
        }
        downloaded = Set(scan.ipsws.filter { !$0.isDownloading }.map(\.name))
    }

    private func placeholderPicker(_ title: LocalizedStringKey) -> some View {
        Picker(title, selection: .constant(0)) {
            Text(catalogError == nil ? "Loading…" : "Unavailable").tag(0)
        }
        .disabled(true)
    }

    @ViewBuilder
    private var firmwareNote: some View {
        if usesCustomSources {
            if let (iphone, cloudOS) = sources {
                Text(verbatim: "\(Self.fileName(iphone)) · \(Self.fileName(cloudOS))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Choose an iPhone IPSW and a cloudOS IPSW in Advanced Options.").foregroundStyle(.red)
            }
        } else if let selectedGuest, let cloudOS = selectedPairing?.recommendedCloudOS.name {
            Text("Recommended firmware pairings for \(selectedGuest.detailedName), with \(cloudOS).")
                .foregroundStyle(.secondary)
        } else if catalog == nil, let catalogError {
            Text(catalogError).foregroundStyle(.red)
        } else if catalog == nil {
            Text("Loading firmware catalog…").foregroundStyle(.secondary)
        }
    }

    private static func fileName(_ source: String) -> String {
        let url = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source)
        return url?.lastPathComponent ?? source
    }

    /// One row that opens the advanced pages: what they are set to, how many
    /// settings differ from the defaults, and anything that stops Create.
    private var advancedSection: some View {
        Section {
            Button {
                open(advancedProblem?.page ?? page)
            } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(verbatim: advancedSummary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                } label: {
                    HStack(spacing: 6) {
                        Text("Advanced Options")
                        if changedCount > 0 {
                            Text("^[\(changedCount) setting](inflect: true) changed")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.tint.opacity(0.15)))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            if let advancedProblem {
                Text(advancedProblem.text).foregroundStyle(.red)
            } else {
                Text(spaceNote).foregroundStyle(.secondary)
            }
        }
    }

    private var advancedSummary: String {
        let networkTitle = VPhoneLaunchpadNewMachineAdvancedView.networkModes.first { $0.tag == network }?.title ?? network
        return String(localized: "\(cpu) cores · \(memoryMB / 1024) GB memory · \(diskSizeGB) GB disk") + " · " + networkTitle
    }

    /// The advanced settings that differ from what the sheet opened with.
    private var changedCount: Int {
        let defaultSlimming = VPhoneLaunchpadSlimming()
        return [
            cpu != Self.defaultCPU,
            memoryMB != Self.defaultMemoryMB,
            diskSizeGB != Self.defaultDiskSizeGB,
            // Off is the default when no template exists to clone.
            usesTemplate != (templateAvailable ?? true),
            slimming != defaultSlimming,
            chosenVersion != nil && bundleVersion != model.bundles.defaultVersion,
            usesCustomSources,
            patches != VPhoneLaunchpadPatchSelection(),
            network != Self.defaultNetwork,
            !usesTemplate && keepArtifacts,
        ].count(where: \.self)
    }

    // MARK: - Advanced

    /// Back to the basic page, and the advanced pages.
    private var advancedBar: some View {
        HStack(spacing: 12) {
            VPhoneLaunchpadSheetPages(selection: Binding(get: { page }, set: { open($0) })) {
                Text("Hardware").tag(Page.hardware)
                Text("Template").tag(Page.template)
                Text("Slimming").tag(Page.slimming)
                Text("Firmware").tag(Page.firmware)
                Text("Patches").tag(Page.patches)
                Text("Storage").tag(Page.storage)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
    }

    private var hardwarePage: some View {
        Section {
            Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
            Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
            Stepper("Disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 32 ... 512, step: 16)
        } footer: {
            Text(spaceNote).foregroundStyle(.secondary)
        }
    }

    private func advancedSections(_ page: Page) -> some View {
        VPhoneLaunchpadNewMachineAdvancedView(
            page: page,
            usesTemplate: usesTemplate,
            network: $network,
            patches: $patches,
            keepArtifacts: $keepArtifacts,
            patchCatalog: patchCatalog,
            patchCatalogError: patchCatalogError,
            reloadPatches: { Task { await loadPatchCatalog() } },
            bundleVersion: bundleVersion,
        )
    }

    // MARK: - Core Bundle

    private var bundleSection: some View {
        Section {
            if model.bundles.selectableVersions.isEmpty {
                Label("No Core Bundle is installed. Install one in Core Bundle.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Core Bundle", selection: versionBinding) {
                    ForEach(model.bundles.selectableVersions, id: \.self) { version in
                        // Store names keep their `-local.` and `-ci.` suffixes,
                        // so a build that is not a release reads as one.
                        if version == model.bundles.defaultVersion {
                            Text("\(version) (Default)").tag(Optional(version))
                        } else {
                            Text(verbatim: version).tag(Optional(version))
                        }
                    }
                }
            }
        } footer: {
            Text("The boot chain is built when the machine is created. Host programs, the guest environment and guest patches can be changed later.")
                .foregroundStyle(.secondary)
        }
    }

    /// A new version clears what was read from the old one, so Create cannot
    /// use a pairing or a preset that version never offered.
    private var versionBinding: Binding<String?> {
        Binding(
            get: { bundleVersion },
            set: { version in
                guard version != bundleVersion else {
                    return
                }
                chosenVersion = version
                catalog = nil
                catalogError = nil
                patchCatalog = nil
                patchCatalogError = nil
            },
        )
    }

    // MARK: - Firmware

    private var firmwareSourceSection: some View {
        Section {
            Toggle("Use Specified Firmware", isOn: $usesCustomSources)

            if usesCustomSources {
                sourceField("iPhone IPSW", $iphoneSource)
                sourceField("cloudOS IPSW", $cloudOSSource)
            } else {
                LabeledContent("cloudOS", value: selectedPairing?.recommendedCloudOS.name ?? "—")
            }
        } header: {
            Text("Firmware")
        } footer: {
            Text(usesCustomSources
                ? "These two files replace the device and version chosen on the basic page."
                : "The device and version are chosen on the basic page; cloudOS goes with them.")
                .foregroundStyle(.secondary)
        }
    }

    private static func isIPSWFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && path.lowercased().hasSuffix(".ipsw")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func sourceField(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                // A chosen file shows only its name; a URL or a path still
                // being typed stays editable.
                if Self.isIPSWFile(text.wrappedValue) {
                    Text(verbatim: URL(fileURLWithPath: text.wrappedValue).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(text.wrappedValue)
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear")
                } else {
                    TextField(title, text: text, prompt: Text("URL or path"))
                        .labelsHidden()
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.present { url in
                        text.wrappedValue = url.path
                    }
                }
            }
        }
    }

    /// Disk plus roughly 20 GB of IPSWs and the prepared restore tree.
    private var spaceNote: String {
        let root = VPhoneLaunchpadHostSetup.existingAncestor(of: URL(fileURLWithPath: location, isDirectory: true))
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return String(localized: "Needs about \(diskSizeGB + 20) GB; \(free / 1_000_000_000) GB free.")
    }

    // MARK: - Actions

    /// Each Core Bundle version's catalog, read once per session, so the
    /// sheet opens on the same rows it shows after loading.
    private static var catalogs: [String: VPhoneLaunchpadFirmwareCatalog] = [:]

    /// The default version's catalog, read once per session.
    static func catalog(_ model: VPhoneLaunchpadModel) async -> VPhoneLaunchpadFirmwareCatalog? {
        await prefetchCatalog(model)
        return model.bundles.defaultVersion.flatMap { catalogs[$0] }
    }

    /// Reads the default version's catalog ahead of the sheet.
    static func prefetchCatalog(_ model: VPhoneLaunchpadModel) async {
        guard let version = model.bundles.defaultVersion, catalogs[version] == nil,
              let commandLine = model.bundles.commandLine(version: version),
              let catalog = try? await fetchCatalog(commandLine)
        else {
            return
        }
        catalogs[version] = catalog
    }

    private struct CatalogFailure: LocalizedError {
        var errorDescription: String?
    }

    private static func fetchCatalog(_ commandLine: VPhoneLaunchpadCommandLine) async throws -> VPhoneLaunchpadFirmwareCatalog {
        let result = try await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false)
        guard result.succeeded, let data = result.jsonData else {
            throw CatalogFailure(errorDescription: result.tail)
        }
        return try JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data)
    }

    private func loadCatalog() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                catalog = VPhoneLaunchpadPreview.catalog
                choose(catalog?.guests.first?.id)
                return
            }
        #endif
        guard let version = bundleVersion, let commandLine = model.bundles.commandLine(version: version) else {
            return
        }
        if let known = Self.catalogs[version] {
            apply(known)
            return
        }
        do {
            let catalog = try await Self.fetchCatalog(commandLine)
            Self.catalogs[version] = catalog
            // Another version may have been chosen meanwhile.
            if version == bundleVersion {
                apply(catalog)
            }
        } catch {
            if version == bundleVersion {
                catalogError = error.localizedDescription
            }
        }
    }

    /// The guest and pairing chosen under the previous version stay when
    /// this one offers them too.
    private func apply(_ catalog: VPhoneLaunchpadFirmwareCatalog) {
        self.catalog = catalog
        catalogError = nil
        if !catalog.guests.contains(where: { $0.id == guest }) {
            choose(catalog.guests.first?.id)
        } else if selectedGuest?.pairings.contains(where: { $0.id == pairing }) != true {
            pairing = selectedGuest?.defaultPairing?.id
        }
    }

    /// Select a guest device and its newest release.
    private func choose(_ productType: String?) {
        guest = productType
        pairing = selectedGuest?.defaultPairing?.id
    }

    /// Read again whenever the preset or the version changes: `inPreset`, which
    /// the note and the editor read the checkmarks against, is reported per
    /// preset, and each version declares its own patches.
    private func loadPatchCatalog() async {
        let version = bundleVersion
        let requested = patches.preset
        do {
            let catalog = try await VPhoneLaunchpadPatchCatalog.read(
                using: version.flatMap(model.bundles.commandLine(version:)),
                machine: nil,
                preset: requested,
            )
            // A second switch may have overtaken this read.
            guard requested == patches.preset, version == bundleVersion else {
                return
            }
            // Overrides naming a patch this version does not declare are dropped.
            patches.normalize(against: catalog)
            patchCatalog = catalog
            patchCatalogError = nil
        } catch {
            guard requested == patches.preset, version == bundleVersion else {
                return
            }
            // The first read after a version change: that version may not
            // have the chosen preset, so fall back to the default one.
            if patchCatalog == nil, requested != VPhoneLaunchpadPatchSelection.defaultPreset {
                patches = VPhoneLaunchpadPatchSelection()
                await loadPatchCatalog()
                return
            }
            patchCatalogError = VPhoneLaunchpadError.message(for: error)
        }
    }

    private func create() {
        guard let (iphone, cloudOS) = sources, let bundleVersion else {
            return
        }
        let options = VPhoneLaunchpadCreationPipeline.Options(
            name: effectiveName,
            libraryRoot: location,
            bundleVersion: bundleVersion,
            iphoneSource: iphone,
            cloudOSSource: cloudOS,
            // An iPad IPSW often covers two sizes; name the one chosen.
            device: usesCustomSources ? nil : selectedGuest.flatMap { $0.isPad ? $0.productType : nil },
            cpuCount: cpu,
            memoryMB: memoryMB,
            diskSizeGB: diskSizeGB,
            network: network,
            patches: patches,
            guestPatches: patchCatalog?.guestOverrides(patches) ?? [],
            keepArtifacts: keepArtifacts,
            usesTemplate: usesTemplate,
            slimming: slimming,
        )
        let pipeline = model.machines.create(options)
        model.machines.selection = [pipeline.machine]
        onCreate(pipeline.machine)
    }
}

// MARK: - Pipeline

/// The pipeline, which keeps running when this sheet closes. A failure shows
/// on its step; the log, which records why, opens in its own sheet. A
/// template-backed creation shows the template's steps apart from the
/// machine's own.
struct VPhoneLaunchpadCreationView: View {
    typealias Step = VPhoneLaunchpadCreationStep

    let creation: VPhoneLaunchpadCreationPipeline
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsLog = false
    /// The IPSWs a template this creation built came from, once it is done.
    @State private var ipswFiles: [VPhoneLaunchpadIPSWFile] = []
    @State private var ipswDirectories: [URL] = []
    @State private var offersIPSWs = false

    private var templateSteps: [Step] {
        creation.steps.filter { $0 == .findTemplate || creation.plan.buildsTemplate($0) }
    }

    private var machineSteps: [Step] {
        creation.steps.filter { !templateSteps.contains($0) }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Creating \(creation.options.name)")) {
            Form {
                if creation.plan.usesTemplate {
                    Section {
                        ForEach(templateSteps) { step in
                            stepRow(step)
                        }
                    } header: {
                        Text("Template")
                    } footer: {
                        if let templateNote {
                            Text(templateNote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(machineSteps) { step in
                        stepRow(step)
                    }
                } header: {
                    if creation.plan.usesTemplate {
                        Text("Machine")
                    }
                } footer: {
                    if creation.isRunning {
                        Text("Creation continues if you close this window.").foregroundStyle(.secondary)
                    } else if let failure = creation.failure, let detail = failure.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                }
                if offersIPSWs {
                    VPhoneLaunchpadTemplateIPSWOffer(files: $ipswFiles, cacheDirectories: ipswDirectories)
                }
            }
            .formStyle(.grouped)
            // A template build lists fourteen steps: the form scrolls in a
            // sheet that fits a laptop screen instead of growing past it.
            .vphoneFittedHeight(limit: VPhoneLaunchpadSheetSize.maximum - VPhoneLaunchpadSheetSize.chrome)
            .task(id: creation.isFinished && creation.builtTemplate) {
                guard creation.isFinished, creation.builtTemplate, !offersIPSWs else {
                    return
                }
                let found = await VPhoneLaunchpadTemplateIPSWOffer.scan(creation, library: model.machines)
                ipswFiles = found.files
                ipswDirectories = found.directories
                offersIPSWs = !found.files.isEmpty
            }
        } accessory: {
            Button("Open Log") { showsLog = true }
        } actions: {
            if creation.isRunning {
                Button("Stop Creating", role: .destructive) { creation.cancel() }
            }
            if !creation.isRunning, let step = creation.failedStep {
                Button("Retry from \(step.title)") { creation.start(from: step) }
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsLog) {
            VPhoneLaunchpadConsoleView(title: "\(creation.options.name) Creation Log", url: creation.logFile)
        }
    }

    /// Which template the machine came from, once that is known.
    private var templateNote: String? {
        if let id = creation.templateID, creation.plan.foundTemplate == true {
            return String(localized: "Cloned from template \(id), which machines with these options share.")
        }
        if let id = creation.templateID, creation.builtTemplate {
            return String(localized: "Saved as template \(id). The next machine with these options is cloned from it in seconds.")
        }
        return nil
    }

    private func stepRow(_ step: Step) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if step == .prepare, let fraction = creation.downloadFraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 120)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let duration = creation.durations[step] {
                    Text(Self.duration(duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                VPhoneLaunchpadCommandInfoButton(command: "vphone-cli \(creation.command(for: step))")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(step.title)
                        if step.needsRoot {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Runs as root through the privileged helper")
                        }
                    }
                    if step == .setUpTemplate, let stage = creation.setupStage {
                        // The CLI's own words for the stage: `b. wait for first-boot work`.
                        Text(verbatim: stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                VPhoneLaunchpadStatusIcon(status: creation.status(step))
            }
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(interval).formatted(.time(pattern: interval >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

// MARK: - IPSWs a template came from

/// Offered once a creation has built a template: its clones need neither
/// IPSW, so the two downloads can go. Nothing is deleted without the
/// confirmation, and only files the IPSW cache holds.
struct VPhoneLaunchpadTemplateIPSWOffer: View {
    @Binding var files: [VPhoneLaunchpadIPSWFile]
    let cacheDirectories: [URL]
    @State private var confirming = false
    @State private var deleted = false
    @State private var error: VPhoneLaunchpadError?

    private var total: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        Section {
            if deleted {
                Label("The IPSWs were deleted.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    LabeledContent {
                        Text(verbatim: VPhoneLaunchpadIPSWCacheView.size(file.size)).monospacedDigit()
                    } label: {
                        Text(verbatim: file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                HStack {
                    Spacer()
                    Button("Delete IPSWs…") { confirming = true }
                        .disabled(files.isEmpty)
                }
            }
        } header: {
            Text("Downloaded Firmware")
        } footer: {
            if !deleted {
                Text("Machines from this template need neither IPSW. A machine with other options downloads them again.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            String(localized: "Delete the IPSWs this template came from?"),
            isPresented: $confirming,
        ) {
            Button(String(localized: "Delete \(VPhoneLaunchpadIPSWCacheView.size(total))"), role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("\(files.map(\.name).joined(separator: ", ")) are deleted from the IPSW cache.")
        }
        .errorAlert($error)
    }

    /// The cached IPSWs `creation` was given as sources and no unfinished
    /// creation still reads.
    static func scan(
        _ creation: VPhoneLaunchpadCreationPipeline,
        library: VPhoneLaunchpadMachineLibrary,
    ) async -> (files: [VPhoneLaunchpadIPSWFile], directories: [URL]) {
        let sources = [creation.options.iphoneSource, creation.options.cloudOSSource]
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                let scan = VPhoneLaunchpadPreview.ipswScan
                return (scan.ipsws.filter { file in sources.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) } }, scan.cacheDirectories)
            }
        #endif
        guard let scan = try? await VPhoneLaunchpadIPSWCache.scan(libraryRoots: library.roots, machineFolders: []) else {
            return ([], [])
        }
        let busy = library.creations.values.filter { !$0.isFinished && $0 !== creation }
            .flatMap { [$0.options.iphoneSource, $0.options.cloudOSSource] }
        let files = scan.ipsws.filter { file in
            !file.isDownloading
                && sources.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) }
                && !busy.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) }
        }
        return (files, scan.cacheDirectories)
    }

    private func delete() async {
        var remaining = files
        for file in files {
            do {
                try await VPhoneLaunchpadIPSWCache.removeIPSW(file.url, cacheDirectories: cacheDirectories)
                remaining.removeAll { $0.id == file.id }
            } catch {
                self.error = VPhoneLaunchpadError(String(localized: "Unable to Delete \(file.name)"), detail: error.localizedDescription)
                files = remaining
                return
            }
        }
        files = []
        deleted = true
    }
}
