import ArgumentParser
import FirmwarePatcher
import Foundation
import MobileDevice
import Dynamic
import Virtualization


enum CLIError: Error {
    case CryptexError(String)
    case RestoreError(String)
}

struct VPhoneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone or patch firmware with the Swift pipeline",
        subcommands: [VPhoneBootCLI.self, VPhoneRestoreCLI.self, PatchFirmwareCLI.self, PatchComponentCLI.self, CryptexCLI.self],
        defaultSubcommand: VPhoneBootCLI.self
    )
}

struct VPhoneBootCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a virtual iPhone (PV=3)",
        discussion: """
        Creates a Virtualization.framework VM with platform version 3 (vphone)
        and boots it from a manifest plist that describes all paths and hardware.

        Requires:
          - macOS 15+ (Sequoia or later)
          - SIP/AMFI disabled
          - Signed with vphone entitlements (done automatically by wrapper script)

        Example:
          vphone-cli --config ./config.plist
        """
    )

    @Option(
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    var config: URL

    @Flag(help: "Boot into DFU mode")
    var dfu: Bool = false

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    var kernelDebugPort: Int?

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    var vphonedBin: String = ".vphoned.signed"
    
    @Option(help: "Firmware variant to execute.")
    var variant: PatchFirmwareCLI.VariantOption = .regular

    @Option(
        help: "Automatically install the given IPA/TIPA after the guest control channel connects. Unavailable with --dfu.",
        transform: URL.init(fileURLWithPath:)
    )
    var installIPA: URL?
    
    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned usage (patchless-only).")
    var noVphoned: Bool = false

    /// DFU mode runs headless (no GUI).
    var noGraphics: Bool {
        dfu
    }

    var installPackageURL: URL? {
        installIPA?.standardizedFileURL
    }

    mutating func validate() throws {
        if dfu, let packageURL = installPackageURL {
            throw ValidationError(
                "`--install-ipa` is unavailable with `--dfu` because DFU mode does not start the guest control channel: \(packageURL.path)"
            )
        }

        guard let packageURL = installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ValidationError("`--install-ipa` file does not exist: \(packageURL.path)")
        }

        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            throw ValidationError(
                "`--install-ipa` only supports .ipa or .tipa packages: \(packageURL.lastPathComponent)"
            )
        }
    }

    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        return VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpBooter, in: vmDir) : nil,
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpSEPBooter, in: vmDir) : nil,
            screenWidth: manifest.screenConfig.width,
            screenHeight: manifest.screenConfig.height,
            screenPPI: manifest.screenConfig.pixelsPerInch,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
            variant: variant.virtualMachineVariant,
            noVphoned: self.noVphoned
        )
    }

    mutating func run() throws {}
}

struct VPhoneRestoreCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a virtual iPhone",
    )

    @Option(
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    var config: URL
    
    @Option(
        help: "Apple firmware variant to restore (release/research).",
        transform: URL.init(fileURLWithPath:)
    )
    var ipsw: URL

    @Option(help: "Apple firmware variant to restore (customer/research).")
    var variant: FirmwareVariant = .customer
    
    enum FirmwareVariant: String, CaseIterable, ExpressibleByArgument {
        case customer
        case research
    }
    
    class RestoreContextWrapper {
        var context: RestoreContext
        init(context: RestoreContext) {
            self.context = context
        }
    }
    
    struct RestoreContext {
        let config: [String: Any]
        let completion: DispatchSemaphore
        var status: RestoreResult = .init()
    }
    
    struct RestoreResult {
        enum State: String {
            case notstarted, started, success, failed
        }

        var state: State = .notstarted
        var errReason: String? = nil

        mutating func setResult(state: State, errReason: String? = nil) {
            self.state = state
            self.errReason = errReason
        }
    }

    // ToDo Improve: Register Log Handler
    mutating func run() throws {
        var config = AMRestorableDeviceCopyDefaultRestoreOptions() as! [String: Any]

        config[kAMRestoreOptionsRestoreBootArgs] =
        if let bootArgs = config[kAMRestoreOptionsRestoreBootArgs] as? String {
            bootArgs + " serial=3"
        } else {
            "rd=md0 nand-enable-reformat=1 -progress -restore serial=3"
        }
        
        config[kAMRestoreOptionsPostRestoreAction] = kAMRestorePostRestoreShutdown
        config[kAMRestorableRestoreOptionWaitForDeviceConnectionToFinishStateMachine] = false
        config[kAMRestoreOptionsPersistentBootArgModifications] = [
            [kAMRestoreBootArgsAdd, "debug", "0x104c04"],
            [kAMRestoreBootArgsAdd, "serial", "3"],
        ]

        config[kAMRestoreOptionsRestoreBundlePath] = ipsw.path
        let variantName = try! restoreVariantName(variant)
        config[kAMRestoreOptionsAuthInstallVariant] = variantName

        var restoreContext = RestoreContext(
            config: config,
            completion: DispatchSemaphore(value: 0)
        )

        print("[vphone] restore: \(ipsw) (variant: \"\(variant.rawValue)\")")

        let contextWrapper = RestoreContextWrapper(context: restoreContext)
        let contextWrapperRaw = Unmanaged<RestoreContextWrapper>.passRetained(contextWrapper)
        defer {
            contextWrapperRaw.release()
        }

        var resErr: Unmanaged<CFError>?
        let clientID = AMRestorableDeviceRegisterForNotifications(
            newConnectionCallback,
            contextWrapperRaw.toOpaque(),
            &resErr
        )
        defer {
            if clientID != kAMRestorableInvalidClientID {
                AMRestorableDeviceUnregisterForNotifications(clientID)
            }
        }

        if let resErr = resErr?.takeUnretainedValue() {
            let errReason = CFErrorCopyDescription(resErr) as? String ?? "No Reason"
            contextWrapper.context.status.setResult(state: .failed,
                                                    errReason: "initialization: \(errReason)")
            throw CLIError.RestoreError("restore init: \(errReason)")
        }
        defer { restoreContext = contextWrapper.context }

        // 5 minutes restore timeout
        let deadline = DispatchTime.now() + 300
        guard contextWrapper.context.completion.wait(timeout: deadline) == .success else {
            contextWrapper.context.status.setResult(state: .failed, errReason: "timeout")
            throw CLIError.RestoreError("timeout")
        }

        guard contextWrapper.context.status.state == .success else {
            throw CLIError.RestoreError("failed: \(restoreContext.status.errReason ?? "No reason")")
        }
    }
}

