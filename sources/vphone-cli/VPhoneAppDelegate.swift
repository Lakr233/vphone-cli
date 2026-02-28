import AppKit
import Foundation
import Virtualization

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneCLI
    private var vm: VPhoneVM?
    private var windowController: VPhoneWindowController?
    private var menuController: VPhoneMenuController?
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
                try await self.startVM()
            } catch {
                print("[vphone] Fatal: \(error)")
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    private func startVM() async throws {
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
        print("Screen: \(cli.screenWidth)x\(cli.screenHeight) @ \(cli.screenPpi) PPI (scale \(cli.screenScale)x)")
        print("SEP   : enabled")
        print("  storage: \(cli.sepStorage)")
        print("  rom    : \(cli.sepRom)")
        print("")

        let options = VPhoneVM.Options(
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

        let vm = try VPhoneVM(options: options)
        self.vm = vm

        try await vm.start(forceDFU: cli.dfu)

        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm.virtualMachine)
            let wc = VPhoneWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: cli.screenWidth,
                screenHeight: cli.screenHeight,
                screenScale: cli.screenScale,
                keyHelper: keyHelper
            )
            windowController = wc
            menuController = VPhoneMenuController(keyHelper: keyHelper)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }
}
