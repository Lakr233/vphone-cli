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
        /// The source a Core Bundle sheet opens on.
        static var coreBundleSource = VPhoneLaunchpadCoreBundleView.Source.releases

        // MARK: - Driver

        static func run(_ model: VPhoneLaunchpadModel) async {
            guard let directory = outputDirectory else {
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let creation = VPhoneLaunchpadCreationPipeline(
                options: creationOptions,
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

                model.helper.applyPreview(.notInstalled)
                model.host.applyPreview(blocked: true)
                model.bundles.applyPreview(installing: false)
                await panel(model, .hostSetup, "01-host-setup-first-run", suffix)

                model.helper.applyPreview(.ready("1"))
                model.host.applyPreview(blocked: false)
                model.bundles.applyPreview(installing: true)
                await panel(model, .coreBundle, "02-core-bundle-first-install", suffix)

                model.bundles.applyPreview(installing: false)
                await panel(model, .coreBundle, "03-core-bundle", suffix)
                coreBundleSource = .actions
                await panel(model, .coreBundle, "03b-core-bundle-actions", suffix)
                coreBundleSource = .releases

                await panel(model, .hostSetup, "04-host-setup-passed", suffix)

                model.machines.selection = [path("research-01")]
                await shot("05-machines", suffix)
                model.showsInspector = false
                await shot("05a-machines-no-inspector", suffix)
                model.showsInspector = true
                if let machine = model.machines.selected {
                    await standalone("05b-machine-inspector", suffix, size: NSSize(width: 380, height: 980)) {
                        VPhoneLaunchpadMachineInspector(machine: machine, onShowProgress: { _ in }, onOpenConsole: { _ in })
                            .environment(model)
                    }
                }

                model.machines.selection = [path("ios27-rc")]
                await shot("06-machines-creating", suffix)

                await sheet(.newMachine, "07-new-machine", suffix)
                await standalone("07b-new-machine-advanced", suffix, size: NSSize(width: 520, height: 560)) {
                    VPhoneLaunchpadNewMachineAdvancedView(
                        network: .constant("nat"),
                        patches: .constant(VPhoneLaunchpadPatchSelection()),
                        keepArtifacts: .constant(false),
                        patchCatalog: nil,
                        patchCatalogError: nil,
                        reloadPatches: {},
                    )
                    .environment(model)
                }
                await sheet(.creation(path("ios27-rc")), "08-creation-progress", suffix)
                creation.applyPreview(failed: true)
                await sheet(.creation(path("ios27-rc")), "08b-creation-failed", suffix)
                creation.applyPreview()
                await standalone("08c-creation-log", suffix, size: NSSize(width: 960, height: 700)) {
                    VPhoneLaunchpadConsoleView(title: "ios27-rc Creation Log", url: creation.logFile)
                }
                model.machines.selection = [labMachine]
                if let machine = model.machines.selected {
                    await sheet(.settings([machine]), "09-machine-settings", suffix)
                }
                await standalone("09b-patch-settings", suffix, size: NSSize(width: 920, height: 680)) {
                    VPhoneLaunchpadPatchSettingsView(initial: VPhoneLaunchpadPatchSelection()) { _ in }
                        .environment(model)
                }
                await sheet(.clone(labMachine), "10-clone", suffix)
                await sheet(.export([labMachine]), "11-export", suffix)
                await sheet(.console(path("research-01")), "12-console", suffix)
            }
            NSApp.terminate(nil)
        }

        private static var mainWindow: NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }
        }

        private static func panel(
            _ model: VPhoneLaunchpadModel,
            _ panel: VPhoneLaunchpadModel.Panel,
            _ name: String,
            _ suffix: String,
        ) async {
            model.panel = panel
            await shot(name, suffix)
            model.panel = nil
            try? await Task.sleep(for: .milliseconds(800))
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

        static let artifacts: [VPhoneLaunchpadArtifact] = [
            artifact(1, "cd013c2a5e8f41b7d09c3e6a2f14b85d7c90e3a1", "2026-09-28T02:14:00Z"),
            artifact(2, "374a2c5f0b1e9d8c7a6b5d4e3f2a1b0c9d8e7f6a", "2026-09-27T16:40:00Z"),
        ]

        private static func artifact(_ id: Int64, _ commit: String, _ date: String) -> VPhoneLaunchpadArtifact {
            let created = ISO8601DateFormatter().date(from: date) ?? Date()
            return VPhoneLaunchpadArtifact(
                id: id,
                name: "vphone-release-\(commit)",
                commit: commit,
                branch: "main",
                runID: id,
                createdAt: created,
                expiresAt: created.addingTimeInterval(7 * 86400),
                size: 20_564_139,
                sha256: String(repeating: "0", count: 64),
                downloadURL: URL(string: "https://example.invalid/\(id).zip")!,
            )
        }

        static let machines: [VPhoneLaunchpadMachine] = {
            let json = """
            [
              {"name":"research-01","cpuCount":8,"memoryMB":8192,"diskSizeBytes":64000000000,
               "network":{"mode":"nat","macAddress":"5a:94:ef:12:30:01"},
               "restoreInfo":{"ios":{"version":"26.4.2","build":"23E261"},"cloudOS":{"version":"26.4","build":"23E224"},"variant":"jb","device":"iPhone99,11"},
               "udid":"00008140-001A2B3C4D5E6F70"},
              {"name":"ios27-rc","cpuCount":8,"memoryMB":12288,"diskSizeBytes":128000000000,
               "network":{"mode":"nat","macAddress":"5a:94:ef:12:30:02"}},
              {"name":"frida-lab","cpuCount":6,"memoryMB":8192,"diskSizeBytes":64000000000,
               "network":{"mode":"bridged","macAddress":"5a:94:ef:12:30:03","bridgeInterface":"en0"},
               "restoreInfo":{"ios":{"version":"26.6.2","build":"23G90"},"cloudOS":{"version":"26.4","build":"23E224"},"variant":"jb","device":"iPhone99,11"},
               "udid":"00008140-0011223344556677"}
            ]
            """
            var machines = (try? JSONDecoder().decode([VPhoneLaunchpadMachine].self, from: Data(json.utf8))) ?? []
            for index in machines.indices {
                machines[index].libraryRoot = machines[index].name == labMachine.name
                    ? labMachine.libraryRoot
                    : VPhoneLaunchpadMachineLocations.defaultRoot
            }
            return machines
        }()

        /// A machine in the default library.
        static func path(_ name: String) -> VPhoneLaunchpadMachinePath {
            VPhoneLaunchpadMachinePath(libraryRoot: VPhoneLaunchpadMachineLocations.defaultRoot, name: name)
        }

        /// A machine in a second library, on an external volume.
        static let labMachine = VPhoneLaunchpadMachinePath(libraryRoot: "/Volumes/Lab/machines", name: "frida-lab")

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
            libraryRoot: VPhoneLaunchpadMachineLocations.defaultRoot,
            iphoneSource: "https://updates.cdn-apple.com/example/iPhone17,3_27.0_24A435_Restore.ipsw",
            cloudOSSource: "https://updates.cdn-apple.com/example/cloudos-26.4",
            cpuCount: 8,
            memoryMB: 12288,
            diskSizeGB: 128,
            network: "nat",
            patches: VPhoneLaunchpadPatchSelection(),
            keepArtifacts: false,
        )

        /// Stands in for `fw patches --json`. `preset` moves the Frida patches in
        /// and out of the preset, as the real report does.
        static func patchCatalog(preset: String?) -> VPhoneLaunchpadPatchCatalog? {
            let active = preset ?? "standard"
            let frida = active == "extended"
            let json = """
            {"activePreset":"\(active)","blockedPatches":[],"allowedPatches":[],
             "presets":[
               {"identifier":"standard","title":"Standard","summary":"The patches every vphone VM needs to boot, jailbroken, with a working display and camera.","patchSets":[]},
               {"identifier":"extended","title":"Extended","summary":"Every patch this bundle declares, including the Frida Stalker relaxations.","patchSets":[]}
             ],
             "patches":[
               {"identifier":"avpbooter.dgst_bypass","title":"AVPBooter digest bypass","summary":"Accepts the resealed boot images instead of the stock digests.","patchSet":"com.vphone.patchset.bootchain","patchSetName":"Boot Chain","target":"AVPBooter","applicability":"any","bootEssential":true,"inPreset":true,"enabled":true},
               {"identifier":"ibss.serial_label","title":"iBSS serial label","summary":"Tags iBSS serial output so the boot log names its stage.","patchSet":"com.vphone.patchset.bootchain","patchSetName":"Boot Chain","target":"iBSS","applicability":"any","bootEssential":false,"inPreset":true,"enabled":true},
               {"identifier":"kernel.debugger","title":"Kernel debugger gate","summary":"Lets a debugger attach to any process in the guest.","patchSet":"com.vphone.patchset.kernel.base","patchSetName":"Kernel Base","target":"Kernel","applicability":"any","bootEssential":false,"inPreset":true,"enabled":true},
               {"identifier":"kernel.thread_guard_violation","title":"Thread guard violation","summary":"Stops the guard exception the older kernels raise on first boot.","patchSet":"com.vphone.patchset.kernel.base","patchSetName":"Kernel Base","target":"Kernel","applicability":"iOS 18.x","bootEssential":true,"inPreset":true,"enabled":true},
               {"identifier":"kernelcache_frida.thread_set_state_entitlement_flag","title":"Frida thread state entitlement","summary":"Lets Stalker set thread state without the entitlement the kernel asks for.","patchSet":"com.vphone.patchset.kernel.frida","patchSetName":"Frida Stalker","target":"Kernel","applicability":"cloudOS 26.4+","bootEssential":false,"inPreset":\(frida),"enabled":\(frida)},
               {"identifier":"kernelcache_frida.vm_map_delete_immutable_code","title":"Frida immutable code unmap","summary":"Allows Stalker to unmap the immutable code it rewrote.","patchSet":"com.vphone.patchset.kernel.frida","patchSetName":"Frida Stalker","target":"Kernel","applicability":"cloudOS 26.4+","bootEssential":false,"inPreset":\(frida),"enabled":\(frida)},
               {"identifier":"guest.vphoned","title":"Guest vphoned","summary":"Installs vphoned and its launch daemon into the guest.","patchSet":"com.vphone.patchset.guest.system","patchSetName":"Guest System","target":"Guest filesystem","applicability":"any","bootEssential":true,"inPreset":true,"enabled":true}
             ]}
            """
            return try? JSONDecoder().decode(VPhoneLaunchpadPatchCatalog.self, from: Data(json.utf8))
        }

        /// What a log terminal shows in snapshot mode instead of the file.
        static func log(for url: URL) -> [String] {
            url.lastPathComponent.hasSuffix("-create.log") ? creationLog : console
        }

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
