import Dynamic
import Foundation
import Virtualization

/// Minimal VM for booting a vphone (virtual iPhone) in DFU mode.
@MainActor
class VPhoneVirtualMachineRefactored: NSObject, VZVirtualMachineDelegate {
    let virtualMachine: VZVirtualMachine
    /// ECID hex string resolved from machineIdentifier (e.g. "0x0012345678ABCDEF").
    let ecidHex: String?
    /// Read handle for VM serial output.
    private var serialOutputReadHandle: FileHandle?
    /// Synthetic battery source for runtime charge/connectivity updates.
    private var batterySource: AnyObject?

    struct Configuration {
        var romURL: URL
        var nvramURL: URL
        var machineIDURL: URL
        var diskURL: URL
        var cpuCount: Int = 8
        var memorySize: UInt64 = 8 * 1024 * 1024 * 1024
        var sepStorageURL: URL
        var sepRomURL: URL
        var screenConfiguration: ScreenConfiguration = .default
        var kernelDebugPort: Int?
    }

    struct ScreenConfiguration {
        let width: Int
        let height: Int
        let pixelsPerInch: Int
        let scale: Double

        static let `default` = ScreenConfiguration(
            width: 1290,
            height: 2796,
            pixelsPerInch: 460,
            scale: 3.0,
        )
    }

    private struct DeviceIdentity {
        let cpidHex: String
        let ecidHex: String
        let udid: String
    }

    // MARK: - Battery Connectivity States

    private enum BatteryConnectivity {
        static let charging = 1
        static let disconnected = 2
    }

