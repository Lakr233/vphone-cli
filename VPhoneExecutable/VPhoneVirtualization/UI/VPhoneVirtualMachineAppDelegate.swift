import AppKit
import Foundation
import Virtualization
import VPhoneCoreKit

class VPhoneVirtualMachineAppDelegate: NSObject, NSApplicationDelegate {
    private let command: VPhoneBootCommand
    private var vm: VPhoneVirtualMachine?
    private var control: VPhoneGuestControl?
    private var windowController: VPhoneVirtualMachineWindowController?
    private var menuController: VPhoneMenuController?
    private var fileWindowController: VPhoneFileWindowController?
    private var keychainWindowController: VPhoneKeychainWindowController?
    private var appWindowController: VPhoneAppWindowController?
    private var locationProvider: VPhoneLocationProvider?
    private var timeZoneSync: VPhoneTimeZoneSync?
    private var clockSync: VPhoneClockSync?
    private var hostAudioLatencySync: VPhoneHostAudioLatencySync?
    private var hostAutomationServer: VPhoneHostAutomationServer?
    private var cameraServer: VPhoneCameraServer?
    private var apiProxy: VPhoneAPIProxy?
    private var portForwarder: VPhonePortForwarder?
    private var sigintSource: DispatchSourceSignal?
    private var didAttemptAutoInstall = false
    private var isRestartingVirtualMachine = false
    /// Set when the stop was asked for without the window or ⌘Q: a SIGINT
    /// from `vm stop` or Launchpad, which must not wait for an answer.
    private var stopConfirmed = false
    private var isConfirmingStop = false
    /// The guest was asked to shut down and the process waits for it to stop.
    private var isShuttingDownGuest = false
    /// The next quit ends the process, and the virtual machine with it.
    private var powersOffOnQuit = false
    /// How long a quit waits for the guest to shut down before turning it
    /// off. `vm stop` sends SIGKILL after 20 s by default, so it stays below.
    private static let guestShutdownTimeout: Duration = .seconds(15)

    init(command: VPhoneBootCommand) {
        self.command = command
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(command.noGraphics ? .prohibited : .regular)
        let name = VPhoneDockName.name(forConfig: command.config)
        VPhoneDockName.set(name)
        if !command.noGraphics {
            VPhoneDockName.label(name)
        }

        if !command.noGraphics {
            VPhoneHostHotKeys.shared.recoverAfterCrash()
        }

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in
            print("\n[vphone] SIGINT — shutting down")
            self?.stopConfirmed = true
            if self?.isConfirmingStop == true {
                // A quit is waiting on the question; this answers it.
                self?.answerStopQuestion()
            } else {
                NSApp.terminate(nil)
            }
        }
        src.activate()
        sigintSource = src

