import Dynamic
import Foundation
import Virtualization

/// Minimal VM for booting a vphone (virtual iPhone) in DFU mode.
@MainActor
class VPhoneVM: NSObject, VZVirtualMachineDelegate {
    let virtualMachine: VZVirtualMachine
    /// Read handle for VM serial output.
    private var serialOutputReadHandle: FileHandle?

    struct Options {
        var romURL: URL
        var nvramURL: URL
        var machineIDURL: URL
        var diskURL: URL
        var cpuCount: Int = 8
        var memorySize: UInt64 = 8 * 1024 * 1024 * 1024
        var sepStorageURL: URL
        var sepRomURL: URL
        var screenWidth: Int = 1290
        var screenHeight: Int = 2796
        var screenPPI: Int = 460
        var screenScale: Double = 3.0
    }

    init(options: Options) throws {
        // --- Hardware model (PV=3) ---
        let hwModel = try VPhoneHardware.createModel()
        print("[vphone] PV=3 hardware model: isSupported = true")

        // --- Platform ---
        let platform = VZMacPlatformConfiguration()

        // Persist machineIdentifier for stable ECID
        if let savedData = try? Data(contentsOf: options.machineIDURL),
           let savedID = VZMacMachineIdentifier(dataRepresentation: savedData)
        {
            platform.machineIdentifier = savedID
            print("[vphone] Loaded machineIdentifier (ECID stable)")
        } else {
            let newID = VZMacMachineIdentifier()
            platform.machineIdentifier = newID
            try newID.dataRepresentation.write(to: options.machineIDURL)
            print("[vphone] Created new machineIdentifier -> \(options.machineIDURL.lastPathComponent)")
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

        // Display
        let gfx = VZMacGraphicsDeviceConfiguration()
        gfx.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: options.screenWidth, heightInPixels: options.screenHeight,
                pixelsPerInch: options.screenPPI
            ),
        ]
        config.graphicsDevices = [gfx]

        // Audio
        let afg = VZVirtioSoundDeviceConfiguration()
        let inputAudioStreamConfiguration = VZVirtioSoundDeviceInputStreamConfiguration()
        let outputAudioStreamConfiguration = VZVirtioSoundDeviceOutputStreamConfiguration()
        inputAudioStreamConfiguration.source = VZHostAudioInputStreamSource()
        outputAudioStreamConfiguration.sink = VZHostAudioOutputStreamSink()
        afg.streams = [inputAudioStreamConfiguration, outputAudioStreamConfiguration]
        config.audioDevices = [afg]

        // Storage
        guard FileManager.default.fileExists(atPath: options.diskURL.path) else {
            throw VPhoneError.diskNotFound(options.diskURL.path)
        }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: options.diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        // Network (shared NAT)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        // Serial port (PL011 UART — pipes for input/output with boot detection)
        if let serialPort = Dynamic._VZPL011SerialPortConfiguration().asObject as? VZSerialPortConfiguration {
            let inputPipe = Pipe()
            let outputPipe = Pipe()

            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: inputPipe.fileHandleForReading,
                fileHandleForWriting: outputPipe.fileHandleForWriting
            )

            // Forward host stdin → VM serial input
            let writeHandle = inputPipe.fileHandleForWriting
            let stdinFD = FileHandle.standardInput.fileDescriptor
            DispatchQueue.global(qos: .userInteractive).async {
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(stdinFD, &buf, buf.count)
                    if n <= 0 { break }
                    writeHandle.write(Data(buf[..<n]))
                }
            }

            serialOutputReadHandle = outputPipe.fileHandleForReading

            config.serialPorts = [serialPort]
            print("[vphone] PL011 serial port attached (interactive)")
        }

        // Multi-touch (USB touch screen)
        if let obj = Dynamic._VZUSBTouchScreenConfiguration().asObject {
            Dynamic(config)._setMultiTouchDevices([obj])
            print("[vphone] USB touch screen configured")
        }

        config.keyboards = [VZUSBKeyboardConfiguration()]

        // Vsock (host ↔ guest control channel, no IP/TCP involved)
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // GDB debug stub (default init, system-assigned port)
        Dynamic(config)._setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)

        // Coprocessors
        let sepConfig = Dynamic._VZSEPCoprocessorConfiguration(storageURL: options.sepStorageURL)
        sepConfig.setRomBinaryURL(options.sepRomURL)
        sepConfig.setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)
        if let sepObj = sepConfig.asObject {
            Dynamic(config)._setCoprocessors([sepObj])
            print("[vphone] SEP coprocessor enabled (storage: \(options.sepStorageURL.path))")
        }

        // Validate
        try config.validate()
        print("[vphone] Configuration validated")

        virtualMachine = VZVirtualMachine(configuration: config)
        super.init()
        virtualMachine.delegate = self

        // Forward VM serial output → host stdout
        if let readHandle = serialOutputReadHandle {
            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                FileHandle.standardOutput.write(data)
            }
        }
    }

    // MARK: - Start

    @MainActor
    func start(forceDFU: Bool) async throws {
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
}