    init(options: Configuration) throws {
        let hardwareModel = try VPhoneHardware.createModel()
        print("[vphone] PV=3 hardware model: isSupported = true")

        let platform = try configurePlatform(
            machineIDURL: options.machineIDURL,
            nvramURL: options.nvramURL,
            hardwareModel: hardwareModel,
        )

        if let machineIdentifier = platform.machineIdentifier {
            ecidHex = Self.resolveDeviceIdentity(machineIdentifier: machineIdentifier)?.ecidHex
        } else {
            ecidHex = nil
        }

        let bootloader = createBootloader(romURL: options.romURL)

        let config = buildConfiguration(
            options: options,
            platform: platform,
            bootloader: bootloader,
        )

        try config.validate()
        print("[vphone] Configuration validated")

        virtualMachine = VZVirtualMachine(configuration: config)
        super.init()
        virtualMachine.delegate = self

        if let readHandle = serialOutputReadHandle {
            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                FileHandle.standardOutput.write(data)
            }
        }
    }

    // MARK: - Platform Configuration

    private func configurePlatform(
        machineIDURL: URL,
        nvramURL: URL,
        hardwareModel: VZMacHardwareModel,
    ) throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel

        let machineIdentifier = loadOrCreateMachineIdentifier(at: machineIDURL)
        platform.machineIdentifier = machineIdentifier

        let auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: nvramURL,
            hardwareModel: hardwareModel,
            options: .allowOverwrite,
        )
        platform.auxiliaryStorage = auxiliaryStorage

        setBootArgsSerialOutput(auxiliaryStorage)

        return platform
    }

    private func loadOrCreateMachineIdentifier(at url: URL) -> VZMacMachineIdentifier {
        if let savedData = try? Data(contentsOf: url),
           let savedID = VZMacMachineIdentifier(dataRepresentation: savedData)
        {
            print("[vphone] Loaded machineIdentifier (ECID stable)")
            return savedID
        }

        let newID = VZMacMachineIdentifier()
        try? newID.dataRepresentation.write(to: url)
        print("[vphone] Created new machineIdentifier -> \(url.lastPathComponent)")
        return newID
    }

    private func setBootArgsSerialOutput(_ auxiliaryStorage: VZMacAuxiliaryStorage) {
        let bootArgs = "serial=3 debug=0x104c04"
        guard let bootArgsData = bootArgs.data(using: .utf8) else { return }

        let success = Dynamic(auxiliaryStorage)
            ._setDataValue(bootArgsData, forNVRAMVariableNamed: "boot-args", error: nil)
            .asBool ?? false

        if success {
            print("[vphone] NVRAM boot-args: \(bootArgs)")
        }
    }

    // MARK: - Bootloader

    private func createBootloader(romURL: URL) -> VZMacOSBootLoader {
        let bootloader = VZMacOSBootLoader()
        Dynamic(bootloader)._setROMURL(romURL)
        return bootloader
    }

    // MARK: - Configuration Builder

    private func buildConfiguration(
        options: Configuration,
        platform: VZMacPlatformConfiguration,
        bootloader: VZMacOSBootLoader,
    ) -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.platform = platform
        config.cpuCount = max(options.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(options.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

        configureDisplay(config, screen: options.screenConfiguration)
        configureAudio(config)
        configureStorage(config, diskURL: options.diskURL)
        configureNetwork(config)
        configureSerialPort(config)
        configureInputDevices(config)
        configureSocketDevice(config)
        configureBattery(config)
        configureDebugStub(config, port: options.kernelDebugPort)
        configureSEP(config, options: options)

        return config
    }

    private func configureDisplay(_ config: VZVirtualMachineConfiguration, screen: ScreenConfiguration) {
        let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
        let displayConfiguration = VZMacGraphicsDisplayConfiguration(
            widthInPixels: screen.width,
            heightInPixels: screen.height,
            pixelsPerInch: screen.pixelsPerInch,
        )
        graphicsConfiguration.displays = [displayConfiguration]
        config.graphicsDevices = [graphicsConfiguration]
    }

    private func configureAudio(_ config: VZVirtualMachineConfiguration) {
        let soundDevice = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()

        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()

        soundDevice.streams = [inputStream, outputStream]
        config.audioDevices = [soundDevice]
    }

    private func configureStorage(_ config: VZVirtualMachineConfiguration, diskURL: URL) {
        guard FileManager.default.fileExists(atPath: diskURL.path) else {
            print("[vphone] Warning: Disk image not found at \(diskURL.path)")
            return
        }

        let attachment = try? VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        let storageDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment!)
        config.storageDevices = [storageDevice]
    }

    private func configureNetwork(_ config: VZVirtualMachineConfiguration) {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]
    }

    private func configureSerialPort(_ config: VZVirtualMachineConfiguration) {
        guard let serialPort = Dynamic._VZPL011SerialPortConfiguration().asObject as? VZSerialPortConfiguration else {
            return
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()

        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting,
        )

        forwardStandardInput(to: inputPipe.fileHandleForWriting)
        serialOutputReadHandle = outputPipe.fileHandleForReading

        config.serialPorts = [serialPort]
        print("[vphone] PL011 serial port attached (interactive)")
    }

    private func forwardStandardInput(to writeHandle: FileHandle) {
        let stdinFD = FileHandle.standardInput.fileDescriptor
        DispatchQueue.global(qos: .userInteractive).async {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = read(stdinFD, &buffer, buffer.count)
                guard bytesRead > 0 else { break }
                writeHandle.write(Data(buffer[..<bytesRead]))
            }
        }
    }

    private func configureInputDevices(_ config: VZVirtualMachineConfiguration) {
        if let touchScreen = Dynamic._VZUSBTouchScreenConfiguration().asObject {
            Dynamic(config)._setMultiTouchDevices([touchScreen])
            print("[vphone] USB touch screen configured")
        }

        config.keyboards = [VZUSBKeyboardConfiguration()]
    }

    private func configureSocketDevice(_ config: VZVirtualMachineConfiguration) {
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    }

    private func configureBattery(_ config: VZVirtualMachineConfiguration) {
        let syntheticBatterySource = Dynamic._VZMacSyntheticBatterySource()
        syntheticBatterySource.setCharge(100.0)
        syntheticBatterySource.setConnectivity(BatteryConnectivity.charging)

        let batteryConfiguration = Dynamic._VZMacBatteryPowerSourceDeviceConfiguration()
        batteryConfiguration.setSource(syntheticBatterySource.asObject)

        guard let batteryObject = batteryConfiguration.asObject else { return }

        Dynamic(config)._setPowerSourceDevices([batteryObject])
        batterySource = syntheticBatterySource.asObject as AnyObject?
        print("[vphone] Synthetic battery configured (100%, charging)")
    }

    private func configureDebugStub(_ config: VZVirtualMachineConfiguration, port: Int?) {
        guard let port else {
            configureDefaultDebugStub(config)
            return
        }

        guard (6000 ... 65535).contains(port) else {
            print("[vphone] Warning: Invalid kernel debug port \(port), using system-assigned")
            configureDefaultDebugStub(config)
            return
        }

        guard let debugStub = Dynamic._VZGDBDebugStubConfiguration(port: port).asObject else {
            configureDefaultDebugStub(config)
            return
        }

        Dynamic(config)._setDebugStub(debugStub)
        print("[vphone] Kernel GDB debug stub: tcp://127.0.0.1:\(port)")
    }

    private func configureDefaultDebugStub(_ config: VZVirtualMachineConfiguration) {
        let debugStub = Dynamic._VZGDBDebugStubConfiguration().asObject
        Dynamic(config)._setDebugStub(debugStub)
        print("[vphone] Kernel GDB debug stub enabled (system-assigned port)")
    }

    private func configureSEP(_ config: VZVirtualMachineConfiguration, options: Configuration) {
        let sepConfiguration = Dynamic._VZSEPCoprocessorConfiguration(storageURL: options.sepStorageURL)
        sepConfiguration.setRomBinaryURL(options.sepRomURL)
        sepConfiguration.setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)

        guard let sepObject = sepConfiguration.asObject else { return }

        Dynamic(config)._setCoprocessors([sepObject])
        print("[vphone] SEP coprocessor enabled (storage: \(options.sepStorageURL.path))")
    }

    // MARK: - Device Identity

    private static func resolveDeviceIdentity(machineIdentifier: VZMacMachineIdentifier) -> DeviceIdentity? {
        let ecidValue = extractECID(from: machineIdentifier)
        guard let ecidValue else { return nil }

        let cpidHex = String(format: "%08X", VPhoneHardware.udidChipID)
        let ecidHex = String(format: "%016llX", ecidValue)
        let udid = "\(cpidHex)-\(ecidHex)"

        return DeviceIdentity(cpidHex: cpidHex, ecidHex: ecidHex, udid: udid)
    }

    private static func extractECID(from machineIdentifier: VZMacMachineIdentifier) -> UInt64? {
        if let ecid = Dynamic(machineIdentifier)._ECID.asUInt64 {
            return ecid
        } else if let ecidNumber = Dynamic(machineIdentifier)._ECID.asObject as? NSNumber {
            return ecidNumber.uint64Value
        }
        return nil
    }

    // MARK: - Battery

    /// Update the synthetic battery charge and connectivity at runtime.
    func updateBattery(charge: Double, isCharging: Bool) {
        guard let source = batterySource else { return }
        Dynamic(source).setCharge(charge)
        Dynamic(source).setConnectivity(isCharging ? BatteryConnectivity.charging : BatteryConnectivity.disconnected)
    }

    // MARK: - Start

    @MainActor
    func start(forceDFU: Bool) async throws {
        let startOptions = VZMacOSVirtualMachineStartOptions()
        Dynamic(startOptions)._setForceDFU(forceDFU)
        Dynamic(startOptions)._setStopInIBootStage1(false)
        Dynamic(startOptions)._setStopInIBootStage2(false)

        print("[vphone] Starting\(forceDFU ? " DFU" : "")...")

        nonisolated(unsafe) let vm = virtualMachine
        try await vm.start(options: startOptions)

        if forceDFU {
            print("[vphone] VM started in DFU mode — connect with irecovery")
        } else {
            print("[vphone] VM started — booting normally")
        }

        logDebugStubPortIfNeeded(vm)
    }

    private func logDebugStubPortIfNeeded(_ vm: VZVirtualMachine) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            print("[vphone] Kernel GDB debug stub port query requires macOS 26+, skipped")
            return
        }

        guard let debugStub = Dynamic(vm)._configuration._debugStub.asAnyObject,
              let port = Dynamic(debugStub).port.asInt,
              port > 0
        else {
            return
        }

        print("[vphone] Kernel GDB debug stub listening on tcp://127.0.0.1:\(port)")
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

    nonisolated func virtualMachine(
        _: VZVirtualMachine,
        networkDevice _: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error,
    ) {
        print("[vphone] Network error: \(error)")
    }
}
