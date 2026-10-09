import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

/// Hardware, network, startup and location for one machine, or for several at once. The
/// fields start from the first machine; only the ones edited are written, to
/// every machine, so values the machines do not share are left alone. A fixed
/// address, a MAC and forwarded ports belong to one machine, so they are only
/// offered when one is selected, on pages of their own.
struct VPhoneLaunchpadMachineSettingsView: View {
    private enum Field {
        case cpu, memory, network, address, mac, forwards, mdns, macName, unlock, location
    }

    enum Page: Hashable {
        case general, network, forwards
    }

    let machines: [VPhoneLaunchpadMachine]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.general
    @State private var cpu: Int
    @State private var memoryMB: Int
    @State private var network: String
    @State private var bridgeInterface: String
    @State private var manualAddress: Bool
    @State private var address: String
    @State private var gateway: String
    @State private var dns: String
    @State private var macAddress: String
    @State private var forwards: [String]
    @State private var advertisesName: Bool
    @State private var resolvesMacName: Bool
    @State private var unlocksAtStartup: Bool
    @State private var syncsHostLocation: Bool
    @State private var newTransport = "tcp"
    @State private var newHostPort = ""
    @State private var newGuestPort = ""
    @State private var newOnAllAddresses = false
    @State private var edited: Set<Field> = []

    init(machines: [VPhoneLaunchpadMachine]) {
        self.machines = machines
        let first = machines.first
        _cpu = State(initialValue: first?.cpuCount ?? 8)
        _memoryMB = State(initialValue: first?.memoryMB ?? 8192)
        _network = State(initialValue: first.map { $0.network.mode == "hostOnly" ? "none" : $0.network.mode } ?? "nat")
        _bridgeInterface = State(initialValue: first?.network.bridgeInterface ?? "")
        let ipv4 = first?.network.ipv4
        _manualAddress = State(initialValue: ipv4 != nil)
        _address = State(initialValue: ipv4.map { "\($0.address)/\($0.prefixLength)" } ?? "")
        _gateway = State(initialValue: ipv4?.router ?? "")
        _dns = State(initialValue: ipv4?.dns?.joined(separator: ", ") ?? "")
        _macAddress = State(initialValue: first?.network.macAddress ?? "")
        _forwards = State(initialValue: first?.network.portForwards?.map(\.argument) ?? [])
        _advertisesName = State(initialValue: first?.network.localHostName != nil)
        _resolvesMacName = State(initialValue: first?.network.resolvesMacName != false)
        _unlocksAtStartup = State(initialValue: first?.unlocksAtStartup == true)
        _syncsHostLocation = State(initialValue: first?.syncsHostLocation == true)
    }

    private var title: Text {
        machines.count == 1 ? Text("\(machines[0].name) Settings") : Text("Settings for \(machines.count) Machines")
    }

    private var single: Bool {
        machines.count == 1
    }

    private var forwardsSupported: Bool {
        network == "nat" || network == "tunnel"
    }

