import Dynamic
import Foundation
import Virtualization
import VPhoneCoreKit

/// Minimal VM for booting a vphone (virtual iPhone) in DFU mode.
@MainActor
class VPhoneVirtualMachine: NSObject, VZVirtualMachineDelegate {
    let virtualMachine: VZVirtualMachine
    /// The configuration actually used by this VM, rather than a pending preference.
    let usesHardwareKeyboard: Bool
    /// The manifest's unlock-at-startup setting as the VM started with it.
    let unlocksAtStartup: Bool
    /// The manifest's Sync Host Location setting as the VM started with it.
    let syncsHostLocation: Bool
    /// ECID hex string resolved from machineIdentifier (e.g. "0x0012345678ABCDEF").
    let ecidHex: String?
    private nonisolated let shaderCache: VPhoneShaderCache.Session?
    /// Read handle for VM serial output.
    private var serialOutputReadHandle: FileHandle?
    private var serialInputSource: DispatchSourceRead?
    /// Synthetic battery source for runtime charge/connectivity updates.
    private var batterySource: AnyObject?
    /// The in-process network backing `.tunnel` mode; nil for every other mode.
    /// Held because the sockets live only as long as this reference does.
    private var userspaceNetwork: VPhoneUserspaceNetwork?
    /// How the manifest's network was realized: attachment, MAC, the address
    /// vphoned should hold the guest to, and the ports forwarded into it.
    private(set) var networkPlan: VPhoneNetworkPlan?
    /// The attachment the VM booted with, put back by `setNetworkLink(up: true)`
    /// after a runtime change.
    private var bootAttachment: VZNetworkDeviceAttachment?

    struct Options {
        var configURL: URL
        var romURL: URL?
        var nvramURL: URL
        var diskURL: URL
        var cpuCount: Int = 8
        var memorySize: UInt64 = 8 * 1024 * 1024 * 1024
        var sepStorageURL: URL
        var sepRomURL: URL?
        var screenWidth: Int = 1290
        var screenHeight: Int = 2796
        var screenPPI: Int = 460
        var screenScale: Double = 3.0
        var kernelDebugPort: Int?
        /// The guest runs iPadOS: Esc is a key there, not the back gesture.
        var isPadGuest = false
        var usesTVOS = false
        var isTVGuest = false
        var isHomePodGuest = false
        /// The guest runs watchOS: its side button is a key of its own (consumer
        /// Help), apart from the crown (Home) and the power key.
        var isWatchGuest = false
        /// The guest is a foldable whose panel is sized per posture at boot;
        /// its window persists the position for the next start.
        var isFoldableGuest = false
    }

    private struct DeviceIdentity {
        let ecid: UInt64
        let cpidHex: String
        let ecidHex: String
        let udid: String
    }

