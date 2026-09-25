import AppKit
import SwiftUI

/// Name, firmware pairing from `fw catalog`, hardware and options. Create
/// hands off to the pipeline sheet.
struct VPhoneLaunchpadNewMachineView: View {
    let onCreate: (String) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var catalog: VPhoneLaunchpadFirmwareCatalog?
    @State private var catalogError: String?
    @State private var pairing: String?
    @State private var usesCustomSources = false
    @State private var iphoneSource = ""
    @State private var cloudOSSource = ""
    @State private var cpu = 8
    @State private var memoryMB = 8192
    @State private var diskSizeGB = 64
    @State private var network = "nat"
    @State private var enableFrida = false
    @State private var forceMaxSlide = false
    @State private var keepArtifacts = false

    private var selectedPairing: VPhoneLaunchpadFirmwareCatalog.Pairing? {
        catalog?.pairings.first { $0.id == pairing }
    }

    private var sources: (String, String)? {
        if usesCustomSources {
            let iphone = iphoneSource.trimmingCharacters(in: .whitespaces)
            let cloudOS = cloudOSSource.trimmingCharacters(in: .whitespaces)
            return iphone.isEmpty || cloudOS.isEmpty ? nil : (iphone, cloudOS)
        }
        return selectedPairing.map { ($0.ios.url, $0.recommendedCloudOS.url) }
    }

    private var nameProblem: String? {
        if name.isEmpty {
            return nil
        }
        if !VPhoneLaunchpadNames.isValidMachineName(name) {
            return String(localized: "Use letters, digits, dots, dashes and underscores.")
        }
        if model.machines.machines.contains(where: { $0.name == name }) {
            return String(localized: "A machine with this name already exists.")
        }
        return nil
    }

    private var canCreate: Bool {
        !name.isEmpty && nameProblem == nil && sources != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(verbatim: "research-01"))
            } footer: {
                if let nameProblem {
                    Text(nameProblem).foregroundStyle(.red)
                }
            }

            firmware

            Section("Hardware") {
                Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
                Stepper("Disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 32 ... 512, step: 16)
                Picker("Network", selection: $network) {
                    Text("NAT").tag("nat")
                    Text("Bridged").tag("bridged")
                    Text("None").tag("none")
                }
            }

            Section {
                Toggle("Frida Stalker kernel relaxations", isOn: $enableFrida)
                Toggle("Disable dyld shared cache randomization", isOn: $forceMaxSlide)
                Toggle("Keep the prepared restore tree", isOn: $keepArtifacts)
            } header: {
                Text("Options")
            } footer: {
                Text(spaceNote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Machine")
        .frame(width: 560, height: 620)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }
                    .disabled(!canCreate)
            }
        }
        .task { await loadCatalog() }
    }

    // MARK: - Firmware

    private var firmware: some View {
        Section {
            Picker("Source", selection: $usesCustomSources) {
                Text("Catalog").tag(false)
                Text("Custom IPSWs").tag(true)
            }
            .pickerStyle(.segmented)

            if usesCustomSources {
                sourceField("iPhone IPSW", $iphoneSource)
                sourceField("cloudOS IPSW", $cloudOSSource)
            } else if let catalog {
                Picker("iOS", selection: $pairing) {
                    ForEach(catalog.pairings.reversed()) { pairing in
                        Text(verbatim: "\(pairing.ios.name) (\(pairing.build))").tag(Optional(pairing.id))
                    }
                }
                LabeledContent("cloudOS", value: selectedPairing?.recommendedCloudOS.name ?? "—")
            } else if let catalogError {
                Label(catalogError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading firmware catalog…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Firmware")
        } footer: {
            if !usesCustomSources, let catalog {
                Text("Recommended firmware pairings for \(catalog.device).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceField(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: text, prompt: Text("URL or path"))
                    .labelsHidden()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        text.wrappedValue = url.path
                    }
                }
            }
        }
    }

    /// Disk plus roughly 20 GB of IPSWs and the prepared restore tree.
    private var spaceNote: String {
        let root = VPhoneLaunchpadHostSetup.existingAncestor(of: model.libraryRoot)
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return String(localized: "Needs about \(diskSizeGB + 20) GB; \(free / 1_000_000_000) GB free.")
    }

    // MARK: - Actions

    private func loadCatalog() async {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                catalog = VPhoneLaunchpadPreview.catalog
                pairing = catalog?.pairings.last?.id
                return
            }
        #endif
        guard catalog == nil, let commandLine = model.bundles.commandLine() else {
            return
        }
        do {
            let result = try await commandLine.run(["fw", "catalog", "--json"], recordInHistory: false)
            guard result.succeeded, let data = result.jsonData else {
                catalogError = result.tail
                return
            }
            let catalog = try JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: data)
            self.catalog = catalog
            pairing = catalog.pairings.last?.id
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func create() {
        guard let (iphone, cloudOS) = sources else {
            return
        }
        let options = VPhoneLaunchpadCreationPipeline.Options(
            name: name,
            iphoneSource: iphone,
            cloudOSSource: cloudOS,
            cpuCount: cpu,
            memoryMB: memoryMB,
            diskSizeGB: diskSizeGB,
            network: network,
            enableFrida: enableFrida,
            forceDyldSharedCacheMaxSlide: forceMaxSlide,
            keepArtifacts: keepArtifacts,
        )
        _ = model.machines.create(options)
        model.machines.selection = name
        onCreate(name)
    }
}

// MARK: - Pipeline

/// The pipeline, which keeps running when this sheet closes.
struct VPhoneLaunchpadCreationView: View {
    let creation: VPhoneLaunchpadCreationPipeline
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(VPhoneLaunchpadCreationPipeline.Step.allCases) { step in
                    stepRow(step)
                }
            } footer: {
                if let failure = creation.failure {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.message).foregroundStyle(.red)
                        if let detail = failure.detail {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                } else if creation.isRunning {
                    Text("Creation continues if you close this window.").foregroundStyle(.secondary)
                }
            }
            Section("Log") {
                VPhoneLaunchpadLogTerminal(url: creation.logFile)
                    .frame(minHeight: 200)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Creating \(creation.options.name)")
        .frame(width: 720, height: 640)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                if creation.isRunning {
                    Button("Stop Creating", role: .destructive) { creation.cancel() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !creation.isRunning, let step = creation.failedStep {
                    Button("Retry from \(step.title)") { creation.start(from: step) }
                }
            }
        }
    }

    private func stepRow(_ step: VPhoneLaunchpadCreationPipeline.Step) -> some View {
        LabeledContent {
            Text(creation.durations[step].map(Self.duration) ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
                    Text(verbatim: "vphone-cli \(creation.command(for: step))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
