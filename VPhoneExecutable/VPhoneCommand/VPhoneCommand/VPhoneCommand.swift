import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

struct VPhoneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone or patch firmware with the Swift pipeline",
        subcommands: [
            VPhoneBootCommand.self, PatchFirmwareCommand.self, PatchComponentCommand.self, VPhoneVirtualMachineCommand.self,
            VPhoneFirmwareCommand.self, VPhoneRestoreCommand.self, VPhoneRecoveryProbeCommand.self,
            VPhoneCustomFirmwareCommand.self, VPhonePatchSetCommand.self,
            VPhoneHostCommand.self,
            VPhoneSignCommand.self, VPhoneDumpEntitlementsCommand.self,
            VPhoneArchiveCommand.self,
        ],
        defaultSubcommand: VPhoneBootCommand.self,
    )
}

// VPhoneBootCommand now lives in VPhoneCoreKit, shared with vphone-vm. This binary
// only forwards it — see main.swift.

struct PatchFirmwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-firmware",
        abstract: "Patch boot-chain firmware in a VM directory using the Swift pipeline",
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the VM directory that contains the *Restore* folder.",
        transform: URL.init(fileURLWithPath:),
    )
    var vmDirectory: URL

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON.",
    )
    var recordsOut: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-component progress output.")
    var quiet: Bool = false

    @Option(
        name: .customLong("preset"),
        help: "Patch preset name, or path to a preset plist, to apply. Defaults to standard. Individual patches are selected per VM by `fw patch`, not here.",
    )
    var preset: String = VPhonePatchPreset.standardIdentifier

    mutating func run() throws {
        let file = try VPhonePatchPresetStore.isPresetFile(preset) ? VPhonePatchPresetStore.readPresetFile(preset) : nil
        guard let resolved = file ?? FirmwarePatchSetCatalog.builtInPresets.first(where: { $0.identifier == preset })
        else {
            let available = FirmwarePatchSetCatalog.builtInPresets.map(\.identifier)
            throw ValidationError(
                "Unknown patch preset '\(preset)'. Available: \(available.joined(separator: ", "))",
            )
        }
        let pipeline = FirmwarePipeline(
            vmDirectory: vmDirectory,
            variant: .jb,
            verbose: !quiet,
            noBinpack: true,
            preset: resolved,
        )
        let records = try pipeline.patchAll()

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            print("[patch-firmware] wrote \(records.count) patch records to \(url.path)")
        } else {
            print("[patch-firmware] applied \(records.count) CFW patches")
        }
    }
}

struct PatchComponentCommand: ParsableCommand {
    enum ComponentOption: String, CaseIterable, ExpressibleByArgument {
        case txm
        case kernelBase = "kernel-base"
        /// TESTING/DIAGNOSTICS ONLY — not part of any production flow.
        /// Production CFW patching runs through `patch-firmware`; this
        /// standalone option runs the CFW kernel layer over a single kernelcache
        /// and dumps records via --records-out.
        /// (txm / kernel-base, by contrast, are standalone single-component patchers.)
        case kernelCFW = "kernel-cfw"
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-component",
        abstract: "Patch a single firmware component payload and write the patched raw bytes",
    )

    @Option(help: "Component to patch.")
    var component: ComponentOption

    @Option(
        name: [.customShort("i"), .customLong("input")],
        help: "Path to the source firmware file (IM4P or raw).",
        transform: URL.init(fileURLWithPath:),
    )
    var input: URL

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Path to write the patched raw payload bytes.",
        transform: URL.init(fileURLWithPath:),
    )
    var output: URL

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-patch progress output.")
    var quiet: Bool = false

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON (for fast-loop validation).",
    )
    var recordsOut: String?

    @Option(
        name: .customLong("target-os"),
        help: "kernel-cfw only: base iOS version the kernel will run under (e.g. 27.0). Gates the iOS-27-only CFW patches exactly as the pipeline does. Omit to apply the full set (dev/test default).",
    )
    var targetOS: String?

    @Flag(
        name: .customLong("frida"),
        help: "kernel-jb only: opt in to the Frida Stalker kernel relaxations.",
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

        case .kernelCFW:
            // Mirrors the pipeline's cfw kernel layer. In FirmwarePipeline each kernel
            // patcher runs on the *original* payload independently, so running
            // KernelCustomFirmwarePatcher standalone faithfully reproduces CFW hook
            // behavior without the base patcher or the rest of the boot chain.
            let patcher = KernelCustomFirmwarePatcher(data: payload, verbose: !quiet)
            // Mirror the pipeline's per-base gating: apply the iOS-27-only patches when
            // --target-os is 27.x, skip them for an explicit non-27 target. With no
            // --target-os, default to applying them so the dev/test tool exercises the
            // full set.
            patcher.applyIOS27 = targetOS.map { $0.hasPrefix("27.") } ?? true
            // The dev tool takes one payload and is told nothing about the cloudOS, so
            // it keeps exercising the 26.4-kernel shims: that is the pairing they were
            // revealed against, and the reference corpus is a 26.4 kernel.
            patcher.applyIOS27LegacyKernel = patcher.applyIOS27
            patcher.applyFrida = frida
            // The narrow paravirt user-client allowlist is the 26.x/18.x counterpart
            // of the iOS-27 sandbox gate; exercise it when the 27 gate is off.
            patcher.applyParavirtUserClients = !patcher.applyIOS27
            count = try patcher.apply()
            patchedData = patcher.buffer.data
            records = patcher.patches
        }

        let outputDir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try patchedData.write(to: output)
        try VPhoneHostFilePermissions.makeAccessible(at: output)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: outputDir)

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            try VPhoneHostFilePermissions.makeAccessible(at: url)
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
