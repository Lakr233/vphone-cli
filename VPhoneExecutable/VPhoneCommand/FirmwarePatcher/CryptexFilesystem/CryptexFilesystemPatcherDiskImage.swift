// CryptexFilesystemPatcherDiskImage.swift — Disk image attach, convert and copy helpers.
//
// Split out of CryptexFilesystemPatcher.swift. The diskutil layer: attaching and
// detaching images, converting between RAW and UDRW, resizing, unmounting, and the
// copyfile-based volume copy used to merge a cryptex into the target volume.

import Foundation
import VPhoneCoreKit

extension CryptexFilesystemPatcher {
    func copyImageContents(source: URL, destination: URL) throws {
        let input = try VPhoneConfinedDirectory.pin(absolutePath: source.path)
        let output = try VPhoneConfinedDirectory.pin(absolutePath: destination.path)
        // The caller just created the empty destination. Preserve guest links
        // without following them and refuse special files.
        for name in try input.entries() {
            if try input.isDirectory(name) {
                try output.copyTree(from: input.directory(name), to: name)
            } else if let link = try input.readLink(name) {
                try output.createSymlink(target: link, at: name)
            } else {
                try input.copyFile(from: name, to: name, in: output)
            }
        }
    }

    func convertToRawImage(input: URL, output: URL) throws {
        let arguments = if #available(macOS 26, *) {
            ["image", "create", "from", "-format", "RAW", input.path, output.path]
        } else {
            ["image", "create", "from", "-format", "RAW", "-source", input.path, output.path]
        }
        _ = try runProcess("/usr/sbin/diskutil", arguments)

