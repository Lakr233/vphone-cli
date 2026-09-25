// CryptexFilesystemPatcherDiskImage.swift — Disk image attach, convert and copy helpers.
//
// Split out of CryptexFilesystemPatcher.swift. The hdiutil/diskutil layer: attaching and
// detaching images, converting between RAW and UDRW, resizing, unmounting, and the
// copyfile-based volume copy used to merge a cryptex into the target volume.

import Foundation

extension CryptexFilesystemPatcher {
    func copyImageContents(source: URL, destination: URL) throws {
        // Copy everything from source volume root into destination volume root.
        let sourceRoot = source.appendingPathComponent("", isDirectory: true)
        let sourcePath = sourceRoot.path
        let destinationRoot = destination.appendingPathComponent("", isDirectory: true)

        // We delete the files first as we want to replace symlinks with actual files.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: keys) else {
            throw FirmwareManifest.ManifestError.fileNotFound(
                "\(sourceRoot.path). Check that the image is still mounted, then try again.",
            )
        }
        for case let fileURL as URL in enumerator {
            guard fileURL.path.hasPrefix(sourcePath) else { continue }

            let values = try fileURL.resourceValues(forKeys: Set(keys))
            var suffix = String(fileURL.path.dropFirst(sourcePath.count))
            if suffix.hasPrefix("/") {
                suffix.removeFirst()
            }

            let destinationPath = destinationRoot.appendingPathComponent(suffix)
            guard let ok = try? destinationPath.checkResourceIsReachable(), ok else {
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                try copyNoFollow(fileURL, to: destinationPath)
                continue
            }

            let vals = try destinationPath.resourceValues(forKeys: Set(keys))
            if values.isDirectory != vals.isDirectory ||
                values.isRegularFile != vals.isRegularFile ||
                values.isSymbolicLink != vals.isSymbolicLink
            {
                try FileManager.default.removeItem(at: destinationPath)
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                try copyNoFollow(fileURL, to: destinationPath)
            }
        }
    }

    /// copyfile without following a symlink at either end; a failure stops
    /// the merge instead of leaving a volume with a silent hole in it.
    private func copyNoFollow(_ source: URL, to destination: URL) throws {
        guard copyfile(
            source.path,
            destination.path,
            nil,
            copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA | COPYFILE_NOFOLLOW),
        ) == 0 else {
            throw CryptexFileOperationError.guestIO(path: destination.path, operation: "copy", code: errno)
        }
    }

    func convertToRawImage(input: URL, output: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "create", "from",
            "--format", "RAW", input.path,
            output.path,
        ])

        // Resize to max. Asking diskutil how big it may get returns a plist, and
        // reading one value out of it used to be `/bin/sh -c "… | plutil -extract
        // max raw -o - -"`: a shell and a second tool to parse what this process
        // can read directly — and a pipeline whose stdout is also where diskutil's
        // own warnings land, so a noisy run produced a "size" that was a sentence.
        let sizes = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "--plist", output.path,
        ])
        let maxsize = try Self.maxResizeSize(fromDiskutilPlist: sizes)
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "--size", maxsize, output.path,
        ])
    }

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
        _ = try runProcess("/usr/bin/hdiutil", [
            "convert",
            input.path,
            "-format", "UDRW",
            "-o", output.path,
        ])
    }

    func shrinkImage(dmg: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image",
            "resize",
            "--size", "min",
            dmg.path,
        ])
    }

    func unmount(mount: String) throws {
        _ = try runProcess("/usr/sbin/diskutil", ["unmount", mount])
    }

    /// attachImage returns the device and mount point
    func attachImage(path: URL, readonly: Bool = false, forceRW: Bool = false) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        // Mount under a fresh 0700 directory of our own, honour ownership, and
        // keep it out of Finder, so nothing else can race us to the mount point.
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-mount.XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template), let real = realpath(created, nil) else {
            throw CryptexFileOperationError.guestIO(path: "mount directory", operation: "create", code: errno)
        }
        // Real path: statfs reports /private/var, not the /var link.
        let parent = String(cString: real)
        free(real)
        guard chmod(parent, 0o700) == 0 else {
            rmdir(parent)
            throw CryptexFileOperationError.guestIO(path: parent, operation: "chmod", code: errno)
        }
        var arguments = ["attach", "-nobrowse", "-owners", "on", "-mountrandom", parent]
        if readonly {
            arguments.append("-readonly")
        }
        process.arguments = arguments + ["-plist", path.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            detachReportedImage(in: output)
            rmdir(parent)
            throw ProcessError.failed(process.terminationStatus, output)
        }

        let root: PlistDict
        do {
            root = try parsePlist(data: data)
        } catch {
            detachReportedImage(in: String(data: data, encoding: .utf8) ?? "")
            throw error
        }
        guard let entries = root["system-entities"] as? [Any] else {
            detachReportedImage(in: String(data: data, encoding: .utf8) ?? "")
            throw FirmwareManifest.ManifestError.missingKey("system-entities")
        }
        for entry in entries {
            guard let entry = entry as? PlistDict,
                  let volumeKind = entry["volume-kind"] as? String,
                  volumeKind == "apfs" || volumeKind == "hfs"
            else {
                continue
            }
            let device = entry["dev-entry"] as? String ?? ""
            let mountPoint = entry["mount-point"] as? String ?? ""
            guard !device.isEmpty, !mountPoint.isEmpty else { continue }

            attachedDevices.insert(device)
            mountParents[device] = parent
            do {
                try verifyMount(mountPoint, isFrom: device, under: parent)
            } catch {
                try? detachImage(deviceNode: device)
                throw error
            }
            mountPoints[device] = mountPoint
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

    /// The mount point must really be the device we just attached, not
    /// something mounted or linked there in between.
    private func verifyMount(_ mountPoint: String, isFrom device: String, under parent: String) throws {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else {
            throw CryptexFileOperationError.guestIO(path: mountPoint, operation: "statfs", code: errno)
        }
        let source = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let mounted = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard source == device, mounted.hasPrefix(parent + "/"),
              mounted == mountPoint || mounted == (mountPoint as NSString).resolvingSymlinksInPath
        else {
            throw FirmwarePatcher.PatcherError.patchVerificationFailed(
                "\(mountPoint) is mounted from \(source) at \(mounted), expected \(device)",
            )
        }
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
            _ = try runProcess("/usr/bin/hdiutil", ["detach", deviceNode])
        } catch {
            _ = try runProcess("/usr/bin/hdiutil", ["detach", "-force", deviceNode])
        }
        attachedDevices.remove(deviceNode)
        mountPoints.removeValue(forKey: deviceNode)
        if let parent = mountParents.removeValue(forKey: deviceNode) {
            rmdir(parent)
        }
    }
}
