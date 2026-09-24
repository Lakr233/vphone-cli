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
    private var hostAutomationServer: VPhoneHostAutomationServer?
    private var cameraServer: VPhoneCameraServer?
    private var apiProxy: VPhoneAPIProxy?
    private var sigintSource: DispatchSourceSignal?
    private var didAttemptAutoInstall = false

    init(command: VPhoneBootCommand) {
        self.command = command
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(command.noGraphics ? .prohibited : .regular)

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            print("\n[vphone] SIGINT — shutting down")
            NSApp.terminate(nil)
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
            let vphonedURL = URL(fileURLWithPath: command.vphonedBin)
            if FileManager.default.fileExists(atPath: vphonedURL.path) {
                control.guestBinaryURL = vphonedURL
            }

            let provider = VPhoneLocationProvider(control: control)
            locationProvider = provider

            let camServer = VPhoneCameraServer()
            cameraServer = camServer

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                control.connect(device: device)
                camServer.connect(device: device)
                if let listen = command.apiListen {
                    let proxy = try VPhoneAPIProxy(device: device, listen: listen)
                    let url = try await proxy.start()
                    apiProxy = proxy
                    print("[api] HTTP/WebSocket API: \(url.absoluteString)")
                }
            } else if command.apiListen != nil {
                throw VPhoneVirtualMachineError.apiSocketUnavailable
            }
        }

        if !command.noGraphics {
            let keySender = VPhoneVirtualMachineKeySender(vm: vm, control: control)
            let wc = VPhoneVirtualMachineWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                keySender: keySender,
                control: control,
                ecid: vm.ecidHex,
                sceneIdentifier: options.configURL
                    .deletingLastPathComponent()
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path,
            )
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
            mc.vm = vm
            mc.captureView = wc.captureView
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
            let recorder = VPhoneScreenRecorder()
            mc.screenRecorder = recorder
            menuController = mc

            let socketPath = options.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path
            let server = VPhoneHostAutomationServer(socketPath: socketPath)
            server.start(
                captureView: wc.captureView!,
                screenRecorder: recorder,
                control: control,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
            )
            hostAutomationServer = server

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak self, weak mc, weak provider = locationProvider] caps in
                mc?.updateConnectAvailability(available: true)
                mc?.updateInstallAvailability(available: caps.contains("ipa_install"))
                mc?.updateBootstrapAvailability(available: caps.contains("bootstrap_install"))
                mc?.updateAppsAvailability(available: caps.contains("apps"))
                mc?.updateURLAvailability(available: caps.contains("url"))
                mc?.updateClipboardAvailability(available: caps.contains("clipboard"))
                mc?.updateSettingsAvailability(available: true)
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
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak mc, weak provider = locationProvider] in
                mc?.updateConnectAvailability(available: false)
                mc?.updateInstallAvailability(available: false)
                mc?.updateBootstrapAvailability(available: false)
                mc?.updateAppsAvailability(available: false)
                mc?.updateURLAvailability(available: false)
                mc?.updateClipboardAvailability(available: false)
                mc?.updateSettingsAvailability(available: false)
                mc?.updatePanelAvailability(capabilities: [])
                provider?.stopReplay()
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
            }
        } else if !command.dfu {
            // Headless mode: auto-start location as before (no menu exists)
            control.onConnect = { [weak self, weak provider = locationProvider] caps in
                if caps.contains("location") {
                    provider?.startForwarding()
                } else {
                    print("[location] guest does not support location simulation")
                }
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak provider = locationProvider] in
                provider?.stopReplay()
                provider?.stopForwarding()
            }
        }
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

    func applicationWillTerminate(_: Notification) {
        hostAutomationServer?.stop()
        apiProxy?.stop()
        control?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !command.noGraphics
    }
}