func restoreVariantName(_ variant: VPhoneRestoreCLI.FirmwareVariant) throws -> String {
    return switch variant {
    case VPhoneRestoreCLI.FirmwareVariant.customer: "Darwin Cloud Customer Erase Install (IPSW)"
    case VPhoneRestoreCLI.FirmwareVariant.research: "Research Darwin Cloud Customer Erase Install (IPSW)"
    }
}

func newConnectionCallback(
    _ deviceRef: AMRestorableDeviceRef?,
    _ event: AMRestorableDeviceEvent,
    _ context: UnsafeMutableRawPointer?
) {
    let deviceRef = deviceRef!
    let contextRef = Unmanaged<VPhoneRestoreCLI.RestoreContextWrapper>
        .fromOpaque(context!)
        .takeUnretainedValue()

    guard contextRef.context.status.state == .notstarted else {
        return
    }

    print("restore: device connected")
    let deviceState = getAMRDeviceState(deviceRef)
    if deviceState == kAMRestorableDeviceStateBootedOS {
        if AMDeviceEnterRecovery(deviceRef) != 0 {
            print("Failed to enter recovery mode")
            return
        }
    }

    guard [kAMRestorableDeviceStateDFU, kAMRestorableDeviceStateDFUMac].contains(deviceState) else {
        print("Not in DFU mode")
        let devState = getAMRDeviceState(deviceRef)
        contextRef.context.status.setResult(state: .failed,
                                            errReason: "VM not in DFU mode (curstate = \(devState))")
        return
    }
    
    let restoreConfig = contextRef.context.config as CFDictionary
    contextRef.context.status.state = .started

    AMRestorableDeviceRestore(
        deviceRef,
        restoreConfig,
        restoreProgressCallback,
        context
    )

    if event == kAMRestorableDeviceEventDisappeared {
        print("Disappeared")
        contextRef.context.status.setResult(state: .failed,
                                            errReason: "disconnected from VM")
    }
}

private func restoreProgressCallback(
    _ deviceRef: AMRestorableDeviceRef?,
    _ restoreInfo: CFDictionary?,
    _ context: UnsafeMutableRawPointer? // &RestoreContext
) {
    let restoreInfo = restoreInfo! as! [String: Any]
    let contextRef = Unmanaged<VPhoneRestoreCLI.RestoreContextWrapper>
        .fromOpaque(context!)
        .takeUnretainedValue()

    if let progress = restoreInfo[kAMRestorableDeviceInfoKeyOverallProgress as String] {
        if (progress as! Int32) >= 0 {
            let printStr = String(format: "%3d", progress as! Int32)
            print("[Restore] Progress: \(printStr)%", terminator: "\r")
            fflush(stdout)
        } else {
            print("[Restore] Waiting...", terminator: "\r")
            fflush(stdout)
        }
    }

    let status = restoreInfo[kAMRestorableDeviceInfoKeyStatus as String]
    guard let status = status as? String else {
        return
    }

    if status == (kAMRestorableDeviceStatusRestoring as String) {
        return
    }

    if status == (kAMRestorableDeviceStatusSuccessful) {
        contextRef.context.status.setResult(state: .success)
        print("[Restore] Completed")
    } else {
        var errReason = "no reason provided"
        if let error = restoreInfo[kAMRestorableDeviceInfoKeyError] {
            errReason = (error as! CFError).localizedDescription
        }

        contextRef.context.status.setResult(state: .failed, errReason: errReason)
    }

    contextRef.context.completion.signal()
}

