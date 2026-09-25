#if DEBUG
    import AppKit
    import SwiftUI

    /// Debug-only snapshot mode. Launched with VPHONE_LAUNCHPAD_SNAPSHOT_DIR
    /// set, the app fills every model with mock data, steps through each page
    /// and sheet in light and dark appearance, draws the window into a PNG
    /// with cacheDisplay (no screen-recording permission needed), and quits.
    enum VPhoneLaunchpadPreview {
        static let outputDirectory = ProcessInfo.processInfo.environment["VPHONE_LAUNCHPAD_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        static var isActive: Bool {
            outputDirectory != nil
        }

        static let sheetNotification = Notification.Name("VPhoneLaunchpadPreviewSheet")

        // MARK: - Driver

        static func run(_ model: VPhoneLaunchpadModel) async {
            guard let directory = outputDirectory else {
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let creation = VPhoneLaunchpadCreationPipeline(
                options: creationOptions,
                libraryRoot: model.libraryRoot,
                bundles: model.bundles,
                helper: model.helper,
                library: model.machines,
            )
            creation.applyPreview()
            model.machines.applyPreview(creation: creation)
            for command in commands.dropLast() {
                model.history.finish(model.history.record(command), status: 0)
            }
            _ = model.history.record(commands.last!)

            try? await Task.sleep(for: .seconds(1))
            if let window = mainWindow {
                window.setContentSize(NSSize(width: 980, height: 700))
                window.center()
            }

            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)

                model.previewSetupCompleted = false
                model.helper.applyPreview(.notInstalled)
                model.host.applyPreview(blocked: true)
                model.bundles.applyPreview(installing: false)
                model.selection = .hostSetup
                await shot("01-host-setup-first-run", suffix)

                model.helper.applyPreview(.ready("1"))
                model.host.applyPreview(blocked: false)
                model.bundles.applyPreview(installing: true)
                model.selection = .coreBundle
                await shot("02-core-bundle-first-install", suffix)

                model.bundles.applyPreview(installing: false)
                model.previewSetupCompleted = true
                model.selection = .coreBundle
                await shot("03-core-bundle", suffix)

                model.selection = .hostSetup
                await shot("04-host-setup-passed", suffix)

                model.machines.selection = "research-01"
                model.selection = .machines
                await shot("05-machines", suffix)
                if let machine = model.machines.selected {
                    await standalone("05b-machine-inspector", suffix, size: NSSize(width: 380, height: 980)) {
                        VPhoneLaunchpadMachineInspector(machine: machine) { _ in }
                            .environment(model)
                    }
                }

                model.machines.selection = "ios27-rc"
                await shot("06-machines-creating", suffix)

                await sheet(.newMachine, "07-new-machine", suffix)
                await sheet(.creation("ios27-rc"), "08-creation-progress", suffix)
                model.machines.selection = "frida-lab"
                if let machine = model.machines.selected {
                    await sheet(.settings(machine), "09-machine-settings", suffix)
                }
                await sheet(.clone("frida-lab"), "10-clone", suffix)
                await sheet(.export("frida-lab"), "11-export", suffix)
            }
            NSApp.terminate(nil)
        }

        private static var mainWindow: NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }
        }

        private static func sheet(_ sheet: VPhoneLaunchpadMachinesView.Sheet, _ name: String, _ suffix: String) async {
            NotificationCenter.default.post(name: sheetNotification, object: sheet)
            await shot(name, suffix)
            NotificationCenter.default.post(name: sheetNotification, object: nil)
            try? await Task.sleep(for: .milliseconds(800))
        }

        /// Draws one view in a plain window of its own. Used for the inspector,
        /// whose column cacheDisplay cannot draw inside the main window.
        private static func standalone(
            _ name: String,
            _ suffix: String,
            size: NSSize,
            @ViewBuilder content: () -> some View,
        ) async {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSApp.appearance
            window.contentView = NSHostingView(rootView: content())
            window.orderFront(nil)
            try? await Task.sleep(for: .milliseconds(1500))
            if let directory = outputDirectory, let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
            window.close()
        }

        private static func shot(_ name: String, _ suffix: String) async {
            try? await Task.sleep(for: .milliseconds(1500))
            guard let directory = outputDirectory, let window = mainWindow else {
                return
            }
            let target = window.attachedSheet ?? window
            guard let view = target.contentView?.superview ?? target.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }

        // MARK: - Mock data

        static let releases: [VPhoneLaunchpadRelease] = [
            release("2.0.2", "2026-09-25T09:10:00Z", "4be1f0c29a7d6e3b58c0a1d2e9f47b6c3d5a8e1f02b9c7d4e6a3f5b8c1d0e2a9", 16_170_112),
            release("2.0.1", "2026-09-25T03:53:35Z", "98daa4d0b00a6188f87c698e73018d497ca34396f31f95e9e872dd93e488322f", 16_162_877),
            release("2.0.0", "2026-09-24T19:56:17Z", "d57fd532e308dcc6901ec0d58e3a226da5e1a5ec022c2b2b3572894954f167b3", 16_160_944),
        ]

        private static func release(_ version: String, _ date: String, _ sha256: String, _ size: Int64) -> VPhoneLaunchpadRelease {
            VPhoneLaunchpadRelease(
                version: version,
                publishedAt: ISO8601DateFormatter().date(from: date) ?? Date(),
                isPrerelease: true,
                assetName: "VPhone-\(version).zip",
                downloadURL: URL(string: "https://example.invalid/VPhone-\(version).zip")!,
                size: size,
                sha256: sha256,
            )
        }

        static let machines: [VPhoneLaunchpadMachine] = {
            let json = """
            [
              {"name":"research-01","cpuCount":8,"memoryMB":8192,"diskSizeBytes":68719476736,
               "network":{"mode":"nat","macAddress":"5a:94:ef:12:30:01"},
               "restoreInfo":{"ios":{"version":"26.4.2","build":"23E261"},"cloudOS":{"version":"26.4","build":"23E224"},"variant":"jb","device":"iPhone99,11"},
               "udid":"00008140-001A2B3C4D5E6F70"},
              {"name":"ios27-rc","cpuCount":8,"memoryMB":12288,"diskSizeBytes":137438953472,
               "network":{"mode":"nat","macAddress":"5a:94:ef:12:30:02"}},
              {"name":"frida-lab","cpuCount":6,"memoryMB":8192,"diskSizeBytes":68719476736,
               "network":{"mode":"bridged","macAddress":"5a:94:ef:12:30:03","bridgeInterface":"en0"},
               "restoreInfo":{"ios":{"version":"26.6.2","build":"23G90"},"cloudOS":{"version":"26.4","build":"23E224"},"variant":"jb","device":"iPhone99,11"},
               "udid":"00008140-0011223344556677"}
            ]
            """
            return (try? JSONDecoder().decode([VPhoneLaunchpadMachine].self, from: Data(json.utf8))) ?? []
        }()

        static let catalog: VPhoneLaunchpadFirmwareCatalog? = {
            let base = "https://updates.cdn-apple.com/example"
            let json = """
            {"device":"iPhone17,3","pairings":[
              {"ios":{"name":"iOS 26.4.2","url":"\(base)/iPhone17,3_26.4.2_23E261_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iOS 26.5.2","url":"\(base)/iPhone17,3_26.5.2_23F84_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iOS 26.6.2","url":"\(base)/iPhone17,3_26.6.2_23G90_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iOS 27.0 RC","url":"\(base)/iPhone17,3_27.0_24A435_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}}
            ]}
            """
            return try? JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: Data(json.utf8))
        }()

        static let creationOptions = VPhoneLaunchpadCreationPipeline.Options(
            name: "ios27-rc",
            iphoneSource: "https://updates.cdn-apple.com/example/iPhone17,3_27.0_24A435_Restore.ipsw",
            cloudOSSource: "https://updates.cdn-apple.com/example/cloudos-26.4",
            cpuCount: 8,
            memoryMB: 12288,
            diskSizeGB: 128,
            network: "nat",
            enableFrida: false,
            forceDyldSharedCacheMaxSlide: false,
            keepArtifacts: false,
        )

        static let console = [
            "[vphone] Loaded VM manifest from ~/.vphone/machines/research-01/config.plist",
            "[vphone] Starting guest (PV=3, 8 CPU, 8192 MB)",
            "[vphone] Guest control connected on vsock 1339",
            "[vphoned] ping ok",
            "[vphone] Display 1179x2556 @ 460 ppi",
        ]

        static let creationLog = [
            "$ vphone-cli vm new ios27-rc --cpu 8 --memory 12288 --disk-size 128",
            "created ~/.vphone/machines/ios27-rc",
            "$ vphone-cli fw prepare ios27-rc --iphone-source … --cloudos-source …",
            "[+] Firmware prepared (iPhone + cloudOS merged into bundle).",
            "$ vphone-cli fw patch ios27-rc",
            "[fw patch] applied JB patches",
            "$ vphone-cli vm launch ios27-rc --dfu",
            "$ vphone-cli recovery-probe --ecid 001A2B3C4D5E6F71 --timeout 2  (up to 90 attempts)",
            "device endpoint is reachable",
            "$ vphone-cli restore ios27-rc",
            "restore  Sending RestoreRamDisk…",
            "restore  Waiting for device to enter restore mode…",
            "restore  Verifying restore images…",
        ]

        static let commands = [
            "vphone-cli host preflight --quiet",
            "vphone-cli vm list --json --library-root ~/.vphone/machines",
            "vphone-cli vm new ios27-rc --cpu 8 --memory 12288 --disk-size 128",
            "vphone-cli fw prepare ios27-rc --iphone-source … --cloudos-source …",
            "vphone-cli fw patch ios27-rc",
            "vphone-cli vm launch research-01 --library-root ~/.vphone/machines",
            "vphone-cli restore ios27-rc --library-root ~/.vphone/machines",
        ]
    }
#endif
