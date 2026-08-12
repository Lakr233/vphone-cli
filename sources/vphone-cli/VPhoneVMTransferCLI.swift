import ArgumentParser
import Foundation
import VPhoneCore

struct VPhoneVMCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a VM bundle (fast APFS clone; resets device identity)",
        discussion: "The clone boots as a fresh device (nvram/machineIdentifier/shsh cleared). "
            + "SEPStorage is copied as-is; a cloned, already-restored VM may need re-restoring.")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "source VM name") var name: String?
    @Argument(help: "new VM name") var newName: String?

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let newName = try VPhoneVMSelection.resolveNewName(newName, prompt: "New VM name:")
        let clone = try VPhoneBundleOps.clone(bundleNamed: name, to: newName, in: lib.library)
        print("cloned \(name) → \(clone.name)")
    }
}

struct VPhoneVMExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export a VM bundle to a .tgz archive")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "output archive path") var out: String
    @Flag(help: "densest compression (xz -9) instead of the default fast (zstd -3)") var max = false
    @Flag(help: "include the *_Restore* IPSW directory") var includeIpsw = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let compression: VPhoneBundleOps.ExportCompression = max ? .max : .fast
        let bar = VPhoneProgressBar(label: "exporting \(name)")
        let outURL = try VPhoneBundleOps.export(
            bundleNamed: name, to: URL(fileURLWithPath: out), includeIPSW: includeIpsw,
            compression: compression, in: lib.library,
            progress: { done, total in bar.update(done: done, total: total) })
        bar.finish()
        print("exported \(name) → \(outURL.path)")
    }
}

struct VPhoneVMImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Import a VM bundle from a .tgz archive")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "input archive path") var input: String
    @Option(name: .shortAndLong, help: "name for the imported VM (default: the archive's own name)") var name: String?

    func run() throws {
        let bar = VPhoneProgressBar(label: "importing")
        let bundle = try VPhoneBundleOps.importArchive(
            from: URL(fileURLWithPath: input), name: name, in: lib.library,
            progress: { done, total in bar.update(done: done, total: total) })
        bar.finish()
        print("imported → \(bundle.name)")
    }
}
