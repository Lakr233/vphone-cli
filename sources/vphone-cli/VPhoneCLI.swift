import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone or patch firmware with the Swift pipeline",
        subcommands: [
            VPhoneBootCLI.self, PatchFirmwareCLI.self, PatchComponentCLI.self, VPhoneVMCommand.self,
            VPhoneFWCommand.self, VPhoneRestoreCommand.self, VPhoneRecoveryProbeCommand.self,
            VPhoneCFWCommand.self,
            VPhoneSignCommand.self, VPhoneDumpEntitlementsCommand.self,
        ],
        defaultSubcommand: VPhoneBootCLI.self
    )
}

// VPhoneBootCLI now lives in VPhoneCore, shared with vphone-vm. This binary
// only forwards it — see main.swift.

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

    @Option(name: [.customShort("V"), .long], help: "Firmware variant to patch.")
    var variant: VariantOption = .regular

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON."
    )
    var recordsOut: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-component progress output.")
    var quiet: Bool = false
    
    @Flag(
        name: .customLong("no-binpack"),
        help: "Exclude the SSH, VNC, ... binaries from being installed (patchless-only)."
    )
    var noBinpack: Bool = false

    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned from being installed (patchless-only).")
    var noVphoned: Bool = false

    @Flag(
        name: .customLong("force-exc-guard"),
        help: "Force-enable the EXC_GUARD (Mach port guard) disable patch on regular/jb/exp, even on bases where it isn't required to boot. Use if a third-party app's crash-reporting/RASP SDK trips a fatal GUARD_TYPE_MACH_PORT violation on launch. Always on for iOS 18 bases regardless of this flag."
    )
    var forceExcGuard: Bool = false

    @Flag(
        name: .customLong("frida"),
        help: "Opt in to Frida Stalker kernel relaxations (existing-thread follow + repeated VM_PROT_COPY). jb/exp only."
    )
    var frida: Bool = false

    mutating func run() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: vmDirectory,
            variant: variant.pipelineVariant,
            verbose: !quiet,
            noBinpack: noBinpack,
            noVphoned: noVphoned,
            forceExcGuard: forceExcGuard,
            enableFrida: frida
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
        // (txm / kernel-base, by contrast, are standalone single-component patchers.)
        case kernelJB = "kernel-jb"
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-component",
        abstract: "Patch a single firmware component payload and write the patched raw bytes"
    )

    @Option(help: "Component to patch.")
    var component: ComponentOption

    @Option(
        name: [.customShort("i"), .customLong("input")],
        help: "Path to the source firmware file (IM4P or raw).",
        transform: URL.init(fileURLWithPath:)
    )
    var input: URL

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Path to write the patched raw payload bytes.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-patch progress output.")
    var quiet: Bool = false

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON (for fast-loop validation)."
    )
    var recordsOut: String?

    @Option(
        name: .customLong("target-os"),
        help: "kernel-jb only: base iOS version the kernel will run under (e.g. 27.0). Gates the iOS-27-only JB patches exactly as the pipeline does. Omit to apply the full set (dev/test default)."
    )
    var targetOS: String?

    @Flag(
        name: .customLong("frida"),
        help: "kernel-jb only: opt in to the Frida Stalker kernel relaxations."
    )
    var frida: Bool = false

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
            // Mirror the pipeline's per-base gating: apply the iOS-27-only patches when
            // --target-os is 27.x, skip them for an explicit non-27 target. With no
            // --target-os, default to applying them so the dev/test tool exercises the
            // full set.
            patcher.applyIOS27 = targetOS.map { $0.hasPrefix("27.") } ?? true
            patcher.applyFrida = frida
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
