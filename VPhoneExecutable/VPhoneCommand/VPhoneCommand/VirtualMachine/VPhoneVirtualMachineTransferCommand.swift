import ArgumentParser
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit

struct VPhoneVirtualMachineCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Copy a VM bundle (using APFS copy-on-write when available)",
        discussion: "The copy keeps the machine identifier, NVRAM, SEP storage, and SHSH blobs unchanged. Edit the device identity yourself if you need a different one.",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "source VM name") var name: String?
    @Argument(help: "new VM name") var newName: String?

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let newName = try VPhoneVirtualMachineSelection.resolveNewName(newName, prompt: "New VM name:")
        let clone = try VPhoneBundleOperations.clone(bundleNamed: name, to: newName, in: lib.library)
        print("cloned \(name) → \(clone.name)")
    }
}

struct VPhoneVirtualMachineExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a VM bundle to a compressed archive (.tzst, or .txz with --max)",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "output archive path") var out: String
    @Flag(help: "densest compression (xz -9) instead of the default fast (zstd -3)") var max = false
    @Flag(help: "include the *_Restore* IPSW directory") var includeIpsw = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let compression: VPhoneBundleTransfer.ExportCompression = max ? .max : .fast
        let bar = VPhoneProgressBar(label: "exporting \(name)")
        let outURL = try VPhoneBundleTransfer.export(
            bundleNamed: name,
            to: URL(fileURLWithPath: out),
            includeIPSW: includeIpsw,
            compression: compression,
            in: lib.library,
            progress: { done, total in bar.update(done: done, total: total) },
        )
        try VPhoneHostFilePermissions.makeAccessible(at: outURL)
        bar.finish()
        print("exported \(name) → \(outURL.path)")
    }
}

struct VPhoneVirtualMachineImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a VM bundle from a compressed archive (compressor auto-detected)",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "input archive path") var input: String
    @Option(name: .shortAndLong, help: "name for the imported VM (default: the archive's own name)") var name: String?

    func run() throws {
        let bar = VPhoneProgressBar(label: "importing")
        let bundle = try VPhoneBundleTransfer.importArchive(
            from: URL(fileURLWithPath: input),
            name: name,
            in: lib.library,
            progress: { done, total in bar.update(done: done, total: total) },
        )
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: lib.library.root)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: VPhoneResources.userDataRoot())
        bar.finish()
        print("imported → \(bundle.name)")
    }
}
