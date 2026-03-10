import ArgumentParser
import Foundation

struct VPhoneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone (PV=3)",
        discussion: """
        Creates a Virtualization.framework VM with platform version 3 (vphone)
        and boots it into DFU mode for firmware loading via irecovery.

        Requires:
          - macOS 15+ (Sequoia or later)
          - SIP/AMFI disabled
          - Signed with vphone entitlements (done automatically by wrapper script)

        Example:
          vphone-cli --config config.plist --rom ./AVPBooter.vresearch1.bin --disk ./Disk.img
        """
    )

    @Option(
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    var config: URL

    @Option(help: "Path to the AVPBooter / ROM binary")
    var rom: String

    @Option(help: "Path to the disk image")
    var disk: String

    @Option(help: "Path to NVRAM storage (created/overwritten)")
    var nvram: String = "nvram.bin"

    @Option(help: "Number of CPU cores (overridden by --config if present)")
    var cpu: Int?

    @Option(help: "Memory size in MB (overridden by --config if present)")
    var memory: Int?

    @Option(help: "Path to SEP storage file (created if missing)")
    var sepStorage: String

    @Option(help: "Path to SEP ROM binary")
    var sepRom: String

    @Flag(help: "Boot into DFU mode")
    var dfu: Bool = false

    @Option(help: "Display width in pixels (overridden by --config if present)")
    var screenWidth: Int?

    @Option(help: "Display height in pixels (overridden by --config if present)")
    var screenHeight: Int?

    @Option(help: "Display pixels per inch (overridden by --config if present)")
    var screenPpi: Int?

    @Option(help: "Window scale divisor (default: 3.0)")
    var screenScale: Double = 3.0

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    var kernelDebugPort: Int?

    @Flag(help: "Run without GUI (headless)")
    var noGraphics: Bool = false

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    var vphonedBin: String = ".vphoned.signed"

    /// Resolve final options by merging manifest with command-line overrides
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        // Start with command-line paths
        let romURL = URL(fileURLWithPath: rom)
        let diskURL = URL(fileURLWithPath: disk)
        let nvramURL = URL(fileURLWithPath: nvram)
        let sepStorageURL = URL(fileURLWithPath: sepStorage)
        let sepRomURL = URL(fileURLWithPath: sepRom)

        // Default values
        var resolvedCpuCount = 8
        var resolvedMemorySize: UInt64 = 8 * 1024 * 1024 * 1024
        var resolvedScreenWidth = 1290
        var resolvedScreenHeight = 2796
        var resolvedScreenPpi = 460
        var resolvedScreenScale = 3.0

        // Load manifest (required)
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        // Apply manifest settings
        resolvedCpuCount = Int(manifest.cpuCount)
        resolvedMemorySize = manifest.memorySize
        resolvedScreenWidth = manifest.screenConfig.width
        resolvedScreenHeight = manifest.screenConfig.height
        resolvedScreenPpi = manifest.screenConfig.pixelsPerInch
        resolvedScreenScale = manifest.screenConfig.scale

        // Apply command-line overrides (if provided)
        if let cpuArg = cpu { resolvedCpuCount = cpuArg }
        if let memoryArg = memory { resolvedMemorySize = UInt64(memoryArg) * 1024 * 1024 }
        if let screenWidthArg = screenWidth { resolvedScreenWidth = screenWidthArg }
        if let screenHeightArg = screenHeight { resolvedScreenHeight = screenHeightArg }
        if let screenPpiArg = screenPpi { resolvedScreenPpi = screenPpiArg }

        return VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: romURL,
            nvramURL: nvramURL,
            diskURL: diskURL,
            cpuCount: resolvedCpuCount,
            memorySize: resolvedMemorySize,
            sepStorageURL: sepStorageURL,
            sepRomURL: sepRomURL,
            screenWidth: resolvedScreenWidth,
            screenHeight: resolvedScreenHeight,
            screenPPI: resolvedScreenPpi,
            screenScale: resolvedScreenScale,
            kernelDebugPort: kernelDebugPort
        )
    }

    /// Execution is driven by VPhoneAppDelegate; main.swift calls parseOrExit()
    /// and hands the parsed options to the delegate.
    mutating func run() throws {}
}