    init(options: Options) throws {
        try Self.checkBundleFiles(options)

        // --- Hardware model (PV=3) ---
        let hwModel = try VPhoneHardware.createModel()
        print("[vphone] PV=3 hardware model: isSupported = true")

        // --- Load or create machineIdentifier from manifest ---
        let machineIdentifier: VZMacMachineIdentifier
        var manifest = try VPhoneVirtualMachineManifest.load(from: options.configURL)

        if !manifest.machineIdentifier.isEmpty,
           let savedID = VZMacMachineIdentifier(dataRepresentation: manifest.machineIdentifier)
        {
            machineIdentifier = savedID
            print("[vphone] Loaded machineIdentifier from config.plist (ECID stable)")
        } else {
            let reason = manifest.machineIdentifier.isEmpty
                ? "Created new machineIdentifier -> saved to config.plist"
                : "Invalid machineIdentifier in config.plist, created new"
            let newID = VZMacMachineIdentifier()
            machineIdentifier = newID

            manifest = manifest.updating(machineIdentifier: newID.dataRepresentation)
            try manifest.write(to: options.configURL)
            try VPhoneHostFilePermissions.makeAccessible(at: options.configURL)

            print("[vphone] \(reason)")
        }

        // --- MAC: generated once, then kept, like the machine identifier ---
        // A fixed MAC keeps the guest on one DHCP lease and is what a custom
        // NAT network reserves its address for.
        if manifest.networkConfig.mode != .off, manifest.networkConfig.macAddress.isEmpty {
            let mac = VPhoneMACAddress.randomLocallyAdministered()
            manifest = manifest.updating(networkConfig: manifest.networkConfig.with(macAddress: mac.description))
            try manifest.write(to: options.configURL)
            try VPhoneHostFilePermissions.makeAccessible(at: options.configURL)
            print("[vphone] Created MAC address \(mac) -> saved to config.plist")
        }

        // --- Platform ---
        let platform = VZMacPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier

        if let identity = Self.resolveDeviceIdentity(machineIdentifier: machineIdentifier) {
            ecidHex = identity.ecidHex
            print("[vphone] ECID: \(identity.ecidHex)")
            print("[vphone] Predicted UDID: \(identity.udid)")
            // The cache only saves recompiling; a VM that cannot keep one boots without it.
            do {
                let shaderCache = try VPhoneShaderCache.prepare(
                    machineDirectory: options.configURL.deletingLastPathComponent(), ecid: identity.ecid,
                )
                self.shaderCache = shaderCache
                print("[vphone] Shader cache: \(shaderCache.cacheURL.path)")
            } catch {
                shaderCache = nil
                print("[vphone] Warning: shader cache not kept for this run: \(error.localizedDescription)")
            }
            let outputURL = options.configURL.deletingLastPathComponent().appendingPathComponent(
                "udid-prediction.txt",
            )
            do {
                try Self.writeUDIDPrediction(identity: identity, to: outputURL)
                try VPhoneHostFilePermissions.makeAccessible(at: outputURL)
                print("[vphone] Wrote UDID prediction: \(outputURL.path)")
            } catch {
                print("[vphone] Warning: failed to write udid-prediction.txt: \(error)")
            }
        } else {
            ecidHex = nil
            shaderCache = nil
            print("[vphone] Warning: failed to resolve ECID from machineIdentifier")
        }

        let auxStorage: VZMacAuxiliaryStorage = if try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: options.nvramURL) {
            VZMacAuxiliaryStorage(url: options.nvramURL)
        } else {
            try VZMacAuxiliaryStorage(
                creatingStorageAt: options.nvramURL,
                hardwareModel: hwModel,
                options: [],
            )
        }
        try VPhoneHostFilePermissions.makeAccessible(at: options.nvramURL)
        platform.auxiliaryStorage = auxStorage
        platform.hardwareModel = hwModel

        // No boot-args are set here. The guest's come from the iBEC/LLB patch
        // (IBootPatcher.bootArgs and extraBootArgs), applied by `cfw install`:
        // the research iBoot reads its own NVRAM banks in this file, not the
        // store VZMacAuxiliaryStorage writes, so an NVRAM value set from the
        // host never reaches the guest.

        // --- Boot loader with custom ROM ---
        let bootloader = VZMacOSBootLoader()
        if let romURL = options.romURL {
            Dynamic(bootloader)._setROMURL(romURL)
        }

        // --- VM Configuration ---
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.platform = platform
        config.cpuCount = max(options.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(
            options.memorySize,
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        )

        // Display
        let gfx = VZMacGraphicsDeviceConfiguration()
        gfx.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: options.screenWidth,
                heightInPixels: options.screenHeight,
                pixelsPerInch: options.screenPPI,
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
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: options.diskURL) else {
            throw VPhoneVirtualMachineError.diskNotFound(options.diskURL.path)
        }
        let attachment = try VPhoneDiskAttachment.make(url: options.diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        // Network (mode, MAC, address and forwards from the bundle manifest)
        let plan = try VPhoneNetworking.plan(manifest.networkConfig)
        let network = try VPhoneNetworking.makeNetworkDevice(plan)
        config.networkDevices = network.configuration.map { [$0] } ?? []
        networkPlan = plan
        userspaceNetwork = network.userspaceNetwork
        print("[vphone] Network: \(Self.describe(plan))")

        // Serial port (PL011 UART - pipes for input/output with boot detection)
        if let serialPort = Dynamic._VZPL011SerialPortConfiguration().asObject
            as? VZSerialPortConfiguration
        {
            let inputPipe = Pipe()
            let outputPipe = Pipe()

            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: inputPipe.fileHandleForReading,
                fileHandleForWriting: outputPipe.fileHandleForWriting,
            )

            // Forward host stdin -> VM serial input
            let writeHandle = inputPipe.fileHandleForWriting
            let stdinFD = FileHandle.standardInput.fileDescriptor
            let inputSource = DispatchSource.makeReadSource(
                fileDescriptor: stdinFD, queue: .global(qos: .userInteractive),
            )
            inputSource.setEventHandler { @Sendable [weak inputSource] in
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(stdinFD, &buf, buf.count)
                if n > 0 {
                    try? writeHandle.write(contentsOf: Data(buf[..<n]))
                } else if n == 0 || errno != EINTR {
                    inputSource?.cancel()
                }
            }
            inputSource.setCancelHandler { @Sendable in try? writeHandle.close() }
            inputSource.activate()
            serialInputSource = inputSource

            serialOutputReadHandle = outputPipe.fileHandleForReading

            config.serialPorts = [serialPort]
            print("[vphone] PL011 serial port attached (interactive)")
        }

