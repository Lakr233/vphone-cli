import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - Command group

struct VPhoneVirtualMachineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Manage vphone VM bundles",
        subcommands: [
            VPhoneVirtualMachineListCommand.self,
            VPhoneVirtualMachineInfoCommand.self,
            VPhoneVirtualMachineNewCommand.self,
            VPhoneVirtualMachineConfigCommand.self,
            VPhoneVirtualMachineNetworkCommand.self,
            VPhoneVirtualMachineLeasesCommand.self,
            VPhoneVirtualMachineRenameCommand.self,
            VPhoneVirtualMachineDeleteCommand.self,
            VPhoneVirtualMachineCloneCommand.self,
            VPhoneVirtualMachineRebaseCommand.self,
            VPhoneVirtualMachineSnapshotCommand.self,
            VPhoneVirtualMachineExportCommand.self,
            VPhoneVirtualMachineImportCommand.self,
            VPhoneVirtualMachineLaunchCommand.self,
            VPhoneVirtualMachineStopCommand.self,
            VPhoneVirtualMachineCreateCommand.self,
            VPhoneVirtualMachineCreateBulkCommand.self,
            VPhoneVirtualMachineTemplateCommand.self,
            VPhoneVirtualMachineWriteManifestCommand.self,
        ],
    )
}

/// Writes configuration for an existing bundle directory. New bundles should
/// normally use `vm new`, which owns all initial storage files.
struct VPhoneVirtualMachineWriteManifestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-manifest",
        abstract: "Write a fresh config.plist into a VM directory",
    )

    @Option(
        name: .customLong("vm-dir"),
        help: "VM directory to write config.plist into",
        transform: URL.init(fileURLWithPath:),
    )
    var vmDirectory: URL = .init(fileURLWithPath: "vm")

    @Option(name: .customLong("cpu"), help: "CPU core count")
    var cpuCount: UInt = 8

    @Option(name: .customLong("memory"), help: "Memory size in MB")
    var memoryMB: UInt64 = 8192

    @Option(
        name: .customLong("platform-fusing"),
        help: "prod or dev. Omit to let the host OS decide.",
    )
    var platformFusing: VPhoneVirtualMachineManifest.PlatformFusing?

    func run() throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: vmDirectory.path, isDirectory: &isDirectory,
            ), isDirectory.boolValue
        else {
            throw ValidationError("VM directory does not exist: \(vmDirectory.path)")
        }

        let manifest = VPhoneVirtualMachineManifest.newVM(
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            platformFusing: platformFusing,
        )
        let configURL = vmDirectory.appendingPathComponent("config.plist")
        if FileManager.default.fileExists(atPath: configURL.path) {
            // An existing VM must already be v2; do not turn a legacy VM into
            // a v2 VM by replacing only its manifest.
            _ = try VPhoneVirtualMachineManifest.load(from: configURL)
        } else if try !((FileManager.default.contentsOfDirectory(atPath: vmDirectory.path)).isEmpty) {
            throw ValidationError(
                "This VM directory has data but no config.plist. write-manifest cannot upgrade an existing VM. Create the VM in a new directory.",
            )
        }
        try manifest.write(to: configURL)
        try VPhoneHostFilePermissions.makeAccessible(at: configURL)
        print("Created VM manifest: \(configURL.path)")
    }
}

// MARK: - Shared options

struct VPhoneLibraryOption: ParsableArguments {
    @Option(
        name: [.customShort("l"), .long], help: "VM library root (default: ~/.vphone/machines or $VPHONE_LIBRARY_ROOT)",
    )
    var libraryRoot: String?

    var library: VPhoneLibrary {
        let root =
            libraryRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VPhoneLibrary.defaultRoot()
        return VPhoneLibrary(root: root)
    }
}

// MARK: - list

struct VPhoneVirtualMachineListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List VM bundles")

    @OptionGroup var lib: VPhoneLibraryOption
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let library = lib.library
        let scan = try library.scan()
        for skip in scan.skipped {
            FileHandle.standardError.write(Data("warning: skipping \(skip.name): \(skip.reason)\n".utf8))
        }
        let reports = scan.bundles.map(VPhoneBundleReport.init)
        if json {
            let data = try JSONEncoder().encode(reports)
            print(String(decoding: data, as: UTF8.self))
        } else if reports.isEmpty {
            print("No VMs in \(library.root.path). Create one with vm create.")
        } else {
            for r in reports {
                let diskGB = r.diskSizeBytes / 1_000_000_000
                if let info = r.restoreInfo {
                    print(
                        "\(r.name)  \(r.cpuCount) CPU  \(r.memoryMB) MB  \(diskGB) GB disk  iOS \(info.ios.version) / cloudOS \(info.cloudOS.version)",
                    )
                } else {
                    print("\(r.name)  \(r.cpuCount) CPU  \(r.memoryMB) MB  \(diskGB) GB disk")
                }
            }
        }
    }
}

