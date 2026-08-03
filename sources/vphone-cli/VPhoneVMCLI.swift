import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - Command group

struct VPhoneVMCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Manage vphone VM bundles",
        subcommands: [
            VPhoneVMListCommand.self,
            VPhoneVMInfoCommand.self,
            VPhoneVMNewCommand.self,
            VPhoneVMConfigCommand.self,
            VPhoneVMRenameCommand.self,
            VPhoneVMDeleteCommand.self,
            VPhoneVMCloneCommand.self,
            VPhoneVMExportCommand.self,
            VPhoneVMImportCommand.self,
            VPhoneVMLaunchCommand.self,
            VPhoneVMStopCommand.self,
            VPhoneVMCreateCommand.self,
        ]
    )
}

// MARK: - Shared options

struct VPhoneLibraryOption: ParsableArguments {
    @Option(name: [.customShort("l"), .long], help: "VM library root (default: ~/.vphone/VMs or $VPHONE_LIBRARY_ROOT)")
    var libraryRoot: String?

    var library: VPhoneLibrary {
        let root = libraryRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? VPhoneLibrary.defaultRoot()
        return VPhoneLibrary(root: root)
    }
}

// MARK: - list

struct VPhoneVMListCommand: ParsableCommand {
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
            print("(no VMs in \(library.root.path))")
        } else {
            for r in reports {
                var line = "\(r.name)  \(r.cpuCount) CPU  \(r.memoryMB) MB  \(r.diskSizeBytes / (1024*1024*1024)) GB disk"
                if let info = r.restoreInfo {
                    line += "  iOS \(info.ios.version) / cloudOS \(info.cloudOS.version)"
                }
                print(line)
            }
        }
    }
}

// MARK: - info

struct VPhoneVMInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show one VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let report = VPhoneBundleReport(bundle: bundle)
        if json {
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        } else {
            print("name:  \(report.name)")
            print("cpu:   \(report.cpuCount)")
            print("mem:   \(report.memoryMB) MB")
            print("disk:  \(report.diskSizeBytes) bytes")
            print("net:   \(describeNetwork(report.network))")
            if let udid = report.udid { print("udid:  \(udid)") }
            if let info = report.restoreInfo {
                print("iOS:     \(info.ios.version) (\(info.ios.build))")
                print("cloudOS: \(info.cloudOS.version) (\(info.cloudOS.build))")
                if let variant = info.variant { print("variant: \(variant)") }
                if let device = info.device { print("device:  \(device)") }
            }
        }
    }
}

// MARK: - new

struct VPhoneVMNewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Create a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String
    @Option(name: .shortAndLong, help: "CPU cores") var cpu: UInt = 8
    @Option(name: .shortAndLong, help: "Memory (MB)") var memory: UInt64 = 8192
    @Option(name: .shortAndLong, help: "Disk size (GB)") var diskSize: UInt64 = 64
    @Option(name: .shortAndLong, help: "AVPBooter ROM (default: framework built-in)") var rom: String?
    @Option(name: .shortAndLong, help: "AVPSEPBooter ROM (default: framework built-in)") var seprom: String?

    func run() throws {
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: name, cpuCount: cpu, memoryMB: memory, diskSizeGB: diskSize,
            romSource: rom.map { URL(fileURLWithPath: $0) } ?? VPhoneBundleOps.defaultROMSource(),
            sepromSource: seprom.map { URL(fileURLWithPath: $0) } ?? VPhoneBundleOps.defaultSEPROMSource())
        let bundle = try VPhoneBundleOps.create(spec, in: lib.library)
        print("created \(bundle.url.path)")
    }
}

// MARK: - config

struct VPhoneVMConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Edit VM manifest fields (cpu/memory/network)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "CPU cores") var cpu: UInt?
    @Option(name: .shortAndLong, help: "Memory (MB)") var memory: UInt64?
    @Option(name: [.customShort("n"), .long], help: "Network mode: nat | bridged | none") var network: String?
    @Option(name: .long, help: "Host interface to bridge (bridged mode; auto-picks first if omitted)")
    var bridgeInterface: String?

    func run() throws {
        let mode = try network.map(Self.parseMode)
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let updated = try VPhoneBundleOps.updateConfig(
            bundleNamed: name, in: lib.library, cpuCount: cpu, memoryMB: memory,
            networkMode: mode, bridgeInterface: bridgeInterface)
        let m = updated.manifest
        print("updated \(updated.name): \(m.cpuCount) CPU, \(m.memorySize / (1024*1024)) MB, "
            + "net=\(describeNetwork(m.networkConfig))")
    }

    private static func parseMode(_ s: String)
        throws -> VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode
    {
        switch s.lowercased() {
        case "nat": return .nat
        case "bridged": return .bridged
        case "none", "off": return .off
        case "hostonly", "host-only":
            throw ValidationError("network mode 'hostOnly' is not supported; use nat, bridged, or none")
        default:
            throw ValidationError("unknown network mode '\(s)'; expected nat, bridged, or none")
        }
    }
}

private func describeNetwork(_ net: VPhoneVirtualMachineManifest.NetworkConfig) -> String {
    var s = net.mode.rawValue
    if net.mode == .bridged, let iface = net.bridgeInterface { s += "(\(iface))" }
    return s
}

// MARK: - rename

struct VPhoneVMRenameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Rename a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "current name") var name: String?
    @Argument(help: "new name") var newName: String?

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let newName = try VPhoneVMSelection.resolveNewName(newName, prompt: "New VM name:")
        let b = try VPhoneBundleOps.rename(bundleNamed: name, to: newName, in: lib.library)
        print("renamed to \(b.name)")
    }
}

// MARK: - delete

struct VPhoneVMDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Do not prompt") var force = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        if !force {
            print("Delete '\(name)' and all its files? [y/N] ", terminator: "")
            guard (readLine() ?? "").lowercased() == "y" else { print("aborted"); return }
        }
        try VPhoneBundleOps.delete(bundleNamed: name, in: lib.library)
        print("deleted \(name)")
    }
}
