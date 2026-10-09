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
        /// The pages New Machine and machine settings open on.
        static var newMachinePage = VPhoneLaunchpadNewMachineView.Page.basic
        static var machineSettingsPage = VPhoneLaunchpadMachineSettingsView.Page.general
        /// The patch choice New Machine opens with.
        static var newMachinePatches = VPhoneLaunchpadPatchSelection()

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
            creation.applyPreview(.restoring)
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
                model.leases.applyPreview(orphans: 0)
                model.bundles.applyPreview(installing: false)
                await panel(model, .hostSetup, "01-host-setup-first-run", suffix)

                model.helper.applyPreview(.ready("1"))
                model.host.applyPreview(blocked: false)
                model.bundles.applyPreview(installing: true)
                await panel(model, .coreBundle, "02-core-bundle-first-install", suffix)

                model.bundles.applyPreview(installing: false)
                await panel(model, .coreBundle, "03-core-bundle", suffix)

                model.leases.applyPreview(orphans: 119)
                await panel(model, .hostSetup, "04-host-setup-passed", suffix)
                await standalone("04b-skill-install", suffix, size: NSSize(width: 520, height: 460)) {
                    VPhoneLaunchpadSkillInstallView()
                }

                model.machines.selection = [path("research-01")]
                await shot("05-machines", suffix)
                // A deleted machine takes its table row with it. A cell that
                // reads the model from the environment crashes the run here
                // unless the column injects it.
                model.machines.applyPreview(removing: labMachine)
                await shot("05c-machines-after-delete", suffix)
                model.machines.applyPreview(creation: creation)
                if let machine = model.machines.selected {
                    await standalone("05b-machine-inspector", suffix, size: NSSize(width: 380, height: 1500)) {
                        VPhoneLaunchpadMachineInspector(machine: machine, onShowProgress: { _ in })
                            .environment(model)
                    }
                }

                model.machines.selection = [path("ios27-rc")]
                await shot("06-machines-creating", suffix)

                await sheet(.newMachine, "07-new-machine", suffix)
                newMachinePage = .hardware
                await sheet(.newMachine, "07-new-machine-hardware", suffix)
                newMachinePage = .firmware
                await sheet(.newMachine, "07-new-machine-firmware", suffix)
                newMachinePage = .storage
                await sheet(.newMachine, "07-new-machine-storage", suffix)
                newMachinePage = .patches
                // One boot-chain and one guest patch off: the guest one is
                // applied to the clone, not built into the template.
                newMachinePatches = VPhoneLaunchpadPatchSelection(blocked: ["ibss-cfw-serial_label", "dyld-cfw-camera"])
                await sheet(.newMachine, "07c-new-machine-guest-patches", suffix)
                // The basic page counts the patch change under Advanced Options.
                newMachinePage = .basic
                await sheet(.newMachine, "07d-new-machine-changed", suffix)
                newMachinePatches = VPhoneLaunchpadPatchSelection()
                newMachinePage = .slimming
                await sheet(.newMachine, "07b-new-machine-slimming", suffix)
                newMachinePage = .basic
                await sheet(.creation(path("ios27-rc")), "08-creation-progress", suffix)
                creation.applyPreview(.downloading(0.42))
                await sheet(.creation(path("ios27-rc")), "08a-creation-downloading", suffix)
                creation.applyPreview(.failed)
                await sheet(.creation(path("ios27-rc")), "08b-creation-failed", suffix)
                creation.applyPreview(.settingUpTemplate)
                await sheet(.creation(path("ios27-rc")), "08d-creation-template-setup", suffix)
                creation.applyPreview(.setupFailed)
                await sheet(.creation(path("ios27-rc")), "08e-creation-template-failed", suffix)
                creation.applyPreview(.builtTemplate)
                await sheet(.creation(path("ios27-rc")), "08f-creation-template-built", suffix)
                creation.applyPreview(.clonedFromTemplate)
                await sheet(.creation(path("ios27-rc")), "08g-creation-from-template", suffix)
                creation.applyPreview(.applyingGuestPatches)
                await sheet(.creation(path("ios27-rc")), "08h-creation-guest-patches", suffix)
                creation.applyPreview(.restoring)
                await standalone("08c-creation-log", suffix, size: NSSize(width: 960, height: 700)) {
                    VPhoneLaunchpadConsoleView(title: "ios27-rc Creation Log", url: creation.logFile)
                }
                model.machines.selection = [labMachine]
                if let machine = model.machines.selected {
                    await sheet(.settings([machine]), "09-machine-settings", suffix)
                    machineSettingsPage = .network
                    await sheet(.settings([machine]), "09-machine-settings-network", suffix)
                    machineSettingsPage = .forwards
                    await sheet(.settings([machine]), "09-machine-settings-forwards", suffix)
                    machineSettingsPage = .general
                }
                await standalone("09b-patch-settings", suffix, size: NSSize(width: 920, height: 680)) {
                    VPhoneLaunchpadPatchSettingsView(initial: VPhoneLaunchpadPatchSelection()) { _ in }
                        .environment(model)
                }
                await standalone("09c-patch-settings-machine", suffix, size: NSSize(width: 920, height: 680)) {
                    VPhoneLaunchpadPatchSettingsView(
                        initial: patchCatalog(preset: nil, machine: true)?.selection ?? VPhoneLaunchpadPatchSelection(),
                        machine: labMachine,
                    ) { _ in }
                        .environment(model)
                }
                await sheet(.clone(labMachine), "10-clone", suffix)
                await sheet(.snapshots(labMachine), "10a-snapshots", suffix)
                await sheet(.snapshots(path("research-01")), "10b-snapshots-running", suffix)
                snapshots = []
                await sheet(.snapshots(labMachine), "10c-snapshots-empty", suffix)
                snapshots = sampleSnapshots
                await standalone("10d-take-snapshot", suffix, size: NSSize(width: 420, height: 330)) {
                    VPhoneLaunchpadTakeSnapshotSheet(machine: labMachine, taken: Set(sampleSnapshots.map(\.name))) { _, _ in }
                }
                await sheet(.console(path("research-01")), "12-console", suffix)
                ipswSelection = ipswScan.ipsws[1].id
                await panel(model, .ipswCache, "13-downloaded-ipsws", suffix)
                ipswSelection = ipswScan.ipsws[0].id
                await panel(model, .ipswCache, "13a-downloaded-ipsws-in-use", suffix)
                await panel(model, .templates, "14-templates", suffix)
                guestSystemRunning = true
                await sheet(.guestSystem(path("research-01")), "15-guest-system", suffix)
                // Switched to None: the guest no longer reports a restart.
                guestSystemRestartPending = true
                await sheet(.guestSystem(path("research-01")), "15b-guest-system-restart-pending", suffix)
                guestSystemRestartPending = false
                guestSystemRunning = false
                await sheet(.guestSystem(labMachine), "15a-guest-system-stopped", suffix)
                model.machines.applyPreviewNotice()
                await shot("16-template-notice", suffix)
                model.machines.templateNotice = nil
                try? await Task.sleep(for: .milliseconds(800))
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
                NSLog("[preview] no shot for \(name): \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) sheet=\($0.isSheet) \($0.frame)" })")
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

        /// Stands in for `vm snapshot list --json`. The sheet reads this one, so
        /// the driver can empty it.
        static var snapshots = sampleSnapshots

        static let sampleSnapshots: [VPhoneLaunchpadMachineSnapshot] = {
            let json = """
            [{"created":"2026-09-30T08:12:44Z","name":"fresh-install","note":"Setup Assistant skipped, nothing installed"},
             {"created":"2026-10-03T14:05:10Z","name":"frida-17.2","note":"frida-server 17.2 from the package manager, before the Stalker patch test"},
             {"created":"2026-10-06T14:30:00Z","name":"2026-10-06-2230"}]
            """
            return (try? VPhoneLaunchpadMachineSnapshot.list(from: Data(json.utf8))) ?? []
        }()

        static let machines: [VPhoneLaunchpadMachine] = {
            let json = """
            [
              {"name":"research-01","cpuCount":8,"memoryMB":8192,"diskSizeBytes":64000000000,
               "network":{"mode":"nat","macAddress":"5a:94:ef:12:30:01"},
               "restoreInfo":{"ios":{"version":"26.4.2","build":"23E261"},"cloudOS":{"version":"26.4","build":"23E224"},"variant":"jb","device":"iPhone99,11"},
               "udid":"00008140-001A2B3C4D5E6F70",
               "unlocksAtStartup":true, "syncsHostLocation":true,
               "template":"52b1fcc75e0c","templateMatch":"current"},
              {"name":"ios27-rc","cpuCount":8,"memoryMB":12288,"diskSizeBytes":128000000000,
               "network":{"mode":"nat","macAddress":"5a:94:ef:12:30:02"}},
              {"name":"frida-lab","cpuCount":6,"memoryMB":8192,"diskSizeBytes":64000000000,
               "network":{"mode":"bridged","macAddress":"5a:94:ef:12:30:03","bridgeInterface":"en0"},
               "restoreInfo":{"ios":{"version":"26.6.2","build":"23G90"},"cloudOS":{"version":"26.4","build":"23E224"},"variant":"jb","device":"iPhone99,11"},
               "udid":"00008140-0011223344556677",
               "template":"2246f982776c","templateMatch":"current"}
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
            let iPhone = """
            [
              {"ios":{"name":"iOS 26.4.2","url":"\(base)/iPhone17,3_26.4.2_23E261_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iOS 26.5.2","url":"\(base)/iPhone17,3_26.5.2_23F84_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iOS 26.6.2","url":"\(base)/iPhone17,3_26.6.2_23G90_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iOS 27.0 RC","url":"\(base)/iPhone17,3_27.0_24A435_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}}
            ]
            """
            let iPad = """
            [
              {"ios":{"name":"iPadOS 26.6.2","url":"\(base)/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}},
              {"ios":{"name":"iPadOS 27.0.1","url":"\(base)/iPad16,1,iPad16,2_27.0.1_24A446_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"\(base)/cloudos-26.4"}}
            ]
            """
            let json = """
            {"device":"iPhone17,3","pairings":\(iPhone),"devices":[
              {"productType":"iPhone17,3","name":"iPhone 16","family":"iPhone","pairings":\(iPhone)},
              {"productType":"iPad16,1","name":"iPad mini (A17 Pro)","family":"iPad","pairings":\(iPad)}
            ]}
            """
            return try? JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: Data(json.utf8))
        }()

        /// Stands in for the IPSW cache: the creation's source, IPSWs the
        /// restored machines were made from, and one nothing uses.
        static let ipswScan: VPhoneLaunchpadIPSWCache.Scan = {
            let base = "https://updates.cdn-apple.com/example"
            let cache = VPhoneLaunchpadIPSWCache.sharedDirectory
            func file(_ source: String, _ size: Int64, facts: VPhoneLaunchpadIPSW? = nil) -> VPhoneLaunchpadIPSWFile {
                let name = VPhoneLaunchpadIPSW.cacheName(for: URL(string: source)!)
                return VPhoneLaunchpadIPSWFile(
                    url: cache.appendingPathComponent(name),
                    name: name,
                    size: size,
                    facts: facts ?? VPhoneLaunchpadIPSW(fileName: name),
                    isDownloading: false,
                )
            }
            let cloudOS = VPhoneLaunchpadIPSW(
                version: "26.4", build: "23E224", productTypes: [],
                deviceClasses: ["vresearch101ap", "vphone600ap"], fromManifest: true,
            )
            var scan = VPhoneLaunchpadIPSWCache.Scan(cacheDirectories: [cache])
            scan.ipsws = [
                file(creationOptions.iphoneSource, 9_835_120_455),
                file("\(base)/iPhone17,3_26.6.2_23G90_Restore.ipsw", 9_612_301_228),
                file("\(base)/iPhone17,3_26.4.2_23E261_Restore.ipsw", 9_401_877_310),
                file("\(base)/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw", 8_903_455_119),
                file(creationOptions.cloudOSSource, 14_220_648_901, facts: cloudOS),
            ]
            for machine in machines {
                scan.productTypes[machine.path.url.path] = "iPhone17,3"
            }
            return scan
        }()

        /// The row the Downloaded Firmware sheet opens with selected.
        static var ipswSelection: String?

        static let creationOptions = VPhoneLaunchpadCreationPipeline.Options(
            name: "ios27-rc",
            libraryRoot: VPhoneLaunchpadMachineLocations.defaultRoot,
            bundleVersion: releases[1].version,
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
        /// and out of the preset, as the real report does. For a machine it adds
        /// what a bundle reports about one: two boxes turned off since the guest
        /// was built, one in the guest and one in the boot chain, both pending.
        static func patchCatalog(preset: String?, machine: Bool = false) -> VPhoneLaunchpadPatchCatalog? {
            let active = preset ?? "standard"
            let frida = active == "experimental"
            let blocked = machine ? #"["kernel-cfw-debugger","dyld-cfw-camera"]"# : "[]"
            let records = machine ? #""installed":true,"receiptRecorded":true,"pendingPatches":2,"# : ""
            func pending(_ part: String, _ value: Bool = false) -> String {
                guard machine else { return "" }
                // delivery is reported only for a pending patch, by part.
                let deliveryKind = switch part {
                case "kernelcache": "update-kernel"
                case "Guest": "update-environment"
                case "AVPBooter": "fw-patch"
                default: "restore"
                }
                let delivery = value ? #","delivery":"\#(deliveryKind)""# : ""
                return #","part":"\#(part)","pending":\#(value)"# + delivery
            }
            let json = """
            {"activePreset":"\(active)","blockedPatches":\(blocked),"allowedPatches":[],\(records)
             "presets":[
               {"identifier":"standard","title":"Standard","summary":"The patches every vphone VM needs to boot custom firmware, with a working display and camera.","patchSets":[]},
               {"identifier":"experimental","title":"Experimental","summary":"Every patch this bundle declares, including the Frida Stalker relaxations.","patchSets":[]}
             ],
             "patches":[
               {"identifier":"avpbooter-boot-dgst_bypass","title":"AVPBooter digest bypass","summary":"Accepts the resealed boot images instead of the stock digests.","patchSet":"com.vphone.patchset.bootchain","patchSetName":"Boot Chain","target":"AVPBooter","applicability":"any","bootEssential":true,"inPreset":true,"enabled":true\(pending("AVPBooter"))},
               {"identifier":"ibss-cfw-serial_label","title":"iBSS serial label","summary":"Tags iBSS serial output so the boot log names its stage.","patchSet":"com.vphone.patchset.bootchain","patchSetName":"Boot Chain","target":"iBSS","applicability":"any","bootEssential":false,"inPreset":true,"enabled":true\(pending("iBSS"))},
               {"identifier":"kernel-cfw-debugger","title":"Kernel debugger gate","summary":"Lets a debugger attach to any process in the guest.","patchSet":"com.vphone.patchset.kernel.base","patchSetName":"Kernel Base","target":"kernelcache","applicability":"any","bootEssential":false,"inPreset":true,"enabled":true\(pending("kernelcache", true))},
               {"identifier":"kernel-boot-thread_guard_violation","title":"Thread guard violation","summary":"Stops the guard exception the older kernels raise on first boot.","patchSet":"com.vphone.patchset.kernel.base","patchSetName":"Kernel Base","target":"kernelcache","applicability":"iOS 18.x","bootEssential":true,"inPreset":true,"enabled":true\(pending("kernelcache"))},
               {"identifier":"kernel-exp-frida_thread_set_state_entitlement_flag","title":"Frida thread state entitlement","summary":"Lets Stalker set thread state without the entitlement the kernel asks for.","patchSet":"com.vphone.patchset.kernel.frida","patchSetName":"Frida Stalker","target":"kernelcache","applicability":"cloudOS 26.4+","bootEssential":false,"inPreset":\(frida),"enabled":\(frida)\(pending("kernelcache"))},
               {"identifier":"kernel-exp-frida_vm_map_delete_immutable_code","title":"Frida immutable code unmap","summary":"Allows Stalker to unmap the immutable code it rewrote.","patchSet":"com.vphone.patchset.kernel.frida","patchSetName":"Frida Stalker","target":"kernelcache","applicability":"cloudOS 26.4+","bootEssential":false,"inPreset":\(frida),"enabled":\(frida)\(pending("kernelcache"))},
               {"identifier":"system-vphoned-boot-install","title":"Guest vphoned","summary":"Installs vphoned and its launch daemon into the guest.","patchSet":"com.vphone.patchset.guest.system","patchSetName":"Guest System","target":"Guest filesystem","applicability":"any","bootEssential":true,"inPreset":true,"enabled":true\(pending("Guest"))},
               {"identifier":"dyld-cfw-camera","title":"Camera in the shared cache","summary":"Points the camera stack at the virtual camera.","patchSet":"com.vphone.patchset.guest.system","patchSetName":"Guest System","target":"dyld shared cache","applicability":"any","bootEssential":false,"inPreset":true,"enabled":true\(pending("Guest", true))}
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

        // MARK: Templates

        /// Stands in for `vm template list --json`: a current slimmed iPhone
        /// template two machines use, an unslimmed iPad one nothing uses, and
        /// one an older series built.
        static let templateList: VPhoneLaunchpadTemplateList? = {
            func template(
                _ id: String, device: String, ios: String, build: String, created: String, size: Int64,
                slimming: String, machines: String, stale: String = "[]", series: String = "2.9",
            ) -> String {
                """
                {"id":"\(id)","path":"\(VPhoneLaunchpadMachineLocations.defaultRoot)/.templates/\(id)","created":"\(created)",
                 "builtWithBundleVersion":"\(series).0","bootChainBundleVersion":"\(series).0","sourceMachine":"template-1a2b3c4d",
                 "allocatedBytes":\(size),"diskSizeBytes":64000000000,"machines":\(machines),"stale":\(stale != "[]"),"staleReasons":\(stale),
                 "sources":{"IPhone":"https://updates.cdn-apple.com/example/\(device)_\(ios)_\(build)_Restore.ipsw","CloudOS":"https://updates.cdn-apple.com/example/cloudos-26.4"},
                 "steps":{},
                 "key":{"Device":"\(device)","IOSVersion":"\(ios)","IOSBuild":"\(build)","CloudOSVersion":"26.4","CloudOSBuild":"23E5207q",
                        "PatchPreset":"standard","BootChainPlanDigest":"01e9","BundleSeries":"\(series)","DiskSizeGB":64,"FormatVersion":2,
                        "Slimming":\(slimming)}}
                """
            }
            let slim = #"{"TrimTier":"standard/1/en,zh,zh-Hans","SetupBoot":true,"ServiceProfile":"trimmed","ServiceGroups":[],"RemovedApps":["com.apple.AppStore","com.apple.Home","com.apple.tv","com.apple.news","com.apple.facetime","com.apple.MobileStore","com.apple.MobileSMS","com.apple.games","com.apple.findmy","com.apple.Passbook"]}"#
            let plain = #"{"TrimTier":"none","SetupBoot":true,"ServiceProfile":"none","ServiceGroups":[],"RemovedApps":[]}"#
            let accounts = #"{"TrimTier":"conservative/1","SetupBoot":true,"ServiceProfile":"trimmed","ServiceGroups":["accounts"],"RemovedApps":["com.apple.AppStore","com.apple.news"]}"#
            let json = """
            {"templates":[
              \(template("52b1fcc75e0c", device: "iPhone17,3", ios: "27.0", build: "24A435", created: "2026-10-08T10:00:00Z", size: 17_580_000_000,
                         slimming: slim, machines: #"["research-01","ios27-rc"]"#)),
              \(template("9d04a7c3e1b2", device: "iPad16,1", ios: "27.0.1", build: "24A446", created: "2026-10-07T16:20:00Z", size: 19_310_000_000,
                         slimming: plain, machines: "[]")),
              \(template("2246f982776c", device: "iPhone17,3", ios: "26.6.2", build: "23G90", created: "2026-10-02T09:00:00Z", size: 18_920_000_000,
                         slimming: accounts, machines: #"["frida-lab"]"#, stale: #"["built by bundle series 2.8; this vphone-cli is 2.9"]"#, series: "2.8"))
            ],
            "building":[{"name":".building-0e44975ff833-7A1C","path":"\(VPhoneLaunchpadMachineLocations.defaultRoot)/.templates/.building-0e44975ff833-7A1C","id":"0e44975ff833","active":false}],
            "damaged":[]}
            """
            return try? VPhoneLaunchpadTemplateList.decode(Data(json.utf8), libraryRoot: VPhoneLaunchpadMachineLocations.defaultRoot)
        }()

        static var templates: [VPhoneLaunchpadTemplate] {
            templateList?.templates ?? []
        }

        /// Whether the Guest System sheet sees its machine running.
        static var guestSystemRunning = false

        /// Whether a profile change waits for the guest to restart.
        static var guestSystemRestartPending = false

        /// Stands in for `services.profile`. After a switch to None the
        /// guest keeps no record, so it reports no restart either.
        static var serviceProfile: [String: Any] {
            if guestSystemRestartPending {
                return ["profile": "none", "supported": true, "running": [], "reboot_required": false]
            }
            return [
                "profile": "trimmed", "supported": true, "running": [], "reboot_required": false,
                "record": ["groups": ["base", "app_store", "signin_followup"], "allow": []],
            ]
        }

        /// Stands in for `apps.removed_system`: list C, Find My kept.
        static var removedSystemApps: [String: Any] {
            let apps = [
                ("com.apple.AppStore", "AppStore.app"), ("com.apple.Home", "Home.app"), ("com.apple.tv", "TVApp.app"),
                ("com.apple.news", "News.app"), ("com.apple.facetime", "FaceTime.app"), ("com.apple.MobileSMS", "MobileSMS.app"),
                ("com.apple.Passbook", "Passbook.app"),
            ]
            return ["backups": apps.map { ["bundle_id": $0.0, "app": $0.1, "restorable": true] }]
        }

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
