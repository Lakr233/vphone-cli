import AppKit
import Foundation
import Virtualization

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneCLI
    private var vm: VPhoneVM?
    private var windowController: VPhoneWindowController?
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

        print("=== vphone-cli ===")
        print("ROM   : \(cli.rom)")
        print("Disk  : \(cli.disk)")
        print("NVRAM : \(cli.nvram)")
        print("CPU   : \(cli.cpu)")
        print("Memory: \(cli.memory) MB")

        let sepStorageURL = cli.sepStorage.map { URL(fileURLWithPath: $0) }
        let sepRomURL = cli.sepRom.map { URL(fileURLWithPath: $0) }

        print("SEP   : \(cli.skipSep ? "skipped" : "enabled")")
        if !cli.skipSep {
            print("  storage: \(cli.sepStorage ?? "(auto)")")
            if let r = cli.sepRom { print("  rom    : \(r)") }
        }
        print("")

        let options = VPhoneVM.Options(
            romURL: romURL,
            nvramURL: nvramURL,
            diskURL: diskURL,
            cpuCount: cli.cpu,
            memorySize: UInt64(cli.memory) * 1024 * 1024,
            skipSEP: cli.skipSep,
            sepStorageURL: sepStorageURL,
            sepRomURL: sepRomURL
        )

        let vm = try VPhoneVM(options: options)
        self.vm = vm

        vm.onStop = {
            NSApp.terminate(nil)
        }

        try await vm.start(forceDFU: cli.dfu)

        if !cli.noGraphics {
            let wc = VPhoneWindowController()
            wc.showWindow(for: vm.virtualMachine)
            windowController = wc
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }

}
