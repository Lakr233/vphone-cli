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
          vphone-cli --rom firmware/rom.bin --disk firmware/disk.img
        """
    )

    @Option(help: "Path to the AVPBooter / ROM binary")
    var rom: String

    @Option(help: "Path to the disk image")
    var disk: String

    @Option(help: "Path to NVRAM storage (created/overwritten)")
    var nvram: String = "nvram.bin"

    @Option(help: "Path to machineIdentifier file (created if missing)")
    var machineId: String

    @Option(help: "Number of CPU cores")
    var cpu: Int = 8

    @Option(help: "Memory size in MB")
    var memory: Int = 8192

    @Option(help: "Path to SEP storage file (created if missing)")
    var sepStorage: String

    @Option(help: "Path to SEP ROM binary")
    var sepRom: String

    @Flag(help: "Boot into DFU mode")
    var dfu: Bool = false

    @Option(help: "Display width in pixels (default: 1290)")
    var screenWidth: Int = 1290

    @Option(help: "Display height in pixels (default: 2796)")
    var screenHeight: Int = 2796

    @Option(help: "Display pixels per inch (default: 460)")
    var screenPpi: Int = 460

    @Option(help: "Window scale divisor (default: 3.0)")
    var screenScale: Double = 3.0

    @Flag(help: "Run without GUI (headless)")
    var noGraphics: Bool = false

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    var vphonedBin: String = ".vphoned.signed"

    /// Execution is driven by VPhoneAppDelegate; main.swift calls parseOrExit()
    /// and hands the parsed options to the delegate.
    mutating func run() throws {}
}