// MARK: - info

struct VPhoneVirtualMachineInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show one VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let report = VPhoneBundleReport(bundle: bundle)
        if json {
            try print(String(decoding: JSONEncoder().encode(report), as: UTF8.self))
        } else {
            print("name:  \(report.name)")
            print("cpu:   \(report.cpuCount)")
            print("mem:   \(report.memoryMB) MB")
            print("disk:  \(report.diskSizeBytes) bytes")
            print("net:   \(describeNetwork(report.network))")
            print("unlock: \(report.unlocksAtStartup ? "on" : "off")")
            print("location: \(report.syncsHostLocation ? "on" : "off")")
            print("rom:   \(VPhoneBootROMOption.describe(bundle))")
            print("seprom: \(VPhoneSEPROMOption.describe(bundle))")
            if let snapshots = try? VPhoneMachineSnapshots.list(of: bundle), !snapshots.isEmpty {
                print("snapshots: \(snapshots.count)")
            }
            if let udid = report.udid {
                print("udid:  \(udid)")
            }
            if let template = report.template {
                print("template: \(template)")
            }
            if let info = report.restoreInfo {
                print("iOS:     \(info.ios.version) (\(info.ios.build))")
                print("cloudOS: \(info.cloudOS.version) (\(info.cloudOS.build))")
                if let variant = info.variant {
                    print("variant: \(variant)")
                }
                if let device = info.device {
                    print("device:  \(device)")
                }
            }
        }
    }
}

// MARK: - new

struct VPhoneVirtualMachineNewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Create a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String
    @Option(name: .shortAndLong, help: "CPU cores") var cpu: UInt = 8
    @Option(name: .shortAndLong, help: "Memory (MB)") var memory: UInt64 = 8192
    @Option(name: .shortAndLong, help: "Disk size (GB)") var diskSize: UInt64 = 64
    @Option(name: .shortAndLong, help: VPhoneBootROMOption.help) var rom: String?
    @Option(name: .shortAndLong, help: VPhoneSEPROMOption.help) var seprom: String?

    func run() throws {
        let spec = VPhoneBundleOperations.NewBundleConfiguration(
            name: name,
            cpuCount: cpu,
            memoryMB: memory,
            diskSizeGB: diskSize,
            romSource: VPhoneBootROMOption.source(for: rom),
            sepromSource: VPhoneSEPROMOption.source(for: seprom),
        )
        let bundle = try VPhoneBundleOperations.create(spec, in: lib.library)
        print("created \(bundle.url.path)")
    }
}

// MARK: - config

struct VPhoneVirtualMachineConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Edit VM manifest fields (cpu/memory/network/startup/rom/seprom)",
        discussion: """
        Network settings are read when the VM starts, so a change applies from the next launch.

        --ip fixes the guest's address. In nat mode it must be on the Mac's shared NAT network \
        (usually 192.168.64.0/24), and vphoned writes it into the guest. In tunnel mode, any \
        private subnet, handed out by the VM's own DHCP. In bridged mode vphoned writes it into \
        the guest, so give --gateway and --dns for the LAN.

        --forward carries a host port into the guest (nat and tunnel): tcp:8022:22 listens on \
        127.0.0.1:8022, tcp:0.0.0.0:8022:22 on every address. Repeat it for more ports.

        --mdns on makes the guest answer to <vm-name>.local over mDNS (or --mdns <name> for \
        another name), in every network mode: the guest also announces it over its USB link to \
        this Mac. --mdns off puts the guest's own name back.

        --mac-name (on by default) has the guest resolve this Mac's <LocalHostName>.local \
        at once, to the address the guest reaches the Mac at (nat: the shared network's host \
        address, usually 192.168.64.1; tunnel: the gateway, which leads to the Mac's loopback; \
        bridged: the Mac's address on that interface), instead of racing mDNS answers. \
        --mac-name off withdraws it. Applied each time vphone-vm connects to the guest.

        --nat-peers (on by default) lets a nat guest and the other nat machines on this Mac \
        reach each other, as a watch and the phone it pairs with must. --nat-peers off keeps \
        the guest isolated: it reaches only this Mac and beyond. Applies from the next launch.

        --unlock-at-startup on has vphone-vm wake the guest and dismiss its Lock Screen each time \
        vphoned starts in it: after the VM starts and after the guest reboots. Applies from the \
        next connect.

        --sync-host-location on has vphone-vm forward this Mac's location to the guest while it \
        runs, as a simulated location; macOS asks once for permission. The guest's own Location \
        Services switch is left alone: with it off, apps in the guest get no location. Applies \
        from the next start; in a VM window, Location > Sync Host Location changes it at once.

        --rom openavb makes the bundle's OpenAVB the boot ROM, --rom apple Virtualization.framework's \
        AVPBooter (the machine's own patched copy when it has one), --rom <file> any other ROM. \
        Applies from the next start, without a restore: both ROMs load the same patched LLB. \
        Restoring a machine that boots OpenAVB needs a bundle with OpenAVB support.

        --seprom opensep makes the bundle's OpenSEP the SEP ROM, --seprom apple Virtualization.framework's \
        AVPSEPBooter, --seprom <file> any other SEP ROM. Applies from the next start, without a \
        restore: both load the SEP firmware the restore installed.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "CPU cores") var cpu: UInt?
    @Option(name: .shortAndLong, help: "Memory (MB)") var memory: UInt64?
    @Option(name: [.customShort("n"), .long], help: "Network mode: nat | bridged | tunnel | none") var network: String?
    @Option(name: .long, help: "Host interface to bridge (bridged mode; auto-picks first if omitted)")
    var bridgeInterface: String?
    @Option(name: .long, help: "Guest NIC MAC address: aa:bb:cc:dd:ee:ff | random | auto (a new one at next boot)")
    var mac: String?
    @Option(name: .long, help: "Fixed guest IPv4 address, address[/prefix] (default /24), or dhcp")
    var ip: String?
    @Option(name: .long, help: "Guest default gateway with a fixed address, or auto")
    var gateway: String?
    @Option(name: .long, help: "Guest DNS servers with a fixed address, comma separated, or auto")
    var dns: String?
    @Option(name: .long, help: "Forward a host port: [tcp|udp:][host-address:]host-port:guest-port (repeatable)")
    var forward: [String] = []
    @Option(name: .long, help: "Remove a forward, as vm info lists it or by host port (repeatable)")
    var removeForward: [String] = []
    @Flag(name: .long, help: "Remove every port forward")
    var clearForwards = false
    @Option(name: .long, help: "mDNS name: on (<vm-name>.local), off, or a name")
    var mdns: String?
    @Option(name: .long, help: "Have the guest resolve this Mac's .local name locally: on (default) | off")
    var macName: String?
    @Option(name: .long, help: "Let this nat guest and the other nat machines reach each other: on (default) | off")
    var natPeers: String?
    @Option(name: .long, help: "Unlock the guest when it starts: on | off (default)")
    var unlockAtStartup: String?
    @Option(name: .long, help: "Forward this Mac's location to the guest: on | off (default)")
    var syncHostLocation: String?
    @Option(name: .long, help: VPhoneBootROMOption.help)
    var rom: String?
    @Option(name: .long, help: VPhoneSEPROMOption.help)
    var seprom: String?

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let edit = try networkEdit(vmName: name)
        let unlocks = try unlockAtStartup.map { try Self.parseSwitch($0, option: "--unlock-at-startup") }
        let syncsLocation = try syncHostLocation.map { try Self.parseSwitch($0, option: "--sync-host-location") }
        let updated = try VPhoneBundleOperations.updateConfig(
            bundleNamed: name,
            in: lib.library,
            cpuCount: cpu,
            memoryMB: memory,
            networkEdit: edit,
            unlocksAtStartup: unlocks,
            syncsHostLocation: syncsLocation,
        )
        var current = updated
        if let rom {
            current = try VPhoneBootROMOption.install(rom, in: current)
            print("boot ROM: \(VPhoneBootROMOption.describe(current)), from the next start")
        }
        if let seprom {
            current = try VPhoneSEPROMOption.install(seprom, in: current)
            print("SEP ROM: \(VPhoneSEPROMOption.describe(current)), from the next start")
        }
        let m = updated.manifest
        print(
            "updated \(updated.name): \(m.cpuCount) CPU, \(m.memorySize / (1024 * 1024)) MB, "
                + "net=\(describeNetwork(m.networkConfig))",
        )
    }

    private func networkEdit(vmName: String) throws -> VPhoneNetworkEdit {
        var edit = try VPhoneNetworkEdit(
            mode: network.map(Self.parseMode),
            bridgeInterface: bridgeInterface,
            removeForwards: removeForward,
            clearForwards: clearForwards,
        )
        switch mac?.lowercased() {
        case nil: break
        case "auto": edit.mac = .automatic
        case "random": edit.mac = .random
        case let value?: edit.mac = .fixed(value)
        }
        if let ip {
            if ip.lowercased() == "dhcp" {
                edit.address = .dhcp
            } else {
                let parsed = try VPhoneNetworking.parseAddress(ip)
                edit.address = .fixed(address: parsed.address, prefixLength: parsed.prefixLength)
            }
        }
        if let gateway {
            edit.router = .some(gateway.lowercased() == "auto" ? nil : gateway)
        }
        if let dns {
            edit.dns = .some(
                dns.lowercased() == "auto"
                    ? nil
                    : dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            )
        }
        edit.addForwards = try forward.map(VPhoneNetworking.parsePortForward)
        switch macName?.lowercased() {
        case nil: break
        case "on": edit.resolvesMacName = true
        case "off": edit.resolvesMacName = false
        default: throw ValidationError("--mac-name takes on or off.")
        }
        switch natPeers?.lowercased() {
        case nil: break
        case "on": edit.reachesPeers = true
        case "off": edit.reachesPeers = false
        default: throw ValidationError("--nat-peers takes on or off.")
        }
        switch mdns?.lowercased() {
        case nil: break
        case "off": edit.localHostName = .some(nil)
        case "on": edit.localHostName = .some(VPhoneNetworking.localHostName(forVMName: vmName))
        default: edit.localHostName = .some(mdns)
        }
        return edit
    }

    static func parseSwitch(_ value: String, option: String) throws -> Bool {
        switch value.lowercased() {
        case "on": return true
        case "off": return false
        default: throw ValidationError("\(option) takes on or off.")
        }
    }

    static func parseMode(_ s: String)
        throws -> VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode
    {
        switch s.lowercased() {
        case "nat": return .nat
        case "bridged": return .bridged
        case "tunnel": return .tunnel
        case "none", "off": return .off
        case "hostonly", "host-only":
            throw ValidationError("Host-only networking is not supported. Use nat, bridged, tunnel, or none.")
        default:
            throw ValidationError("Unknown network mode '\(s)'. Use nat, bridged, tunnel, or none.")
        }
    }
}

/// One line: mode, then whatever is set beyond it.
func describeNetwork(_ net: VPhoneVirtualMachineManifest.NetworkConfig) -> String {
    var parts = [net.mode == .bridged ? "bridged(\(net.bridgeInterface ?? "?"))" : net.mode.rawValue]
    if !net.macAddress.isEmpty {
        parts.append("mac \(net.macAddress)")
    }
    if let ipv4 = net.ipv4 {
        var address = "ip \(ipv4.address)/\(ipv4.prefixLength)"
        if let router = ipv4.router {
            address += " gw \(router)"
        }
        if let dns = ipv4.dns, !dns.isEmpty {
            address += " dns \(dns.joined(separator: ","))"
        }
        parts.append(address)
    }
    if let forwards = net.portForwards, !forwards.isEmpty {
        parts.append("forward \(forwards.map(\.description).joined(separator: " "))")
    }
    if let name = net.localHostName {
        parts.append("mdns \(name).local")
    }
    if net.resolvesMacName == false {
        parts.append("mac-name off")
    }
    if net.mode == .nat, !VPhoneNetworking.reachesPeers(net) {
        parts.append("nat-peers off")
    }
    return parts.joined(separator: ", ")
}

// MARK: - rename

struct VPhoneVirtualMachineRenameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Rename a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "current name") var name: String?
    @Argument(help: "new name") var newName: String?

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let newName = try VPhoneVirtualMachineSelection.resolveNewName(newName, prompt: "New VM name:")
        let b = try VPhoneBundleOperations.rename(bundleNamed: name, to: newName, in: lib.library)
        print("renamed to \(b.name)")
    }
}

// MARK: - delete

struct VPhoneVirtualMachineDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Do not prompt") var force = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        if !force {
            print("Delete '\(name)' and all its files? [y/N] ", terminator: "")
            guard (readLine() ?? "").lowercased() == "y" else {
                print("Canceled. Nothing was deleted.")
                return
            }
        }
        let source = try VPhoneMachineTemplates.readSource(inBundle: lib.library.bundle(named: name).url)
        try VPhoneBundleOperations.delete(bundleNamed: name, in: lib.library)
        print("deleted \(name)")
        // Never deleted here: another create may want it, and rebuilding it
        // takes a restore.
        if let template = VPhoneMachineTemplates.unusedTemplate(after: source, in: lib.library) {
            let size = VPhoneSystemTrim.formatBytes(VPhoneMachineTemplates.allocatedBytes(of: template.url))
            print("note: template \(template.identifier) (~\(size)) is no longer used by any machine; "
                + "remove it with `vphone-cli vm template delete \(template.identifier)`")
        }
    }
}