    /// The mDNS name the machine has, or the one `--mdns on` would give it:
    /// its name with everything but letters and digits turned into hyphens.
    private var localHostName: String {
        if let name = machines.first?.network.localHostName {
            return name
        }
        let name = machines.first?.name ?? ""
        var label = ""
        for character in name {
            if character.isASCII, character.isLetter || character.isNumber {
                label.append(character)
            } else if !label.hasSuffix("-") {
                label.append("-")
            }
        }
        label = String(label.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return label.isEmpty ? "vphone" : label
    }

    /// Bridged and none have no port forwarding; switching to them drops it.
    private var dropsForwards: Bool {
        single && !forwardsSupported && !forwards.isEmpty
    }

    private var newForward: String? {
        guard let host = Int(newHostPort), (1 ... 65535).contains(host),
              let guest = Int(newGuestPort), (1 ... 65535).contains(guest)
        else { return nil }
        return "\(newTransport):\(newOnAllAddresses ? "0.0.0.0" : "127.0.0.1"):\(host):\(guest)"
    }

    private var canSave: Bool {
        !edited.isEmpty && !(manualAddress && address.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            VStack(spacing: 0) {
                // Several machines share only hardware, the network mode and
                // startup, which fit on one page.
                if single {
                    VPhoneLaunchpadSheetPages(selection: $page) {
                        Text("General").tag(Page.general)
                        Text("Network").tag(Page.network)
                        Text("Port Forwarding").tag(Page.forwards)
                    }
                }
                Form {
                    if !single || page == .general {
                        hardwareSection
                    }
                    if !single || page == .network {
                        networkSection
                        if single {
                            addressSection
                        }
                    }
                    if single, page == .forwards {
                        forwardsSection
                    }
                    if !single || page == .general {
                        startupSection
                        locationSection
                    }
                }
                .formStyle(.grouped)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: cpu) { edited.insert(.cpu) }
        .onChange(of: memoryMB) { edited.insert(.memory) }
        .onChange(of: network) { edited.insert(.network) }
        .onChange(of: bridgeInterface) { edited.insert(.network) }
        .onChange(of: manualAddress) { edited.insert(.address) }
        .onChange(of: address) { edited.insert(.address) }
        .onChange(of: gateway) { edited.insert(.address) }
        .onChange(of: dns) { edited.insert(.address) }
        .onChange(of: macAddress) { edited.insert(.mac) }
        .onChange(of: forwards) { edited.insert(.forwards) }
        .onChange(of: advertisesName) { edited.insert(.mdns) }
        .onChange(of: resolvesMacName) { edited.insert(.macName) }
        .onChange(of: unlocksAtStartup) { edited.insert(.unlock) }
        .onChange(of: syncsHostLocation) { edited.insert(.location) }
        #if DEBUG
            .onAppear {
                if VPhoneLaunchpadPreview.isActive {
                    page = VPhoneLaunchpadPreview.machineSettingsPage
                }
            }
        #endif
    }

    private var hardwareSection: some View {
        Section {
            Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
            Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
        } header: {
            Text("Hardware")
        }
    }

    private var startupSection: some View {
        Section {
            Toggle("Unlock at startup", isOn: $unlocksAtStartup)
        } header: {
            Text("Startup")
        } footer: {
            Text("Each time the guest starts, its screen is turned on and the Lock Screen dismissed.")
                .foregroundStyle(.secondary)
        }
    }

    private var locationSection: some View {
        Section {
            Toggle("Sync this Mac's location", isOn: $syncsHostLocation)
        } header: {
            Text("Location")
        } footer: {
            Text("While the machine runs, the guest gets this Mac's location as a simulated location. macOS asks for permission the first time. Apps in the guest also need Location Services turned on in the guest's Settings.")
                .foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        Section {
            Picker("Mode", selection: $network) {
                Text("NAT").tag("nat")
                Text("Bridged").tag("bridged")
                Text("Tunnel").tag("tunnel")
                Text("None").tag("none")
            }
            if network == "bridged" {
                TextField("Interface", text: $bridgeInterface, prompt: Text("First available"))
            }
        } header: {
            if !single {
                Text("Network")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(VPhoneLaunchpadNewMachineAdvancedView.networkDescription(network))
                if dropsForwards {
                    Text("This mode cannot forward ports, so saving removes the port forwards.")
                }
                if machines.count > 1 {
                    Text("Only the settings you change are applied to each machine.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var addressSection: some View {
        Section {
            if network != "none" {
                Picker("Configure IPv4", selection: $manualAddress) {
                    Text("Using DHCP").tag(false)
                    Text("Manually").tag(true)
                }
                if manualAddress {
                    TextField("Address", text: $address, prompt: Text(verbatim: network == "tunnel" ? "192.168.127.3/24" : "192.168.64.50/24"))
                    TextField("Gateway", text: $gateway, prompt: Text("Automatic"))
                    TextField("DNS Servers", text: $dns, prompt: Text("Automatic"))
                }
                HStack {
                    TextField("MAC Address", text: $macAddress, prompt: Text("Generated at next start"))
                    Button("Generate") { macAddress = Self.randomMACAddress() }
                }
                Toggle("Resolve this Mac's name in the guest", isOn: $resolvesMacName)
            }
            // The guest also announces over its USB link to the Mac, so this
            // works without a network device too.
            Toggle("Reachable as \(localHostName).local", isOn: $advertisesName)
        } header: {
            Text("Address")
        } footer: {
            Group {
                switch network {
                case "none":
                    EmptyView()
                case "nat":
                    Text("Use an address on the Mac's shared NAT network, usually 192.168.64.0/24. For another subnet, use Tunnel.")
                case "tunnel":
                    Text("The tunnel hands this address to the guest itself.")
                default:
                    Text("vphoned sets this address in the guest. Use your network's gateway and DNS servers.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The page stays when the mode cannot forward, so the segments do not
    /// change under the pointer; it says why it is empty instead.
    @ViewBuilder
    private var forwardsSection: some View {
        if forwardsSupported {
            forwardsList
        } else {
            Section {
                Text(dropsForwards
                    ? "This mode cannot forward ports, so saving removes the port forwards."
                    : "Port forwarding needs NAT or Tunnel. Change the mode in Network.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var forwardsList: some View {
        Section {
            ForEach(forwards, id: \.self) { forward in
                HStack {
                    Text(Self.forwardLabel(forward))
                    Spacer()
                    Button {
                        forwards.removeAll { $0 == forward }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            HStack {
                Picker("Protocol", selection: $newTransport) {
                    Text(verbatim: "TCP").tag("tcp")
                    Text(verbatim: "UDP").tag("udp")
                }
                .labelsHidden()
                .fixedSize()
                TextField("Mac Port", text: $newHostPort)
                TextField("Guest Port", text: $newGuestPort)
                Button {
                    if let newForward, !forwards.contains(newForward) {
                        forwards.append(newForward)
                        newHostPort = ""
                        newGuestPort = ""
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(newForward == nil)
                .help("Add")
            }
            Toggle("Reachable from other devices", isOn: $newOnAllAddresses)
        } footer: {
            Text("A forwarded port listens on this Mac only, unless it is reachable from other devices.")
                .foregroundStyle(.secondary)
        }
    }

    /// `tcp:127.0.0.1:8022:22` as `TCP 127.0.0.1:8022 → 22`.
    private static func forwardLabel(_ argument: String) -> String {
        let parts = argument.split(separator: ":")
        guard parts.count == 4 else { return argument }
        return "\(parts[0].uppercased()) \(parts[1]):\(parts[2]) → \(parts[3])"
    }

    /// A unicast, locally administered address, the kind no vendor assigns.
    private static func randomMACAddress() -> String {
        var bytes = (0 ..< 6).map { _ in UInt8.random(in: 0 ... 255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func save() {
        let cpu = edited.contains(.cpu) ? cpu : nil
        let memoryMB = edited.contains(.memory) ? memoryMB : nil
        let network = edited.contains(.network) ? network : nil
        let bridgeInterface = network == "bridged" ? bridgeInterface : nil
        let unlocksAtStartup = edited.contains(.unlock) ? unlocksAtStartup : nil
        let syncsHostLocation = edited.contains(.location) ? syncsHostLocation : nil
        var networkArguments: [String] = []
        if single {
            if edited.contains(.address) {
                if manualAddress {
                    let trimmedGateway = gateway.trimmingCharacters(in: .whitespaces)
                    let trimmedDNS = dns.replacingOccurrences(of: " ", with: "")
                    networkArguments += [
                        "--ip", address.trimmingCharacters(in: .whitespaces),
                        "--gateway", trimmedGateway.isEmpty ? "auto" : trimmedGateway,
                        "--dns", trimmedDNS.isEmpty ? "auto" : trimmedDNS,
                    ]
                } else {
                    networkArguments += ["--ip", "dhcp"]
                }
            }
            if edited.contains(.macName) {
                networkArguments += ["--mac-name", resolvesMacName ? "on" : "off"]
            }
            if edited.contains(.mdns) {
                networkArguments += ["--mdns", advertisesName ? "on" : "off"]
            }
            if edited.contains(.mac) {
                let trimmed = macAddress.trimmingCharacters(in: .whitespaces)
                networkArguments += ["--mac", trimmed.isEmpty ? "auto" : trimmed]
            }
            if dropsForwards {
                networkArguments += ["--clear-forwards"]
            } else if edited.contains(.forwards) {
                networkArguments += ["--clear-forwards"] + forwards.flatMap { ["--forward", $0] }
            }
        }
        let paths = machines.map(\.path)
        let library = model.machines
        Task {
            for path in paths {
                await library.configure(
                    path,
                    cpu: cpu,
                    memoryMB: memoryMB,
                    network: network,
                    bridgeInterface: bridgeInterface,
                    networkArguments: networkArguments,
                    unlocksAtStartup: unlocksAtStartup,
                    syncsHostLocation: syncsHostLocation,
                )
            }
        }
        dismiss()
    }
}

// MARK: - Rename and clone

/// A new name for a machine, and for a clone whatever else it takes, in
/// sections of `options` under the name.
struct VPhoneLaunchpadNameSheet<Options: View>: View {
    let title: LocalizedStringKey
    let action: LocalizedStringKey
    let initial: String
    /// The machine renamed or cloned. The new name stays in its library.
    let machine: VPhoneLaunchpadMachinePath
    @ViewBuilder let options: Options
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    init(
        title: LocalizedStringKey,
        action: LocalizedStringKey,
        initial: String,
        machine: VPhoneLaunchpadMachinePath,
        @ViewBuilder options: () -> Options,
        onConfirm: @escaping (String) -> Void,
    ) {
        self.title = title
        self.action = action
        self.initial = initial
        self.machine = machine
        self.options = options()
        self.onConfirm = onConfirm
    }

    private var fitsLocation: Bool {
        VPhoneLaunchpadMachineLocations.socketPathFits(root: machine.libraryRoot, name: name)
    }

    private var isValid: Bool {
        VPhoneLaunchpadNames.isValidMachineName(name) && name != machine.name && fitsLocation
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text(title)) {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    if fitsLocation {
                        Text("Use letters, numbers, periods, hyphens, and underscores.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The path is too long. Use a shorter name, or a location with a shorter path.")
                            .foregroundStyle(.red)
                    }
                }
                options
            }
            .formStyle(.grouped)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(action) {
                onConfirm(name)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = initial }
    }
}

extension VPhoneLaunchpadNameSheet where Options == EmptyView {
    init(
        title: LocalizedStringKey,
        action: LocalizedStringKey,
        initial: String,
        machine: VPhoneLaunchpadMachinePath,
        onConfirm: @escaping (String) -> Void,
    ) {
        self.init(title: title, action: action, initial: initial, machine: machine, options: { EmptyView() }, onConfirm: onConfirm)
    }
}

/// Clone, with the choice of a device of its own. A new identity is the
/// default: a clone that keeps the original's ECID, UDID and MAC cannot run
/// at the same time as it, and the host sees them as one device.
struct VPhoneLaunchpadCloneSheet: View {
    let machine: VPhoneLaunchpadMachinePath
    let onConfirm: (_ name: String, _ newIdentity: Bool) -> Void
    @State private var newIdentity = true

    var body: some View {
        VPhoneLaunchpadNameSheet(
            title: "Clone \(machine.name)",
            action: "Clone",
            initial: "\(machine.name)-clone",
            machine: machine,
        ) {
            Section {
                Toggle("New device identity", isOn: $newIdentity)
            } footer: {
                Text(newIdentity
                    ? "The clone gets its own ECID, UDID and MAC address, so it can run alongside the original. The guest asks to trust this Mac again the first time it connects."
                    : "The clone is the same device as the original. Run only one of them at a time.")
                    .foregroundStyle(.secondary)
            }
        } onConfirm: { name in
            onConfirm(name, newIdentity)
        }
    }
}

// MARK: - Export

extension UTType {
    /// `<name>.vpea`: a machine as `vm export` writes it, a gnutar of its
    /// folder compressed with zstd. Declared in Info.plist.
    static let vphoneExportedArchive = UTType(exportedAs: "com.vphone.exported-archive")
}
