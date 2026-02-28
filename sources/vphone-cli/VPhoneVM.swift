import Dynamic
import Foundation
import Virtualization

/// Minimal VM for booting a vphone (virtual iPhone) in DFU mode.
@MainActor
class VPhoneVM: NSObject, VZVirtualMachineDelegate {
    let virtualMachine: VZVirtualMachine

    /// Called on the main queue when the guest stops (normally or with an error).
    var onStop: (() -> Void)?

    struct Options {
        var romURL: URL
        var nvramURL: URL
        var diskURL: URL
        var cpuCount: Int = 4
        var memorySize: UInt64 = 4 * 1024 * 1024 * 1024
        var skipSEP: Bool = true
        var sepStorageURL: URL?
        var sepRomURL: URL?
        var serialLogPath: String?
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

        // Persist machineIdentifier for stable ECID
        let machineIDPath = options.nvramURL.deletingLastPathComponent()
            .appendingPathComponent("machineIdentifier.bin")
        if let savedData = try? Data(contentsOf: machineIDPath),
           let savedID = VZMacMachineIdentifier(dataRepresentation: savedData)
        {
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

        // Set NVRAM boot-args to enable serial output
        let bootArgs = "serial=3 debug=0x104c04"
        if let bootArgsData = bootArgs.data(using: .utf8) {
            let ok = Dynamic(auxStorage)
                ._setDataValue(bootArgsData, forNVRAMVariableNamed: "boot-args", error: nil)
                .asBool ?? false
            if ok { print("[vphone] NVRAM boot-args: \(bootArgs)") }
        }

        // --- Boot loader with custom ROM ---
        let bootloader = VZMacOSBootLoader()
        Dynamic(bootloader)._setROMURL(options.romURL)

        // --- VM Configuration ---
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.platform = platform
        config.cpuCount = max(options.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(options.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

        // Display (vresearch101: 1290x2796 @ 460 PPI)
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

        // Serial port (PL011 UART — interactive stdin/stdout)
        if let serialPort = Dynamic._VZPL011SerialPortConfiguration().asObject as? VZSerialPortConfiguration {
            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput,
                fileHandleForWriting: FileHandle.standardOutput
            )
            config.serialPorts = [serialPort]
            print("[vphone] PL011 serial port attached (interactive)")
        }

        if let logPath = options.serialLogPath {
            let logURL = URL(fileURLWithPath: logPath)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            consoleLogFileHandle = FileHandle(forWritingAtPath: logURL.path)
            print("[vphone] Serial log: \(logPath)")
        }

        // Multi-touch (USB touch screen)
        if let obj = Dynamic._VZUSBTouchScreenConfiguration().asObject {
            Dynamic(config)._setMultiTouchDevices([obj])
            print("[vphone] USB touch screen configured")
        }

        // GDB debug stub (default init, system-assigned port)
        Dynamic(config)._setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)

        // Coprocessors
        if options.skipSEP {
            print("[vphone] SKIP_SEP=1 — no coprocessor")
        } else {
            let sepURL = options.sepStorageURL
                ?? options.nvramURL.deletingLastPathComponent().appendingPathComponent("sep_storage.bin")
            let sepConfig = Dynamic._VZSEPCoprocessorConfiguration(storageURL: sepURL)
            if let romURL = options.sepRomURL { sepConfig.setRomBinaryURL(romURL) }
            sepConfig.setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)
            if let sepObj = sepConfig.asObject {
                Dynamic(config)._setCoprocessors([sepObj])
                print("[vphone] SEP coprocessor enabled (storage: \(sepURL.path))")
            }
        }

        // Validate
        try config.validate()
        print("[vphone] Configuration validated")

        virtualMachine = VZVirtualMachine(configuration: config)
        super.init()
        virtualMachine.delegate = self
    }

    // MARK: - Start

    @MainActor
    func start(forceDFU: Bool, stopOnPanic _: Bool, stopOnFatalError _: Bool) async throws {
        let opts = VZMacOSVirtualMachineStartOptions()
        Dynamic(opts)._setForceDFU(forceDFU)
        Dynamic(opts)._setStopInIBootStage1(false)
        Dynamic(opts)._setStopInIBootStage2(false)
        print("[vphone] Starting\(forceDFU ? " DFU" : "")...")
        try await virtualMachine.start(options: opts)
        if forceDFU {
            print("[vphone] VM started in DFU mode — connect with irecovery")
        } else {
            print("[vphone] VM started — booting normally")
        }
    }

    // MARK: - Delegate

    // VZ delivers delegate callbacks on the thread where the VM was created (main).

    nonisolated func guestDidStop(_: VZVirtualMachine) {
        print("[vphone] Guest stopped")
        exit(EXIT_SUCCESS)
    }

    nonisolated func virtualMachine(_: VZVirtualMachine, didStopWithError error: Error) {
        print("[vphone] Stopped with error: \(error)")
        exit(EXIT_FAILURE)
    }

    nonisolated func virtualMachine(_: VZVirtualMachine, networkDevice _: VZNetworkDevice,
                                    attachmentWasDisconnectedWithError error: Error)
    {
        print("[vphone] Network error: \(error)")
    }

    // MARK: - Cleanup

    func stopConsoleCapture() {
        consoleLogFileHandle?.closeFile()
    }
}