        Task { @MainActor in
            do {
                try await self.startVirtualMachine()
            } catch {
                print("[vphone] Fatal: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        let options = try command.resolveOptions()

        guard options.romURL == nil || FileManager.default.fileExists(atPath: options.romURL!.path) else {
            throw VPhoneVirtualMachineError.romNotFound(options.romURL!.path)
        }

        print("=== vphone-cli ===")
        print("ROM     : \(options.romURL?.path ?? "None")")
        print("Disk    : \(options.diskURL.path)")
        print("NVRAM   : \(options.nvramURL.path)")
        print("Config  : \(options.configURL.path)")
        print("CPU     : \(options.cpuCount)")
        print("Memory  : \(options.memorySize / 1024 / 1024) MB")
        print(
            "Screen: \(options.screenWidth)x\(options.screenHeight) @ \(options.screenPPI) PPI (scale \(options.screenScale)x)",
        )
        if let kernelDebugPort = options.kernelDebugPort {
            print("Kernel debug stub : 127.0.0.1:\(kernelDebugPort)")
        } else {
            print("Kernel debug stub : auto-assigned")
        }
        print("SEP               : enabled")
        print("  storage         : \(options.sepStorageURL.path)")
        print("  rom             : \(options.sepRomURL?.path ?? "None")")
        print("")

        let vm = try VPhoneVirtualMachine(options: options)
        self.vm = vm

        try await vm.start(forceDFU: command.dfu)

        let control = VPhoneGuestControl()
        self.control = control
        if !command.dfu {
            control.unlocksAtStartup = vm.unlocksAtStartup
            control.syncsGuestEnvironment = !options.isTVGuest
            control.syncsHostLocation = vm.syncsHostLocation
            control.guestDeviceName = Self.guestDeviceName(forConfig: options.configURL)
            startNetworkServices(vm: vm, control: control)
            let vphonedURL = URL(fileURLWithPath: command.vphonedBin)
            if FileManager.default.fileExists(atPath: vphonedURL.path) {
                control.guestBinaryURL = vphonedURL
            }

            let provider = VPhoneLocationProvider(control: control)
            locationProvider = provider
            timeZoneSync = VPhoneTimeZoneSync(control: control)
            clockSync = VPhoneClockSync(control: control)
            hostAudioLatencySync = VPhoneHostAudioLatencySync(control: control)

            let camServer = VPhoneCameraServer()
            cameraServer = camServer

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                control.connect(device: device)
                camServer.connect(device: device)
                if let listen = command.apiListen {
                    let hostScreen = VPhoneHostScreenService(
                        scale: options.screenScale,
                        display: { [weak vm] in vm?.virtualMachine.graphicsDevices.first?.displays.first },
                        interfaceDegrees: { [weak control] in
                            guard let control, control.isConnected,
                                  let result = try? await control.call("display.orientation")
                            else { return nil }
                            return (result["degrees"] as? NSNumber)?.intValue
                        },
                    )
                    let proxy = try VPhoneAPIProxy(device: device, listen: listen, hostScreen: hostScreen)
                    let (url, token) = try await proxy.start()
                    apiProxy = proxy
                    print("[api] HTTP/WebSocket API: \(url.absoluteString)")
                    print("[api] token: \(token)")
                    print("[api] send it as: Authorization: Bearer \(token)")
                }
            } else if command.apiListen != nil {
                throw VPhoneVirtualMachineError.apiSocketUnavailable
            }
        }

        let screenRecorder = VPhoneScreenRecorder()
        if !command.noGraphics {
            let keySender = VPhoneVirtualMachineKeySender(vm: vm, control: control)
            let wc = VPhoneVirtualMachineWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                hardwareKeyboardEnabled: vm.usesHardwareKeyboard,
                keySender: keySender,
                control: control,
                name: VPhoneDockName.name(forConfig: options.configURL),
                sceneIdentifier: options.configURL
                    .deletingLastPathComponent()
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path,
            )
            wc.captureView?.escapeIsBackGesture = !options.isPadGuest && !options.isTVGuest
            wc.captureView?.isTVGuest = options.isTVGuest
            wc.homeButtonHoldsInGuest = options.isTVGuest
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let keychainWC = VPhoneKeychainWindowController()
            keychainWindowController = keychainWC

            let appWC = VPhoneAppWindowController()
            appWindowController = appWC
            appWC.onRevealPath = { [weak fileWC, weak control] path in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control, path: path)
            }

            let mc = VPhoneMenuController(keySender: keySender, control: control)
            mc.guestPanelsWindowController.displayWindow = wc.displayWindow
            mc.vm = vm
            mc.onHardwareKeyboardChange = { [weak self] enabled in
                guard let self else { return }
                try await restartWithHardwareKeyboard(enabled)
            }
            mc.onFrameRateDisplayChange = { [weak wc] enabled in
                wc?.setFrameRateDisplay(enabled)
            }
            mc.onUnlockAtStartupChange = { [config = command.config] enabled in
                let manifest = try VPhoneVirtualMachineManifest.load(from: config)
                try manifest.updating(unlocksAtStartup: enabled).write(to: config)
                try VPhoneHostFilePermissions.makeAccessible(at: config)
            }
            mc.onHostLocationSyncChange = { [config = command.config] enabled in
                let manifest = try VPhoneVirtualMachineManifest.load(from: config)
                try manifest.updating(syncsHostLocation: enabled).write(to: config)
                try VPhoneHostFilePermissions.makeAccessible(at: config)
            }
            mc.captureView = wc.captureView
            mc.showsTVControls = options.isTVGuest
            mc.touchIDMonitor = wc.touchIDMonitor
            mc.onFilesPressed = { [weak fileWC, weak control] in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control)
            }
            mc.onKeychainPressed = { [weak keychainWC, weak control] in
                guard let keychainWC, let control else { return }
                keychainWC.showWindow(control: control)
            }
            mc.onFindPressed = { [weak keychainWC, weak appWC, weak control] in
                if appWC?.isKeyWindow == true {
                    appWC?.focusSearch()
                } else if keychainWC?.isKeyWindow == true {
                    keychainWC?.focusSearch()
                } else if let appWC, let control {
                    appWC.showWindow(control: control)
                    appWC.focusSearch()
                }
            }
            mc.onAppsPressed = { [weak appWC, weak control] in
                guard let appWC, let control else { return }
                appWC.showWindow(control: control)
            }
            if let provider = locationProvider {
                mc.locationProvider = provider
                provider.onAuthorizationFailure = { [weak mc] in
                    mc?.locationMenuItem?.state = .off
                    let alert = NSAlert()
                    alert.messageText = VPhoneLocalization.text("Host Location Unavailable")
                    alert.informativeText = VPhoneLocalization.text(
                        "Allow VPhone to use your location in System Settings > Privacy & Security > Location Services to sync the Mac's location.",
                    )
                    alert.runModal()
                }
                provider.onGuestLocationServicesOff = {
                    VPhoneAlert.present(
                        title: "Location Services Are Off in the Guest",
                        message: "Turn on Location Services in the guest's Settings > Privacy & Security > Location Services. Until then, apps in the guest get no location; the Mac's location is sent again once they are on.",
                        style: .informational,
                    )
                }
            }
            if let camServer = cameraServer {
                mc.cameraServer = camServer
                camServer.onConnectionStateChange = { [weak mc] connected in
                    Task { @MainActor in
                        mc?.updateCameraConnectionState(connected: connected)
                    }
                }
                mc.updateCameraConnectionState(connected: camServer.isConnected)
            }
            mc.screenRecorder = screenRecorder
            menuController = mc

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak self, weak mc, weak provider = locationProvider, weak timeZoneSync, weak clockSync, weak hostAudioLatencySync] caps in
                mc?.updateConnectAvailability(available: true)
                mc?.updateInstallAvailability(available: caps.contains("ipa_install"))
                mc?.updateBootstrapAvailability(available: caps.contains("bootstrap_install"))
                mc?.updateBootstrapUninstallAvailability(available: caps.contains("bootstrap_uninstall"))
                mc?.updateAppsAvailability(available: caps.contains("apps"))
                mc?.updateURLAvailability(available: caps.contains("url"))
                mc?.updateClipboardAvailability(available: caps.contains("clipboard"))
                mc?.updateSettingsAvailability(available: true)
                mc?.updateRestartAvailability(available: caps.contains("system_control"))
                mc?.updateShutDownAvailability(available: caps.contains("system_shutdown"))
                mc?.updateUDIDAvailability(available: caps.contains("udid_override"))
                mc?.updatePanelAvailability(capabilities: caps)
                if caps.contains("location") {
                    mc?.updateLocationCapability(available: true)
                    // Auto-resume if user had toggle on
                    if mc?.locationMenuItem?.state == .on {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
                mc?.syncBatteryFromHost()
                mc?.syncLowPowerModeFromHost()
                if caps.contains("timezone") {
                    timeZoneSync?.start()
                }
                if caps.contains("clock") {
                    clockSync?.start()
                }
                if caps.contains("audio_host_latency") {
                    hostAudioLatencySync?.start()
                }
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak mc, weak provider = locationProvider, weak timeZoneSync, weak clockSync, weak hostAudioLatencySync] in
                mc?.updateConnectAvailability(available: false)
                mc?.updateInstallAvailability(available: false)
                mc?.updateBootstrapAvailability(available: false)
                mc?.updateBootstrapUninstallAvailability(available: false)
                mc?.updateAppsAvailability(available: false)
                mc?.updateURLAvailability(available: false)
                mc?.updateClipboardAvailability(available: false)
                mc?.updateSettingsAvailability(available: false)
                mc?.updateRestartAvailability(available: false)
                mc?.updateShutDownAvailability(available: false)
                mc?.updateUDIDAvailability(available: false)
                mc?.updatePanelAvailability(capabilities: [])
                provider?.stopReplay()
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
                timeZoneSync?.stop()
                clockSync?.stop()
                hostAudioLatencySync?.stop()
            }
        } else if !command.dfu {
            // Headless mode: no menu, so the machine's setting alone decides.
            control.onConnect = { [weak self, weak control, weak provider = locationProvider, weak timeZoneSync, weak clockSync, weak hostAudioLatencySync] caps in
                if !caps.contains("location") {
                    print("[location] guest does not support location simulation")
                } else if control?.syncsHostLocation == true {
                    provider?.startForwarding()
                }
                if caps.contains("timezone") {
                    timeZoneSync?.start()
                }
                if caps.contains("clock") {
                    clockSync?.start()
                }
                if caps.contains("audio_host_latency") {
                    hostAudioLatencySync?.start()
                }
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak provider = locationProvider, weak timeZoneSync, weak clockSync, weak hostAudioLatencySync] in
                provider?.stopReplay()
                provider?.stopForwarding()
                timeZoneSync?.stop()
                clockSync?.stop()
                hostAudioLatencySync?.stop()
            }
        }

        // Headless launches serve the socket too, over guest-side input and screenshots.
        let socketPath = options.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("vphone.sock").path
        let server = VPhoneHostAutomationServer(socketPath: socketPath)
        server.start(
            captureView: windowController?.captureView,
            screenRecorder: screenRecorder,
            control: control,
            screenWidth: options.screenWidth,
            screenHeight: options.screenHeight,
        )
        server.virtualMachine = vm
        hostAutomationServer = server
    }

    /// The guest shows the VM's name, the folder holding config.plist, as its
    /// device name. A VM name that cannot be one is not used, and the guest
    /// keeps its own.
    private static func guestDeviceName(forConfig config: URL) -> String? {
        let name = VPhoneDockName.name(forConfig: config)
        do {
            try VPhoneGuestDeviceName.validate(name)
            return name
        } catch {
            print("[device] the VM name is not used as the device name: \(error)")
            return nil
        }
    }

    /// Hold the guest to its configured address and open its forwarded ports.
    @MainActor
    private func startNetworkServices(vm: VPhoneVirtualMachine, control: VPhoneGuestControl) {
        guard let plan = vm.networkPlan else { return }
        control.guestIPv4Setting = plan.guestIPv4
        control.guestLocalHostName = plan.localHostName
        control.guestStaticNames = {
            let bridged: VPhoneIPv4Address? = if case let .bridged(interface) = plan.attachment {
                VPhoneNetworking.ipv4Address(ofInterface: interface)
            } else {
                nil
            }
            return VPhoneNetworking.macStaticNames(
                plan: plan,
                macName: VPhoneNetworking.macLocalHostName(),
                bridgedAddress: bridged,
            )
        }
        guard !plan.portForwards.isEmpty else { return }

        let destination: VPhonePortForwarder.Destination = if case .tunnel = plan.attachment, let network = vm.tunnelNetwork {
            .tunnel(network)
        } else {
            .direct(plan.forwardingAddress)
        }
        let forwarder = VPhonePortForwarder(forwards: plan.portForwards, destination: destination)
        for failure in forwarder.start() {
            print("[network] port forward not opened: \(failure)")
        }
        print("[network] forwarding \(plan.portForwards.map(\.description).joined(separator: ", "))")
        // A DHCP guest's address is learned from vphoned, and can change. A
        // dropped connection to vphoned says nothing about the guest's address,
        // so the last one known is kept.
        if case .direct(nil) = destination {
            control.onGuestIPAddressChange = { [weak forwarder] ip in
                guard let address = ip.flatMap(VPhoneIPv4Address.init(dotted:)) else { return }
                forwarder?.updateGuestAddress(address)
            }
        }
        portForwarder = forwarder
    }

    @MainActor
    private func installPackageIfRequested(caps: [String]) async {
        guard !didAttemptAutoInstall else { return }
        guard let packageURL = command.installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            didAttemptAutoInstall = true
            print("[install] requested package not found: \(packageURL.path)")
            return
        }
        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            didAttemptAutoInstall = true
            print("[install] unsupported package type: \(packageURL.path)")
            return
        }
        guard caps.contains("ipa_install") else {
            print(
                "[install] guest does not advertise ipa_install; reconnect or reboot the guest so the updated daemon can take over",
            )
            return
        }
        guard let control else {
            print("[install] control channel is not ready")
            return
        }

        didAttemptAutoInstall = true
        print("[install] auto-installing \(packageURL.lastPathComponent)")
        do {
            let result = try await control.installIPA(localURL: packageURL)
            print("[install] \(result)")
        } catch {
            print("[install] failed: \(error)")
        }
    }

    @MainActor
    private func stopControlServices() {
        hostAutomationServer?.stop()
        portForwarder?.stop()
        apiProxy?.stop()
        control?.stop()
    }

    /// Virtualization copies the keyboard configuration when creating the VM.
    /// A guest reboot leaves the USB device in place. Rebuild the VM's devices
    /// inside the same NSApplication so the menu remains registered with macOS.
    @MainActor
    private func restartWithHardwareKeyboard(_ enabled: Bool) async throws {
        guard !isRestartingVirtualMachine else { return }
        isRestartingVirtualMachine = true
        defer { isRestartingVirtualMachine = false }
        try await stopForHardwareKeyboardChange(enabled)

        vm?.stopHostDevices()
        (NSApp as? VPhoneApplication)?.resetGuestKeyState()
        stopControlServices()
        locationProvider?.stopForwarding()
        locationProvider?.stopReplay()
        timeZoneSync?.stop()
        clockSync?.stop()
        hostAudioLatencySync?.stop()
        cameraServer?.disconnect()
        menuController?.stopBatteryMonitoring()
        menuController?.guestPanelsWindowController.closeAttitudeDials()
        windowController?.closeForRestart()
        // Tool windows belong to the old guest connection too.
        for window in NSApp.windows {
            window.close()
        }
        NSApp.mainMenu = nil
        windowController = nil
        menuController = nil
        fileWindowController = nil
        keychainWindowController = nil
        appWindowController = nil
        locationProvider = nil
        timeZoneSync = nil
        clockSync = nil
        hostAudioLatencySync = nil
        cameraServer = nil
        hostAutomationServer = nil
        apiProxy = nil
        control = nil
        vm = nil

        print("[vphone] Restarting with hardware keyboard \(enabled ? "enabled" : "disabled")")
        do {
            try await startVirtualMachine()
        } catch {
            VPhoneAlert.present(
                title: "Unable to Restart Virtual Machine",
                message: VPhoneLocalization.format("The virtual machine stopped and the keyboard setting was saved. Launch this machine again. Unable to restart: %@", error.localizedDescription),
                style: .warning,
            ) { _ in NSApp.terminate(nil) }
        }
    }

    @MainActor
    private func stopForHardwareKeyboardChange(_ enabled: Bool) async throws {
        guard let vm else { return }
        let manifest = try VPhoneVirtualMachineManifest.load(from: command.config)
        try manifest.updating(hardwareKeyboardEnabled: enabled).write(to: command.config)

        // An intentional stop must not go through guestDidStop's exit handler.
        vm.virtualMachine.delegate = nil
        do {
            nonisolated(unsafe) let machine = vm.virtualMachine
            try await machine.stop()
        } catch {
            vm.virtualMachine.delegate = vm
            // Preserve any other edits made while stop was in flight.
            let current = try VPhoneVirtualMachineManifest.load(from: command.config)
            try current.updating(hardwareKeyboardEnabled: vm.usesHardwareKeyboard).write(to: command.config)
            throw error
        }
    }

    func applicationWillTerminate(_: Notification) {
        stopControlServices()
    }

    /// Quitting shuts the guest down first and turns the virtual machine off
    /// once it has, or when it has not within `guestShutdownTimeout`. A guest
    /// that cannot be asked (in DFU, still starting up, or a vphoned without
    /// `system.shutdown`) is turned off at once. A quit from the window or ⌘Q
    /// asks first while the VM runs; a SIGINT stop and a headless VM do not.
    /// A second SIGINT while the guest shuts down, as a second Control-C,
    /// turns it off without waiting.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !powersOffOnQuit, vm != nil else { return .terminateNow }
        if isShuttingDownGuest {
            return stopConfirmed ? .terminateNow : .terminateCancel
        }
        guard !command.noGraphics, !stopConfirmed else { return stopGuest() }
        guard !isConfirmingStop else { return .terminateCancel }
        isConfirmingStop = true
        VPhoneAlert.present(
            title: "Stop the Virtual Machine?",
            message: canShutDownGuest
                ? "The guest shuts down, then the virtual machine stops. A guest still running after 15 seconds is turned off, as pulling the power would."
                : "Quitting turns the guest off at once, as pulling the power would. Anything not saved in the guest is lost.",
            style: .warning,
            buttons: ["Stop", "Cancel"],
        ) { [weak self] response in
            // A SIGINT that came while the question was up has answered it.
            guard let self, isConfirmingStop else { return }
            isConfirmingStop = false
            guard response == .alertFirstButtonReturn else {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            NSApp.reply(toApplicationShouldTerminate: stopGuest() == .terminateNow)
        }
        return .terminateLater
    }

    /// Answers a quit waiting on the stop question, as a SIGINT does.
    @MainActor
    private func answerStopQuestion() {
        isConfirmingStop = false
        if let window = VPhoneAlert.hostWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        NSApp.reply(toApplicationShouldTerminate: stopGuest() == .terminateNow)
    }

    @MainActor
    private var canShutDownGuest: Bool {
        guard !command.dfu, let control else { return false }
        return control.isConnected && control.guestCapabilities.contains("system_shutdown")
    }

    /// Asks the guest to shut down and cancels the quit, or turns the guest off
    /// now when it cannot be asked. `guestDidStop` exits the process once the
    /// guest has stopped.
    @MainActor
    private func stopGuest() -> NSApplication.TerminateReply {
        guard canShutDownGuest, let control else { return .terminateNow }
        isShuttingDownGuest = true
        print("[vphone] Asking the guest to shut down")
        Task { @MainActor [weak self] in
            do {
                try await control.shutDownGuest()
            } catch let VPhoneGuestControl.ControlError.guestError(message) {
                print("[vphone] Guest refused to shut down: \(message); turning it off")
                self?.powerOff()
            } catch {
                // The guest can stop before it replies, so the connection drops.
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.guestShutdownTimeout)
            print("[vphone] Guest still running after \(Self.guestShutdownTimeout); turning it off")
            self?.powerOff()
        }
        return .terminateCancel
    }

    @MainActor
    private func powerOff() {
        powersOffOnQuit = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !command.noGraphics && !isRestartingVirtualMachine
    }
}
