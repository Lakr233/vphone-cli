import ArgumentParser
import Darwin
import Foundation
import VPhoneCoreKit

/// Offline trim of a stopped machine's guest System volume: attach its
/// `Disk.img` without mounting (`diskutil image attach -noMount`), find the
/// System-role volume, mount it read-write inside a private folder, delete
/// the trim's entries (``VPhoneSystemTrimSpec/apply(to:log:)``), unmount and
/// eject, then record the trim in the machine's `Template.plist` steps.
///
/// Root is not needed: an image attached by a user mounts for that user
/// with `noowners`. A template build under sudo runs it as root all the
/// same. Either way the volume is mounted `nosuid,nodev,nobrowse` in a 0700
/// folder made by `mkdtemp`, and every deletion is descriptor relative and
/// refuses links, so nothing on the guest volume can point it at a host path.
///
/// What it deletes stays allocated until the guest deletes its `orig-fs`
/// snapshot during the setup boot; a template is frozen only after that.
public enum VPhoneMachineTemplateTrimmer {
    /// Trims the machine at `bundle` and records the trim.
    ///
    /// - Parameters:
    ///   - label: The name messages use: the machine's, or the staging folder's.
    ///   - newRecord: The unfrozen `Template.plist` to write when the machine
    ///     has none (a library machine Launchpad is building into a template).
    @discardableResult
    public static func trim(
        _ bundle: VPhoneBundle,
        label: String,
        spec: VPhoneSystemTrimSpec,
        newRecord: VPhoneMachineTemplateRecord?,
        log: (String) -> Void = { print($0) },
    ) throws -> VPhoneSystemTrimResult {
        try requireTrimmable(bundle, label: label, spec: spec)
        if spec.tier == .none {
            log("[*] Trim none: nothing to delete")
            try record(spec, in: bundle, newRecord: newRecord)
            return VPhoneSystemTrimResult(trim: spec.keyValue, entries: [])
        }
        let disk = try diskImage(of: bundle)
        let before = allocatedBytes(disk)
        log("[*] Trimming \(label) to \(spec.keyValue): \(disk.path)")
        let result = try withMountedSystemVolume(disk) { root in
            try spec.apply(to: root) { log("  [trim] \($0)") }
        }
        let after = allocatedBytes(disk)
        log("[+] Trim \(spec.keyValue) removed \(VPhoneSystemTrim.formatBytes(result.bytes)) from the System volume")
        log("    Disk.img allocated \(VPhoneSystemTrim.formatBytes(before)) → \(VPhoneSystemTrim.formatBytes(after)); "
            + "the guest's orig-fs snapshot keeps the trimmed blocks until the setup boot deletes it")
        try record(spec, in: bundle, newRecord: newRecord)
        return result
    }

    // MARK: Checks

    /// Stopped, not a frozen template, not a clone of one, and not already
    /// trimmed in a way this trim cannot follow
    /// (``VPhoneSystemTrimSpec/canFollow(recorded:)``).
    static func requireTrimmable(_ bundle: VPhoneBundle, label: String, spec: VPhoneSystemTrimSpec) throws {
        guard spec.tier.isSupported else {
            throw VPhoneSystemTrimError.unsupportedTier(spec.tier.rawValue)
        }
        let url = bundle.url.absoluteURL.standardizedFileURL
        let record = try VPhoneMachineTemplates.readRecord(inBundle: url)
        if url.deletingLastPathComponent().lastPathComponent == VPhoneMachineTemplates.directoryName || record?.frozen == true {
            throw VPhoneMachineTemplateError.frozen(identifier: record?.identifier ?? url.lastPathComponent)
        }
        if let source = VPhoneMachineTemplates.readSource(inBundle: url) {
            throw VPhoneSystemTrimError.clonedFromTemplate(machine: label, template: source.identifier)
        }
        try VPhoneBundleActivity.requireStopped(bundle)
        if let recorded = record?.steps.trimTier, !spec.canFollow(recorded: recorded) {
            throw VPhoneSystemTrimError.downgrade(machine: label, recorded: recorded, requested: spec.keyValue)
        }
    }

    private static func record(_ spec: VPhoneSystemTrimSpec, in bundle: VPhoneBundle, newRecord: VPhoneMachineTemplateRecord?) throws {
        try VPhoneMachineTemplates.recordSteps(inBundle: bundle.url, creating: newRecord.map { record in { record } }) {
            $0.trimTier = spec.keyValue
        }
    }

    /// `Disk.img`: a regular file with one link, owned by the account that
    /// started a sudo run when there is one.
    private static func diskImage(of bundle: VPhoneBundle) throws -> URL {
        let disk = bundle.url.appendingPathComponent(bundle.manifest.diskImage)
        var info = stat()
        guard lstat(disk.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ValidationError("\(disk.path) is not a plain disk image file.")
        }
        if geteuid() == 0, let user = VPhoneInvokingUser.current, info.st_uid != user.uid {
            throw ValidationError("\(disk.path) is not owned by the account that started this command.")
        }
        return disk
    }

