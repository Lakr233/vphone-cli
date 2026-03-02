import AppKit
import Foundation
import Virtualization

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneCLI
    private var vm: VPhoneVirtualMachine?
    private var control: VPhoneControl?
    private var windowController: VPhoneWindowController?
    private var menuController: VPhoneMenuController?
    private var fileWindowController: VPhoneFileWindowController?
    private var locationProvider: VPhoneLocationProvider?
    private var sigintSource: DispatchSourceSignal?

    init(cli: VPhoneCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(cli.noGraphics ? .prohibited : .regular)

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
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        let romURL = URL(fileURLWithPath: cli.rom)
        guard FileManager.default.fileExists(atPath: romURL.path) else {
            throw VPhoneError.romNotFound(cli.rom)
        }

        let diskURL = URL(fileURLWithPath: cli.disk)
        let nvramURL = URL(fileURLWithPath: cli.nvram)
        let machineIDURL = URL(fileURLWithPath: cli.machineId)
        let sepStorageURL = URL(fileURLWithPath: cli.sepStorage)
        let sepRomURL = URL(fileURLWithPath: cli.sepRom)

        print("=== vphone-cli ===")
        print("ROM   : \(cli.rom)")
        print("Disk  : \(cli.disk)")
        print("NVRAM : \(cli.nvram)")
        print("MachID: \(cli.machineId)")
        print("CPU   : \(cli.cpu)")
        print("Memory: \(cli.memory) MB")
        print(
            "Screen: \(cli.screenWidth)x\(cli.screenHeight) @ \(cli.screenPpi) PPI (scale \(cli.screenScale)x)"
        )
        print("SEP   : enabled")
        print("  storage: \(cli.sepStorage)")
        print("  rom    : \(cli.sepRom)")
        print("")

        let options = VPhoneVirtualMachine.Options(
            romURL: romURL,
            nvramURL: nvramURL,
            machineIDURL: machineIDURL,
            diskURL: diskURL,
            cpuCount: cli.cpu,
            memorySize: UInt64(cli.memory) * 1024 * 1024,
            sepStorageURL: sepStorageURL,
            sepRomURL: sepRomURL,
            screenWidth: cli.screenWidth,
            screenHeight: cli.screenHeight,
            screenPPI: cli.screenPpi,
            screenScale: cli.screenScale
        )

        let vm = try VPhoneVirtualMachine(options: options)
        self.vm = vm

        try await vm.start(forceDFU: cli.dfu)

        let control = VPhoneControl()
        self.control = control
        if !cli.dfu {
            let vphonedURL = URL(fileURLWithPath: cli.vphonedBin)
            if FileManager.default.fileExists(atPath: vphonedURL.path) {
                control.guestBinaryURL = vphonedURL
            }

            let provider = VPhoneLocationProvider(control: control)
            locationProvider = provider

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                control.connect(device: device)
            }
        }

        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            let wc = VPhoneWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: cli.screenWidth,
                screenHeight: cli.screenHeight,
                screenScale: cli.screenScale,
                keyHelper: keyHelper,
                control: control
            )
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let mc = VPhoneMenuController(keyHelper: keyHelper, control: control)
            mc.onFilesPressed = { [weak fileWC, weak control] in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control)
            }
            if let provider = locationProvider {
                mc.locationProvider = provider
            }
            menuController = mc

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak mc, weak provider = locationProvider] caps in
                if caps.contains("location") {
                    mc?.updateLocationCapability(available: true)
                    // Auto-resume if user had toggle on
                    if mc?.locationMenuItem?.state == .on {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
            }
            control.onDisconnect = { [weak mc, weak provider = locationProvider] in
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
            }
        } else if !cli.dfu {
            // Headless mode: auto-start location as before (no menu exists)
            control.onConnect = { [weak provider = locationProvider] caps in
                if caps.contains("location") {
                    provider?.startForwarding()
                } else {
                    print("[location] guest does not support location simulation")
                }
            }
            control.onDisconnect = { [weak provider = locationProvider] in
                provider?.stopForwarding()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }
}