        // Resize to max. Asking diskutil how big it may get returns a plist, and
        // reading one value out of it used to be `/bin/sh -c "… | plutil -extract
        // max raw -o - -"`: a shell and a second tool to parse what this process
        // can read directly — and a pipeline whose stdout is also where diskutil's
        // own warnings land, so a noisy run produced a "size" that was a sentence.
        let sizes = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "-plist", output.path,
        ])
        let maxsize = try Self.maxResizeSize(fromDiskutilPlist: sizes)
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let limit = Int64(maxsize), limit > size {
            _ = try runProcess("/usr/sbin/diskutil", [
                "image", "resize", "-size", maxsize, output.path,
            ])
            return
        }
        // An OS image with no partition map (iOS 26.5's 094-54920-099, 9.3 GB
        // with 537 MB free) has its container on the whole file, and diskutil's
        // max is then its current size: merging the System OS cryptex ran out
        // of space in the image. It grows as growImage grows such an image;
        // the room is sparse, and shrinkImage gives it back after the merge.
        try growImage(dmg: output, by: Self.mergeHeadroom)
    }

    /// Room the cryptexes and the guest additions need on the OS volume.
    static let mergeHeadroom: Int64 = 16 << 30

    /// The `max` value out of `diskutil image resize --plist`, as the string
    /// `--size` wants back.
    ///
    /// `runProcess` merges stderr into stdout, so the plist may arrive with a
    /// line of diskutil's own in front of it; the parse starts at the XML
    /// declaration rather than assuming the first byte is one.
    static func maxResizeSize(fromDiskutilPlist output: String) throws -> String {
        let body = output.range(of: "<?xml").map { String(output[$0.lowerBound...]) } ?? output
        guard let data = body.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil,
              ) as? [String: Any]
        else {
            throw ProcessError.failed(0, "diskutil did not return a plist:\n\(output)")
        }
        switch root["max"] {
        case let number as NSNumber: return number.stringValue
        case let string as String: return string
        default:
            throw ProcessError.failed(0, "no 'max' size in diskutil's plist:\n\(output)")
        }
    }

    func convertToUDRWImage(input: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        // diskutil calls the former UDRW read-write format RAW.
        let arguments = if #available(macOS 26, *) {
            ["image", "create", "from", "-format", "RAW", input.path, output.path]
        } else {
            ["image", "create", "from", "-format", "RAW", "-source", input.path, output.path]
        }
        _ = try runProcess("/usr/sbin/diskutil", arguments)
    }

    func shrinkImage(dmg: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image",
            "resize",
            "-size", "min",
            dmg.path,
        ])
    }

    /// Room `apfs_sealvolume` needs on the merged volume to remap its fsroot tree.
    static let sealHeadroom: Int64 = 2 << 30

    /// Add `bytes` to the image's size, for a tool that needs room on a
    /// volume `shrinkImage` left at its minimum.
    ///
    /// diskutil grows an image only up to the size its container already
    /// spans. A system image with no partition map sits on the whole file, so
    /// once it is merged at that size there is nothing left: watchOS 26.4's
    /// stopped at 11.2 GB on macOS 26.6.2 ("Requested size exceeds maximum
    /// size"), and the seal then ran out of space remapping its fsroot tree.
    /// Such an image grows by extending the file and letting the container
    /// fill it.
    func growImage(dmg: URL, by bytes: Int64) throws {
        // Extending a file whose size is unknown would cut it to `bytes`.
        guard let size = (try FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? NSNumber)?.int64Value,
              size > 0
        else {
            throw ProcessError.failed(0, "could not read the size of \(dmg.lastPathComponent) to grow it")
        }
        let sizes = try runProcess("/usr/sbin/diskutil", ["image", "resize", "-plist", dmg.path])
        let limit = try Int64(Self.maxResizeSize(fromDiskutilPlist: sizes))
        if let limit, size + bytes <= limit {
            _ = try runProcess("/usr/sbin/diskutil", [
                "image", "resize", "-size", String(size + bytes), dmg.path,
            ])
            return
        }
        // Only a container on the whole file grows with it: behind a partition
        // map, the map and its backup header would still end at the old size.
        let probe = try runProcess("/usr/sbin/diskutil", ["image", "attach", "-noMount", dmg.path])
        detachReportedImage(in: probe)
        guard !Self.hasPartitionMap(attachOutput: probe) else {
            throw ProcessError.failed(0, "\(dmg.lastPathComponent) has a partition map, and diskutil grows it no further than \(limit.map(String.init) ?? "its current size") bytes; \(bytes) more are needed")
        }
        let handle = try FileHandle(forWritingTo: dmg)
        try handle.truncate(atOffset: UInt64(size + bytes))
        try handle.close()
        let volume = try attachImageWithoutMounting(path: dmg)
        defer { try? detachImage(deviceNode: volume) }
        // disk7s1 → disk7: `0` makes the container take all of its physical store.
        let container = volume.replacingOccurrences(of: #"s[0-9]+$"#, with: "", options: .regularExpression)
        _ = try runProcess("/usr/sbin/diskutil", ["apfs", "resizeContainer", container, "0"])
        VPhoneConsole.shared.line("  [+] Grew \(dmg.lastPathComponent)'s container past diskutil's limit by \(bytes) bytes", .note)
    }

    /// Whether `diskutil image attach` reported a partition map (a
    /// `…_partition_scheme` disk or an `Apple_APFS` partition) rather than an
    /// APFS container on the whole image.
    static func hasPartitionMap(attachOutput output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && (fields[1].hasSuffix("_partition_scheme") || fields[1] == "Apple_APFS")
        }
    }

    /// Attach an image without mounting anything, and return its APFS volume's
    /// device node.
    func attachImageWithoutMounting(path: URL) throws -> String {
        let output: String
        do {
            output = try runProcess("/usr/sbin/diskutil", ["image", "attach", "-noMount", path.path])
        } catch let ProcessError.failed(status, output) {
            detachReportedImage(in: output)
            throw ProcessError.failed(status, output)
        }
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasPrefix("/dev/disk"), fields[1] == "Apple_APFS_Volume" else {
                continue
            }
            let device = String(fields[0])
            attachedDevices.insert(device)
            return device
        }
        detachReportedImage(in: output)
        throw FirmwareManifest.ManifestError.missingKey("APFS volume in \(path.lastPathComponent)")
    }

    /// Delete the event log the host's fseventsd keeps on a writable mount.
    ///
    /// Apple's system volumes have no `.fseventsd`, and the restore writes
    /// `.fseventsd/.ramdisk-boot-done` into the one it restores. A log the host
    /// left in the image shows up in the mtree, the restored volume then no
    /// longer matches it, and the restore fails at `seal_system_volume`
    /// ("mtree: cannot generate the XML dictionary"). Deleting the directory on
    /// the mounted volume also stops fseventsd writing it again for this mount.
    func removeHostEventLog(mount: String) throws {
        let directory = try VPhoneConfinedDirectory.pin(absolutePath: mount)
        try directory.removeItem(".fseventsd")
    }

    /// attachImage returns the device and mount point
    func attachImage(path: URL, readonly: Bool = false, forceRW: Bool = false) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        let mountPoint = try createTmpDir().appending(path: "volume")
        // diskutil image attach refuses a mount point that does not exist
        // ("Mount point … doesn't exist", macOS 26.6.2).
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        process.arguments = if readonly {
            [
                "image", "attach", "-mountPoint", mountPoint.path, "-nobrowse",
                "-readOnly",
                path.path,
            ]
        } else {
            [
                "image", "attach", "-mountPoint", mountPoint.path, "-nobrowse",
                path.path,
            ]
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            detachReportedImage(in: output)
            throw ProcessError.failed(process.terminationStatus, output)
        }

        let output = String(decoding: data, as: UTF8.self)
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, fields[0].hasPrefix("/dev/disk"), fields[2].hasPrefix("/") else {
                continue
            }
            let device = fields[0]
            let mountPoint = fields[2]

            attachedDevices.insert(device)
            if forceRW {
                do {
                    _ = try runProcess("/sbin/mount", ["-u", "-w", device, mountPoint])
                } catch {
                    try? detachImage(deviceNode: device)
                    throw error
                }
            }
            return (device, mountPoint)
        }
        detachReportedImage(in: String(data: data, encoding: .utf8) ?? "")
        throw FirmwareManifest.ManifestError.missingKey("dev-entry or mount-point")
    }

    private func detachReportedImage(in output: String) {
        guard let range = output.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression) else {
            return
        }
        let device = String(output[range])
        attachedDevices.insert(device)
        try? detachImage(deviceNode: device)
    }

    func detachImage(deviceNode: String) throws {
        do {
            _ = try runProcess("/usr/sbin/diskutil", ["eject", deviceNode])
        } catch {
            _ = try runProcess("/usr/sbin/diskutil", ["unmountDisk", "force", deviceNode])
            _ = try runProcess("/usr/sbin/diskutil", ["eject", deviceNode])
        }
        attachedDevices.remove(deviceNode)
    }
}