        if let obj1 = Dynamic._VZMacVideoToolboxDeviceConfiguration().asObject,
           let obj2 = Dynamic._VZMacNeuralEngineDeviceConfiguration().asObject,
           let obj3 = Dynamic._VZMacScalerAcceleratorDeviceConfiguration().asObject
        {
            Dynamic(config)._setAcceleratorDevices([obj1, obj2, obj3])
            print("[vphone] Accelerator devices configured")
        }

        // Multi-touch (USB touch screen)
        if let obj = Dynamic._VZUSBTouchScreenConfiguration().asObject {
            Dynamic(config)._setMultiTouchDevices([obj])
            print("[vphone] USB touch screen configured")
        }

        let obj = VZVirtioEntropyDeviceConfiguration()
        config.entropyDevices = [obj]
        print("[vphone] Entropy device configured")

        unlocksAtStartup = manifest.unlocksScreenAtStartup
        syncsHostLocation = manifest.sharesHostLocation
        usesHardwareKeyboard = manifest.usesHardwareKeyboard
        config.keyboards = usesHardwareKeyboard ? [VZUSBKeyboardConfiguration()] : []
        print("[vphone] Hardware keyboard: \(usesHardwareKeyboard ? "enabled" : "disabled")")

        // Vsock (host <-> guest control channel, no IP/TCP involved)
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Power source (synthetic battery - guest sees full charge, charging)
        let source = Dynamic._VZMacSyntheticBatterySource()
        source.setCharge(100.0)
        source.setConnectivity(1) // 1=charging, 2=disconnected
        let batteryConfig = Dynamic._VZMacBatteryPowerSourceDeviceConfiguration()
        batteryConfig.setSource(source.asObject)
        if let batteryObj = batteryConfig.asObject {
            Dynamic(config)._setPowerSourceDevices([batteryObj])
            batterySource = source.asObject as AnyObject?
            print("[vphone] Synthetic battery configured (100%, charging)")
        }

