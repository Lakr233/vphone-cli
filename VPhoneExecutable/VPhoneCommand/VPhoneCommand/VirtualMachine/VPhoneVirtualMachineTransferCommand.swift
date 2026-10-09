import ArgumentParser
import Foundation
import VPhoneArchiveKit
import VPhoneCoreKit

struct VPhoneVirtualMachineCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Copy a VM bundle (using APFS copy-on-write when available)",
        discussion: """
        The source VM must be stopped. Its snapshots are not copied.

        By default the copy keeps the machine identifier (ECID), MAC address, NVRAM, SEP \
        storage and every setting, so it cannot run beside its source: use it as a backup.

        --new-identity clears the machine identifier and MAC address, so the copy gets new \
        ones, and with them a new UDID, on its first start. It also clears the fixed IPv4 \
        address, port forwards and a hand-chosen mDNS name, which would collide with the \
        source's; a derived mDNS name follows the new name. NVRAM, \
        SEP storage and the disk image are kept: they were made together by one restore, and \
        the guest panics if SEP storage is replaced. No restore or re-personalization is \
        needed. The host must be trusted again in the guest before lockdown tools work.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "source VM name") var name: String?
    @Argument(help: "new VM name") var newName: String?
    @Flag(help: "give the copy a new machine identifier and MAC address on its first start")
    var newIdentity = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let newName = try VPhoneVirtualMachineSelection.resolveNewName(newName, prompt: "New VM name:")
        let source = try lib.library.bundle(named: name)
        let clone = try VPhoneBundleOperations.clone(
            bundleNamed: name,
            to: newName,
            in: lib.library,
            newIdentity: newIdentity,
        )
        print("cloned \(name) → \(clone.name)")
        guard newIdentity else { return }
        print("new identity: machine identifier and MAC address are generated on first start")
        for setting in VPhoneBundleOperations.networkSettingsClearedByNewIdentity(source.manifest.networkConfig, sourceName: source.name) {
            print("cleared \(setting)")
        }
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
        // SIGINT (Ctrl-C, or vphone-launchpad stopping the import) and SIGTERM
        // stop the extraction between blocks, so the staging folder is removed
        // rather than left in the library at the size it had reached.
        let stop = VPhoneImportInterruption()
        let bundle = try VPhoneBundleTransfer.importArchive(
            from: URL(fileURLWithPath: input),
            name: name,
            in: lib.library,
            progress: { done, total in bar.update(done: done, total: total) },
            isCancelled: { stop.isRequested },
        )
        try VPhoneHostFilePermissions.makeAccessible(at: bundle.url)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: lib.library.root)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: VPhoneResources.userDataRoot())
        bar.finish()
        print("imported → \(bundle.name)")
    }
}

// MARK: - Interruption

/// Turns SIGINT and SIGTERM into a flag the import polls. The signals are
/// ignored for the rest of the process: once the extraction has returned, the
/// remaining steps are a rename and permission changes, quicker to finish
/// than to undo.
private final class VPhoneImportInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                lock.withLock { requested = true }
            }
            source.resume()
            sources.append(source)
        }
    }

    var isRequested: Bool {
        lock.withLock { requested }
    }
}
