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

    @Option(help: "Number of CPU cores")
    var cpu: Int = 4

    @Option(help: "Memory size in MB")
    var memory: Int = 4096

    @Option(help: "Path to write serial console log file")
    var serialLog: String? = nil

    @Flag(help: "Stop VM on guest panic")
    var stopOnPanic: Bool = false

    @Flag(help: "Stop VM on fatal error")
    var stopOnFatalError: Bool = false

    @Flag(help: "Skip SEP coprocessor setup")
    var skipSep: Bool = false

    @Option(help: "Path to SEP storage file (created if missing)")
    var sepStorage: String? = nil

    @Option(help: "Path to SEP ROM binary")
    var sepRom: String? = nil

    @Flag(help: "Boot into DFU mode")
    var dfu: Bool = false

    @Flag(help: "Run without GUI (headless)")
    var noGraphics: Bool = false

    /// Execution is driven by VPhoneAppDelegate; main.swift calls parseOrExit()
    /// and hands the parsed options to the delegate.
    mutating func run() throws {}
}