        // Kernel GDB debug stub (auto-assigned by default; fixed when explicitly requested)
        if let kernelDebugPort = options.kernelDebugPort {
            guard (6000 ... 65535).contains(kernelDebugPort) else {
                throw VPhoneVirtualMachineError.invalidKernelDebugPort(kernelDebugPort)
            }
            if let kernelDebugStub = Dynamic._VZGDBDebugStubConfiguration(port: kernelDebugPort)
                .asObject
            {
                Dynamic(config)._setDebugStub(kernelDebugStub)
                print("[vphone] Kernel GDB debug stub: tcp://127.0.0.1:\(kernelDebugPort)")
            } else {
                Dynamic(config)._setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)
                print("[vphone] Kernel GDB debug stub enabled (system-assigned port)")
            }
        } else {
            Dynamic(config)._setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)
            print("[vphone] Kernel GDB debug stub enabled (system-assigned port)")
        }

        // Coprocessors
        let sepConfig = Dynamic._VZSEPCoprocessorConfiguration(storageURL: options.sepStorageURL)
        if let sepRomURL = options.sepRomURL {
            sepConfig.setRomBinaryURL(sepRomURL)
        }
        sepConfig.setDebugStub(Dynamic._VZGDBDebugStubConfiguration().asObject)
        if let sepObj = sepConfig.asObject {
            Dynamic(config)._setCoprocessors([sepObj])
            print("[vphone] SEP coprocessor enabled (storage: \(options.sepStorageURL.path))")
        }

        // Validate
        try config.validate()
        print("[vphone] Configuration validated")

        virtualMachine = VZVirtualMachine(configuration: config)
        bootAttachment = virtualMachine.networkDevices.first?.attachment
        super.init()
        virtualMachine.delegate = self

        // Forward VM serial output -> host stdout
        if let readHandle = serialOutputReadHandle {
            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    return
                }
                FileHandle.standardOutput.write(data)
            }
        }
    }

    // MARK: - Bundle Files

    /// Cancel serial forwarding before another VM takes the same host stdin.
    func stopHostDevices() {
        finishShaderCache()
        serialInputSource?.cancel()
        serialInputSource = nil
        serialOutputReadHandle?.readabilityHandler = nil
        serialOutputReadHandle = nil
    }

    /// Every file below is opened, created or overwritten by this process or
    /// by Virtualization, and neither refuses a symbolic link. A bundle can
    /// come from someone else's export, so an entry that exists must be a
    /// regular file in the bundle itself. A missing NVRAM or SEP storage is
    /// fine, because it is created; a missing disk is not.
    private static func checkBundleFiles(_ options: Options) throws {
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: options.configURL) else {
            throw VPhoneManifestError.loadFailed(path: options.configURL.path)
        }
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: options.diskURL) else {
            throw VPhoneVirtualMachineError.diskNotFound(options.diskURL.path)
        }
        let others = [options.nvramURL, options.sepStorageURL, options.romURL, options.sepRomURL]
        for case let url? in others {
            try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: url)
        }
    }

    private static func resolveDeviceIdentity(machineIdentifier: VZMacMachineIdentifier)
        -> DeviceIdentity?
    {
        let ecidValue: UInt64? = if let ecid = Dynamic(machineIdentifier)._ECID.asUInt64 {
            ecid
        } else if let ecidNumber = Dynamic(machineIdentifier)._ECID.asObject as? NSNumber {
            ecidNumber.uint64Value
        } else {
            nil
        }

        guard let ecidValue else { return nil }

        let cpidHex = String(format: "%08X", VPhoneHardware.udidChipID)
        let ecidHex = String(format: "%016llX", ecidValue)
        let udid = "\(cpidHex)-\(ecidHex)"
        return DeviceIdentity(ecid: ecidValue, cpidHex: cpidHex, ecidHex: ecidHex, udid: udid)
    }

    private static func writeUDIDPrediction(identity: DeviceIdentity, to outputURL: URL) throws {
        let content = """
        UDID=\(identity.udid)
        CPID=0x\(identity.cpidHex)
        ECID=0x\(identity.ecidHex)
        MACHINE_IDENTIFIER=config.plist
        """
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Battery

    /// Update the synthetic battery charge and connectivity at runtime.
    /// - Parameters:
    ///   - charge: Battery percentage (0.0–100.0).
    ///   - connectivity: 1 = charging, 2 = disconnected.
    func setBattery(charge: Double, connectivity: Int) {
        guard let source = batterySource else { return }
        Dynamic(source).setCharge(charge)
        Dynamic(source).setConnectivity(connectivity)
    }

    // MARK: - Network

    enum NetworkControlError: Error, CustomStringConvertible {
        case noNetworkDevice

        var description: String {
            "This VM has no network device (network mode none)."
        }
    }

    /// The in-process network when the VM runs in `tunnel` mode.
    var tunnelNetwork: VPhoneUserspaceNetwork? {
        userspaceNetwork
    }

    /// The NIC as it is now, for `vphone.sock`'s `network` command.
    var networkStatus: [String: Any] {
        var status: [String: Any] = [:]
        if let plan = networkPlan {
            status["configured"] = Self.describe(plan)
            status["mac"] = plan.macAddress?.description ?? ""
            status["guest_ipv4"] = plan.guestIPv4?.description ?? ""
            status["forwards"] = plan.portForwards.map(\.description)
            status["local_host_name"] = plan.localHostName.map { "\($0).local" } ?? ""
        }
        guard let device = virtualMachine.networkDevices.first else {
            status["device"] = false
            return status
        }
        status["device"] = true
        status["link"] = device.attachment == nil ? "down" : "up"
        status["attachment"] = Self.describe(device.attachment)
        return status
    }

    /// Unplug or replug the guest's cable without stopping it. Down detaches
    /// the NIC from every network; up puts back the attachment it booted with.
    /// Neither is saved: the next launch reads config.plist again.
    ///
    /// Only that one attachment ever goes back. Handing a running VM a new
    /// attachment, even another `VZNATNetworkDeviceAttachment`, stopped it with
    /// an internal virtualization error (macOS 27 host, iOS 27 guest), so
    /// switching networks needs a restart.
    func setNetworkLink(up: Bool) throws {
        guard let device = virtualMachine.networkDevices.first else {
            throw NetworkControlError.noNetworkDevice
        }
        device.attachment = up ? bootAttachment : nil
        print("[vphone] Network link \(up ? "up" : "down")")
    }

    static func describe(_ plan: VPhoneNetworkPlan) -> String {
        var parts = switch plan.attachment {
        case .none: ["none"]
        case .sharedNAT: ["nat"]
        case let .bridged(interface): ["bridged(\(interface))"]
        case let .tunnel(configuration):
            ["tunnel(\(configuration.guestAddress)/\(configuration.prefixLength) via \(configuration.hostAddress))"]
        }
        if let mac = plan.macAddress {
            parts.append("mac \(mac)")
        }
        if case .manual = plan.guestIPv4 {
            parts.append("guest \(plan.guestIPv4!)")
        }
        if !plan.portForwards.isEmpty {
            parts.append("forwards \(plan.portForwards.map(\.description).joined(separator: ", "))")
        }
        if let name = plan.localHostName {
            parts.append("mdns \(name).local")
        }
        return parts.joined(separator: "  ")
    }

    static func describe(_ attachment: VZNetworkDeviceAttachment?) -> String {
        switch attachment {
        case nil: "none"
        case is VZNATNetworkDeviceAttachment: "nat"
        case let bridged as VZBridgedNetworkDeviceAttachment: "bridged(\(bridged.interface.identifier))"
        case is VZFileHandleNetworkDeviceAttachment: "tunnel"
        case let other?: String(describing: type(of: other))
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
        // Start draining before the framework touches the device, or the guest's
        // first DHCP request is sent into a socket nobody is reading.
        userspaceNetwork?.start()
        nonisolated(unsafe) let vm = virtualMachine
        try await vm.start(options: opts)
        if forceDFU {
            print("[vphone] VM started in DFU mode - connect with irecovery")
        } else {
            print("[vphone] VM started - booting normally")
        }

        // Print auto-assigned debug stub port after VM starts (private API, macOS 26+ only)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            if let debugStub = Dynamic(vm)._configuration._debugStub.asAnyObject {
                if let port = Dynamic(debugStub).port.asInt, port > 0 {
                    print("[vphone] Kernel GDB debug stub listening on tcp://127.0.0.1:\(port)")
                }
            }
        } else {
            print("[vphone] Kernel GDB debug stub port query requires macOS 26+, skipped")
        }
    }

    // MARK: - Delegate

    nonisolated func guestDidStop(_: VZVirtualMachine) {
        finishShaderCache()
        print("[vphone] Guest stopped")
        exit(EXIT_SUCCESS)
    }

    nonisolated func virtualMachine(_: VZVirtualMachine, didStopWithError error: Error) {
        finishShaderCache()
        print("[vphone] Stopped with error: \(error)")
        exit(EXIT_FAILURE)
    }

    private nonisolated func finishShaderCache() {
        guard let shaderCache else { return }
        do { try shaderCache.checkpoint() }
        catch { print("[vphone] Cannot save shader cache: \(error)") }
    }

    nonisolated func virtualMachine(
        _: VZVirtualMachine,
        networkDevice _: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error,
    ) {
        print("[vphone] Network error: \(error)")
    }
}