    private static func allocatedBytes(_ url: URL) -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return UInt64(max(info.st_blocks, 0)) * 512
    }

    // MARK: Mounting

    /// Attaches `disk`, mounts its System-role volume and hands `body` its
    /// root; unmounts and detaches on every way out.
    private static func withMountedSystemVolume<T>(_ disk: URL, _ body: (VPhoneConfinedDirectory) throws -> T) throws -> T {
        let work = try makeWorkDirectory()
        defer { rmdir(work.appendingPathComponent("system").path); rmdir(work.path) }
        let mountPoint = work.appendingPathComponent("system")
        guard mkdir(mountPoint.path, 0o700) == 0 else {
            throw ValidationError("Cannot create \(mountPoint.path): \(String(cString: strerror(errno)))")
        }

        // `diskutil image attach` has no image-class key; it reads a headerless
        // `Disk.img` as a raw image by itself. A failed attach can still leave
        // a device, so its output is read before its exit status.
        let attach = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/diskutil"), ["image", "attach", "-noMount", disk.path],
        )
        let attached = attach.stdout
        let disks = VPhoneGuestDiskLayout.attachedDisks(fromAttachOutput: attached)
        guard attach.succeeded, let whole = disks.wholeDisk, VPhoneGuestDiskLayout.isDeviceName(whole) else {
            let leftover = disks.wholeDisk.flatMap { VPhoneGuestDiskLayout.isDeviceName($0) ? $0 : nil }
                ?? attached.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression).map { String(attached[$0]) }
            if let leftover {
                eject(leftover)
            }
            let detail = attach.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VPhoneSystemTrimError.layout(attach.succeeded
                ? "diskutil attached no disk image"
                : "diskutil image attach failed (\(attach.exitCode)): \(detail)")
        }
        defer { eject(whole) }
        guard let store = disks.store, VPhoneGuestDiskLayout.isDeviceName(store) else {
            throw VPhoneSystemTrimError.layout("the image on \(whole) has no APFS partition")
        }
        let info = try tool("/usr/sbin/diskutil", ["info", "-plist", store])
        guard
            let plist = try? PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil) as? [String: Any],
            let container = plist["APFSContainerReference"] as? String,
            VPhoneGuestDiskLayout.isDeviceName(container)
        else {
            throw VPhoneSystemTrimError.layout("\(store) is not an APFS physical store")
        }
        let list = try tool("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
        let system = try VPhoneGuestDiskLayout.systemVolume(fromAPFSList: Data(list.utf8), container: container, physicalStore: store)

        _ = try tool("/usr/sbin/diskutil", [
            "mount", "-mountOptions", "nosuid,nodev,noowners,nobrowse", "-mountPoint", mountPoint.path, system,
        ])
        defer {
            if (try? tool("/usr/sbin/diskutil", ["unmount", mountPoint.path])) == nil {
                _ = try? tool("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path])
            }
        }
        // Every descriptor on the volume lives in this scope, so none holds
        // it busy when the deferred unmount runs.
        do {
            let root = try VPhoneConfinedDirectory.pin(absolutePath: work.path).mountedVolume("system")
            guard try root.mountedFrom() == "/dev/\(system)" else {
                throw VPhoneSystemTrimError.layout("\(mountPoint.path) is not /dev/\(system)")
            }
            return try body(root)
        }
    }

    /// `diskutil eject`, and when that fails (a volume still busy), a forced
    /// `unmountDisk` and a second eject: the `diskutil` form of `hdiutil
    /// detach -force` that macOS 15 also accepts.
    private static func eject(_ device: String) {
        if (try? tool("/usr/sbin/diskutil", ["eject", device])) == nil {
            _ = try? tool("/usr/sbin/diskutil", ["unmountDisk", "force", device])
            _ = try? tool("/usr/sbin/diskutil", ["eject", device])
        }
    }

    /// A fresh 0700 folder under `/private/var/tmp`, named by `mkdtemp` so it
    /// cannot be predicted or claimed beforehand.
    private static func makeWorkDirectory() throws -> URL {
        var template = Array("/private/var/tmp/vphone-trim.XXXXXXXX".utf8CString)
        // Read the name while the buffer mkdtemp returns a pointer into is
        // still pinned; `&template` lends one that ends with the call (#628).
        let made = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let made else {
            throw ValidationError("Cannot create a work folder in /private/var/tmp: \(String(cString: strerror(errno)))")
        }
        return URL(fileURLWithPath: made, isDirectory: true)
    }

    @discardableResult
    private static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: path), arguments)
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError("\(URL(fileURLWithPath: path).lastPathComponent) \(arguments.first ?? "") failed (\(result.exitCode)): \(detail)")
        }
        return result.stdout
    }
}
