// VPhonePatchSetCommand.swift — `vphone-cli patchset`.
//
// The verbs for out-of-tree patch sets: look at one, import one, list what is
// imported, remove one. A preset then names an imported set by identifier and path
// and `fw patch` loads it.
//
// `import` is deliberately its own step rather than something `fw patch` does on
// the fly. Loading a set runs its code in the patching process, so the moment a
// bundle becomes loadable should be a thing the user did, with a path they typed,
// and it should be the moment the bundle gets its ad hoc signature.

import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCommandKit
import VPhoneCoreKit
import VPhonePatchKit

struct VPhonePatchSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patchset",
        abstract: "Inspect and import .vphonepatchset bundles",
        discussion: """
        A patch set is a loadable bundle carrying Contents/Resources/Manifest.plist
        and one exported symbol, vphone_patch_set_principal, returning a
        VPhonePatchSetPrincipal. The sets compiled into this bundle need none of
        this; these verbs are for a set built outside it.

        An imported set is reached by a preset that names it:

            <dict>
              <key>Kind</key>    <string>External</string>
              <key>Identifier</key> <string>com.example.patchset.mine</string>
              <key>Path</key>    <string>~/.vphone/patchsets/com.example.patchset.mine.vphonepatchset</string>
            </dict>

        Shipped presets never do this, so such a preset goes in
        ~/.vphone/patches_presets/ and is selected with --preset.

        A loaded set can patch the boot chain only. The guest half of an install
        runs as root and loads no external set, so a guest-side declaration would
        promise a patch that never runs and is refused at import.
        """,
        subcommands: [
            VPhonePatchSetListCommand.self,
            VPhonePatchSetInfoCommand.self,
            VPhonePatchSetImportCommand.self,
            VPhonePatchSetRemoveCommand.self,
        ],
        defaultSubcommand: VPhonePatchSetListCommand.self,
    )
}

// MARK: - list

struct VPhonePatchSetListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the patch sets this bundle has and the ones that were imported",
    )

    func run() throws {
        print("Bundled (\(FirmwarePatchSetCatalog.bundled.count)):")
        for manifest in FirmwarePatchSetCatalog.bundled {
            print("  \(manifest.identifier)  \(manifest.version)"
                + "  \(manifest.patches.count) patches  \(manifest.name)")
        }

        let store = try VPhonePatchSetStore.contents()
        let records = VPhonePatchSetStore.imported()
        print("\nImported (\(store.count))  \(VPhonePatchSetStore.directory().path):")
        guard !store.isEmpty else {
            print("  none — `vphone-cli patchset import <path>` adds one")
            return
        }
        for set in store {
            let identifier = set.manifest.identifier
            print("  \(identifier)  \(set.manifest.version)"
                + "  \(set.manifest.patches.count) patches  \(set.manifest.name)")
            print("    \(Self.state(of: set, record: records[identifier]))")
        }
    }

    /// One line on whether the set on disk is still what was imported, and whether
    /// it would load right now.
    private static func state(
        of set: VPhonePatchSetBundle,
        record: VPhoneImportedPatchSet?,
    ) -> String {
        do {
            try set.requireValidSignature()
        } catch {
            return "signature: INVALID — \(error)"
        }
        guard let record else {
            return "signature: valid; no import record, so nothing to compare against"
        }
        let current = (try? set.codeDirectoryHash()) ?? ""
        guard current == record.codeDirectoryHash else {
            return "signature: valid, but re-signed since import"
                + " (was \(record.codeDirectoryHash.prefix(16))…, now \(current.prefix(16))…)"
        }
        return "signature: valid, unchanged since import"
    }
}

// MARK: - info

struct VPhonePatchSetInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print what a patch set declares",
    )

    @Argument(help: "A .vphonepatchset path, or the identifier of a bundled or imported set")
    var target: String

    func run() throws {
        let manifest = try Self.manifest(for: target)
        print("Identifier:  \(manifest.identifier)")
        print("Name:        \(manifest.name)")
        print("Version:     \(manifest.version)")
        if !manifest.summary.isEmpty {
            print("Summary:     \(manifest.summary)")
        }
        print("Needs:       PatchKit \(manifest.minimumPatchKitVersion)"
            + " (this is \(VPhoneVersion.currentPatchKit))")
        if !manifest.provides.isEmpty {
            print("Provides:    \(manifest.provides.joined(separator: ", "))")
        }
        if !manifest.requires.isEmpty {
            print("Requires:    \(manifest.requires.joined(separator: ", "))")
        }
        if !manifest.conflictsWith.isEmpty {
            print("Conflicts:   \(manifest.conflictsWith.joined(separator: ", "))")
        }
        if !manifest.after.isEmpty {
            print("After:       \(manifest.after.joined(separator: ", "))")
        }
        print("\nPatches (\(manifest.patches.count)):")
        for patch in manifest.patches {
            let essential = patch.bootEssential ? "  [boot-essential]" : ""
            print("  \(patch.identifier)\(essential)")
            print("    \(patch.title) — \(patch.target)")
            print("    applies to: \(patch.applicability)")
        }
    }

    /// A path if it is one, otherwise an identifier looked up in the store and then
    /// among the bundled sets.
    static func manifest(for target: String) throws -> VPhonePatchSetManifest {
        let expanded = (target as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return try VPhonePatchSetBundle.inspect(at: URL(fileURLWithPath: expanded)).manifest
        }
        let stored = VPhonePatchSetStore.url(forIdentifier: target)
        if FileManager.default.fileExists(atPath: stored.path) {
            return try VPhonePatchSetBundle.inspect(at: stored).manifest
        }
        guard let bundled = FirmwarePatchSetCatalog.manifest(identifier: target) else {
            throw ValidationError(
                "No patch set at \(target), and no bundled or imported set with that identifier."
                    + " Run `vphone-cli patchset list`.",
            )
        }
        return bundled
    }
}

// MARK: - import

struct VPhonePatchSetImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Copy a .vphonepatchset into the store, ad hoc signing it if it is unsigned",
        discussion: """
        Checks the manifest first — including that every patch targets the boot
        chain — then copies the bundle to ~/.vphone/patchsets under the identifier
        it declares, ad hoc signs the copy if it arrived unsigned or invalid, and
        verifies that the result passes the same check `fw patch` will make.

        The set's own code never runs here.
        """,
    )

    @Argument(help: "Path to the .vphonepatchset to import")
    var path: String

    @Flag(name: .customLong("replace"), help: "Overwrite a set already imported under this identifier")
    var replace = false

    func run() throws {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let installed = try VPhonePatchSetStore.importSet(from: source, replacing: replace)
        print("[patchset import] \(installed.manifest.identifier) \(installed.manifest.version)"
            + " — \(installed.manifest.patches.count) patches")
        print("  \(installed.url.path)")
        try print("  cdhash \(installed.codeDirectoryHash())")
        // The real directory, not `~/.vphone`: a run with VPHONE_ROOT set reads its
        // presets from there, and a hint naming the wrong path is worse than none.
        print("\nName it from a preset in \(VPhonePatchPresetStore.userPresetsDirectory().path)/ as:")
        print("  Kind External, Identifier \(installed.manifest.identifier), Path \(installed.url.path)")
    }
}

// MARK: - remove

struct VPhonePatchSetRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete an imported patch set",
    )

    @Argument(help: "Identifier of the imported set")
    var identifier: String

    func run() throws {
        try VPhonePatchSetStore.remove(identifier: identifier)
        print("[patchset remove] \(identifier)")
    }
}