private func getAMRDeviceState(_ deviceRef: AMRestorableDeviceRef) -> AMRestorableDeviceState {
    return AMRestorableDeviceGetStateWithVersion(deviceRef,
                                                 OpaquePointer(getAMRestorableDeviceStateVersion2()))
}

struct PatchFirmwareCLI: ParsableCommand {
    enum VariantOption: String, CaseIterable, ExpressibleByArgument {
        case less
        case regular
        case dev
        case jb
        case exp

        var pipelineVariant: FirmwarePipeline.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            case .exp: .exp
            }
        }

        var virtualMachineVariant: VPhoneVirtualMachine.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            case .exp: .exp
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-firmware",
        abstract: "Patch boot-chain firmware in a VM directory using the Swift pipeline"
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the VM directory that contains the *Restore* folder.",
        transform: URL.init(fileURLWithPath:)
    )
    var vmDirectory: URL

    @Option(help: "Firmware variant to patch.")
    var variant: VariantOption = .regular

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON."
    )
    var recordsOut: String?

    @Flag(name: .customLong("quiet"), help: "Suppress per-component progress output.")
    var quiet: Bool = false
    
    @Flag(name: .customLong("no-binpack"), help: "Exclude the SSH, VNC, ... binaries from being installed (patchless-only).")
    var noBinpack: Bool = false

    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned from being installed (patchless-only).")
    var noVphoned: Bool = false

    mutating func run() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: vmDirectory,
            variant: variant.pipelineVariant,
            verbose: !quiet,
            noBinpack: noBinpack,
            noVphoned: noVphoned
        )
        let records = try pipeline.patchAll()

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            print("[patch-firmware] wrote \(records.count) patch records to \(url.path)")
        } else {
            print("[patch-firmware] applied \(records.count) patches for \(variant.rawValue)")
        }
    }
}

struct PatchComponentCLI: ParsableCommand {
    enum ComponentOption: String, CaseIterable, ExpressibleByArgument {
        case txm
        case kernelBase = "kernel-base"
        // TESTING/DIAGNOSTICS ONLY — not part of any production flow.
        // Production JB patching runs through `patch-firmware --variant jb`; this
        // standalone option exists so `tests/test_jb_kernel_patches.sh` can run the
        // JB kernel layer over a single kernelcache and dump records via --records-out.
        // (txm / kernel-base, by contrast, are also used by scripts/ramdisk_build.py.)
        case kernelJB = "kernel-jb"
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-component",
        abstract: "Patch a single firmware component payload and write the patched raw bytes"
    )

    @Option(help: "Component to patch.")
    var component: ComponentOption

    @Option(
        name: .customLong("input"),
        help: "Path to the source firmware file (IM4P or raw).",
        transform: URL.init(fileURLWithPath:)
    )
    var input: URL

    @Option(
        name: .customLong("output"),
        help: "Path to write the patched raw payload bytes.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL

    @Flag(name: .customLong("quiet"), help: "Suppress per-patch progress output.")
    var quiet: Bool = false

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON (for fast-loop validation)."
    )
    var recordsOut: String?

    mutating func run() throws {
        let payload = try IM4PHandler.load(contentsOf: input).payload
        let count: Int
        let patchedData: Data
        var records: [PatchRecord] = []

        switch component {
        case .txm:
            let patcher = TXMPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.patchedData

        case .kernelBase:
            let patcher = KernelPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.buffer.data
            records = patcher.patches

        case .kernelJB:
            // Mirrors the pipeline's jb kernel layer. In FirmwarePipeline each kernel
            // patcher runs on the *original* payload independently, so running
            // KernelJBPatcher standalone faithfully reproduces JB hook behavior
            // without the base patcher or the rest of the boot chain.
            let patcher = KernelJBPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.buffer.data
            records = patcher.patches
        }

        let outputDir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try patchedData.write(to: output)

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            if !quiet {
                print("[patch-component] wrote \(records.count) patch records to \(url.path)")
            }
        }

        if !quiet {
            print("[patch-component] applied \(count) patches for \(component.rawValue)")
            print("[patch-component] wrote patched payload to \(output.path)")
        }
    }
}

struct CryptexCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cryptex",
        abstract: "Configure the use of Cryptexes for your virtual iPhone",
        subcommands: [CryptexCreateCLI.self]
    )
}

struct CryptexCreateCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a cryptex to your virtual iPhone"
    )
    
    @Option(name: [.customLong("source"), .customShort("s")],
            help: "The source for compiling the Cryptex. Required.")
    var path: String
    
    @Option(name: [.customLong("variant"), .customShort("v")],
            help: "The variant of the referenced Cryptex (research, release, ...). Required.")
    var variant: String

    mutating func run() throws {
        print("Creating cryptex")
        let path = try Cryptex.createCryptex(source: path, name: variant)
        print("Created cryptex at \(path)")
    }
}
