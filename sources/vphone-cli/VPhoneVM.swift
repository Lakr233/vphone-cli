import Foundation
import Virtualization
import VPhoneObjC

/// Minimal VM for booting a vphone (virtual iPhone) in DFU mode.
class VPhoneVM: NSObject, VZVirtualMachineDelegate {
    let virtualMachine: VZVirtualMachine
    private var done = false

    struct Options {
        var romURL: URL
        var nvramURL: URL
        var diskURL: URL
        var cpuCount: Int = 4
        var memorySize: UInt64 = 4 * 1024 * 1024 * 1024
        var skipSEP: Bool = true
        var sepStorageURL: URL?
        var sepRomURL: URL?
        var serialLogPath: String? = nil
        var stopOnPanic: Bool = false
        var stopOnFatalError: Bool = false
    }

    private var consoleLogFileHandle: FileHandle?

    init(options: Options) throws {
        // --- Hardware model (PV=3) ---
        let hwModel = try VPhoneHardware.createModel()
        print("[vphone] PV=3 hardware model: isSupported = true")

        // --- Platform ---
        let platform = VZMacPlatformConfiguration()

        // Persist machineIdentifier for stable ECID (same as vrevm)
        let machineIDPath = options.nvramURL.deletingLastPathComponent()
            .appendingPathComponent("machineIdentifier.bin")
        if let savedData = try? Data(contentsOf: machineIDPath),
           let savedID = VZMacMachineIdentifier(dataRepresentation: savedData) {
            platform.machineIdentifier = savedID
            print("[vphone] Loaded machineIdentifier (ECID stable)")
        } else {
            let newID = VZMacMachineIdentifier()
            platform.machineIdentifier = newID
            try newID.dataRepresentation.write(to: machineIDPath)
            print("[vphone] Created new machineIdentifier -> \(machineIDPath.lastPathComponent)")
        }

        let auxStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: options.nvramURL,
            hardwareModel: hwModel,
            options: .allowOverwrite
        )
        platform.auxiliaryStorage = auxStorage
        platform.hardwareModel = hwModel
        // platformFusing = prod (same as vrevm config)

        // Set NVRAM boot-args to enable serial output (same as vrevm restore)
        let bootArgs = "serial=3 debug=0x104c04"
        if let bootArgsData = bootArgs.data(using: .utf8) {
            if VPhoneSetNVRAMVariable(auxStorage, "boot-args", bootArgsData) {
                print("[vphone] NVRAM boot-args: \(bootArgs)")
            }
        }

        // --- Boot loader with custom ROM ---
        let bootloader = VZMacOSBootLoader()
        VPhoneSetBootLoaderROMURL(bootloader, options.romURL)

        // --- VM Configuration ---
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.platform = platform
        config.cpuCount = max(options.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(options.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

        // Display (vresearch101: 1290x2796 @ 460 PPI — matches vrevm)
        let gfx = VZMacGraphicsDeviceConfiguration()
        gfx.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1290, heightInPixels: 2796, pixelsPerInch: 460),
        ]
        config.graphicsDevices = [gfx]

        // Storage
        if FileManager.default.fileExists(atPath: options.diskURL.path) {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: options.diskURL, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        }

        // Network (shared NAT)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        // Serial port (PL011 UART — always configured)
        // Connect host stdin/stdout directly for interactive serial console
        do {
            if let serialPort = VPhoneCreatePL011SerialPort() {
                serialPort.attachment = VZFileHandleSerialPortAttachment(
                    fileHandleForReading: FileHandle.standardInput,
                    fileHandleForWriting: FileHandle.standardOutput
                )
                config.serialPorts = [serialPort]
                print("[vphone] PL011 serial port attached (interactive)")
            }

            // Set up log file if requested
            if let logPath = options.serialLogPath {
                let logURL = URL(fileURLWithPath: logPath)
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                self.consoleLogFileHandle = FileHandle(forWritingAtPath: logURL.path)
                print("[vphone] Serial log: \(logPath)")
            }
        }

        // Multi-touch (USB touch screen for VNC click support)
        VPhoneConfigureMultiTouch(config)

        // GDB debug stub (default init, system-assigned port — same as vrevm)
        VPhoneSetGDBDebugStubDefault(config)

        // Coprocessors
        if options.skipSEP {
            print("[vphone] SKIP_SEP=1 — no coprocessor")
        } else if let sepStorageURL = options.sepStorageURL {
            VPhoneConfigureSEP(config, sepStorageURL, options.sepRomURL)
            print("[vphone] SEP coprocessor enabled (storage: \(sepStorageURL.path))")
        } else {
            // Create default SEP storage next to NVRAM
            let defaultSEPURL = options.nvramURL.deletingLastPathComponent()
                .appendingPathComponent("sep_storage.bin")
            VPhoneConfigureSEP(config, defaultSEPURL, options.sepRomURL)
            print("[vphone] SEP coprocessor enabled (storage: \(defaultSEPURL.path))")
        }

        // Validate
        try config.validate()
        print("[vphone] Configuration validated")

        virtualMachine = VZVirtualMachine(configuration: config)
        super.init()
        virtualMachine.delegate = self
    }

    // MARK: - DFU start

    @MainActor
    func start(forceDFU: Bool, stopOnPanic: Bool, stopOnFatalError: Bool) async throws {
        let opts = VZMacOSVirtualMachineStartOptions()
        VPhoneConfigureStartOptions(opts, forceDFU, stopOnPanic, stopOnFatalError)
        print("[vphone] Starting\(forceDFU ? " DFU" : "")...")
        try await virtualMachine.start(options: opts)
        if forceDFU {
            print("[vphone] VM started in DFU mode — connect with irecovery")
        } else {
            print("[vphone] VM started — booting normally")
        }
    }

    // MARK: - Wait

    func waitUntilStopped() async {
        while !done {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Delegate

    func guestDidStop(_: VZVirtualMachine) {
        print("[vphone] Guest stopped")
        done = true
    }

    func virtualMachine(_: VZVirtualMachine, didStopWithError error: Error) {
        print("[vphone] Stopped with error: \(error)")
        done = true
    }

    func virtualMachine(_: VZVirtualMachine, networkDevice _: VZNetworkDevice,
                        attachmentWasDisconnectedWithError error: Error)
    {
        print("[vphone] Network error: \(error)")
    }

    // MARK: - Cleanup

    func stopConsoleCapture() {
        consoleLogFileHandle?.closeFile()
    }
}

// MARK: - Errors

enum VPhoneError: Error, CustomStringConvertible {
    case hardwareModelNotSupported
    case romNotFound(String)

    var description: String {
        switch self {
        case .hardwareModelNotSupported:
            """
            PV=3 hardware model not supported. Check:
              1. macOS >= 15.0 (Sequoia)
              2. Signed with com.apple.private.virtualization + \
            com.apple.private.virtualization.security-research
              3. SIP/AMFI disabled
            """
        case let .romNotFound(p):
            "ROM not found: \(p)"
        }
    }
}
