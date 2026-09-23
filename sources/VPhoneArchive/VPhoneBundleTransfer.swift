import Darwin
import Foundation
import VPhoneCore

// MARK: - Errors

public enum VPhoneBundleTransferError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The archive is readable, but it is not a VM export.
    case badArchive(String)

    public var description: String {
        switch self {
        case let .badArchive(message): message
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - VPhoneBundleTransfer

/// `vm export` and `vm import`.
///
/// It lives here, and not in `VPhoneCore`, because it needs libarchive. It
/// lives here, and not in the VM kit, because `vphone-cli` deliberately does
/// not import the kit — see the note on that target in `Package.swift` —
/// and `vphone-cli vm export` has to keep working. `VPhoneArchive` sits above
/// `VPhoneCore` and needs neither Virtualization nor AppKit, which is exactly
/// the altitude this wants.
///
/// The format contract is fixed and older archives are already out there:
/// gnutar, `.tzst` at zstd 3, `.txz` at xz 9, extension chosen from the
/// preset. `importArchive` detects the compressor, so it reads anything an
/// older copy of this program produced — and `/usr/bin/tar` reads what this
/// produces.
public enum VPhoneBundleTransfer {
    /// Compression preset for `export`. Both import transparently —
    /// `importArchive` auto-detects the compressor when it extracts.
    public enum ExportCompression: String, CaseIterable, Sendable {
        case fast, max

        /// zstd 3 and xz 9. Not tuning knobs: archives with these settings
        /// have been handed to users, and the levels are part of what `.tzst`
        /// and `.txz` mean here.
        var archiveCompression: VPhoneArchiveCompression {
            switch self {
            case .fast: .zstd(level: 3)
            case .max: .xz(level: 9)
            }
        }

        /// Extension for auto-named output when `export`'s destination is a
        /// directory.
        public var fileExtension: String { archiveCompression.tarExtension }
    }

    // MARK: - Export

    /// When `to` is an existing directory, the archive is written inside it as
    /// `<name>.<compression.fileExtension>`. Returns the resolved output URL.
    ///
    /// `progress` is called with `(bytesDone, totalBytes)`, where `totalBytes`
    /// is the bundle's on-disk logical size minus the excludes, and `bytesDone`
    /// is the uncompressed payload packed so far. It ticks per megabyte rather
    /// than per member: a bundle is one huge `Disk.img` and a few small files.
    @discardableResult
    public static func export(
        bundleNamed name: String,
        to outFile: URL,
        includeIPSW: Bool,
        compression: ExportCompression = .fast,
        in library: VPhoneLibrary,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> URL {
        _ = try library.bundle(named: name)  // validate it exists
        var isDir: ObjCBool = false
        let outFile = FileManager.default.fileExists(atPath: outFile.path, isDirectory: &isDir)
            && isDir.boolValue
            ? outFile.appendingPathComponent("\(name).\(compression.fileExtension)")
            : outFile

        let bundleDir = library.url(forName: name)
        var excludes = VPhoneBundleOps.exportExcludePatterns
        if !includeIPSW { excludes.append("*_Restore*") }

        let total = progress != nil
            ? archivedLogicalSize(bundleDir: bundleDir, includeIPSW: includeIPSW)
            : 0

        // gnutar, not the pax default: pax extended headers used to break the
        // consumer of the old two-stage pipe, and — still true — ustar cannot
        // carry a member over 8 GB, which Disk.img is.
        //
        // topLevel is the bundle's own name, so the archive holds exactly one
        // top-level directory. importArchive checks for that, and so does
        // every export already on disk.
        try VPhoneArchiveWriter.create(
            archive: outFile,
            from: bundleDir,
            topLevel: name,
            format: .gnutar,
            compression: compression.archiveCompression,
            excluding: excludes,
            bytesPacked: progress.map { report in { done in report(done, total) } }
        )
        return outFile
    }

    /// On-disk logical size of the members `export` will archive, mirroring the
    /// exclude patterns so the progress total matches the streamed bytes.
    ///
    /// A hardlinked file is counted once, no matter how many names it has under
    /// the bundle. `VPhoneArchiveWriter` runs a link resolver: the first name is
    /// stored with its contents and every later name becomes a size-0 hardlink
    /// reference, so those later names contribute nothing to `bytesPacked`.
    /// Adding each name's size here made the total larger than anything that
    /// could ever be packed, and the bar could not reach 100%.
    private static func archivedLogicalSize(bundleDir: URL, includeIPSW: Bool) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .linkCountKey]
        let fm = FileManager.default
        guard let en = fm.enumerator(at: bundleDir, includingPropertiesForKeys: keys)
        else { return 0 }
        let prefix = bundleDir.path.count + 1  // members are relative to the bundle
        var total: Int64 = 0
        var countedInodes = Set<Inode>()
        for case let url as URL in en {
            guard url.path.count > prefix else { continue }
            let rel = String(url.path.dropFirst(prefix))
            if !includeIPSW, rel.contains("_Restore") { en.skipDescendants(); continue }
            if VPhoneBundleOps.exportExcludePatterns.contains(where: { fnmatch($0, rel, 0) == 0 }) {
                continue
            }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            // linkCount == 1 is every file in an ordinary bundle, and it costs
            // no extra syscall — only a genuinely linked file is stat'd again
            // to find out which inode it is a name for.
            if (vals.linkCount ?? 1) > 1 {
                guard let inode = Inode(path: url.path), countedInodes.insert(inode).inserted
                else { continue }
            }
            total += Int64(vals.fileSize ?? 0)
        }
        return total
    }

    /// Identity of a file's contents: device plus inode, which is what makes
    /// two names the same file rather than two files of equal size.
    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            number = info.st_ino
        }
    }

    // MARK: - Import

    /// Extracts (auto-detecting gzip/zstd/xz) into a private staging dir, then
    /// promotes the single top-level bundle to the library.
    ///
    /// `progress` is called with `(bytesDone, totalBytes)` against the archive
    /// file's size on disk — compressed bytes, which is what the user can see
    /// in Finder.
    public static func importArchive(
        from inFile: URL,
        name: String?,
        in library: VPhoneLibrary,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> VPhoneBundle {
        let fm = FileManager.default
        // Fail fast when the destination name is already known (explicit rename).
        if let name {
            try VPhoneBundleOps.requireValidName(name)
            if fm.fileExists(atPath: library.url(forName: name).path) {
                throw VPhoneLibraryError.alreadyExists(name: name)
            }
        }

        // Extract into a private staging dir so the archive's OWN top-level name
        // can never clobber/merge into an existing bundle of that name; only the
        // validated destination name is ever placed into the library.
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        let staging = library.root.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let total = progress != nil ? fileByteSize(inFile) : 0
        // .intoHostDirectory, and specifically NOT the guest-volume preset: an
        // import is an archive from another machine landing in the user's home
        // directory, so the umask applies and setuid/setgid do not survive —
        // what `/usr/bin/tar -xf` (no -p) gave when this shelled out. The
        // modes a VM bundle actually needs are its own files' 0644/0755;
        // nothing in it has any business being setuid.
        try VPhoneArchiveExtractor.extract(
            inFile,
            into: staging,
            options: .intoHostDirectory,
            bytesRead: progress.map { report in { done in report(done, total) } }
        )
        // A tar reader stops at the end-of-archive marker, which in a
        // compressed file can sit short of the last byte, so the read position
        // alone would leave the bar just under full on a finished import.
        progress?(total, total)

        let entries = try fm.contentsOfDirectory(atPath: staging.path)
        guard entries.count == 1, let archived = entries.first else {
            throw VPhoneBundleTransferError.badArchive(
                "This archive is not a VM export. Choose an archive created by 'vphone-cli vm export'.")
        }
        let finalName = name ?? archived
        try VPhoneBundleOps.requireValidName(finalName)
        let dst = library.url(forName: finalName)
        if fm.fileExists(atPath: dst.path) { throw VPhoneLibraryError.alreadyExists(name: finalName) }
        let extracted = staging.appendingPathComponent(archived)
        guard fm.fileExists(atPath: extracted.appendingPathComponent("config.plist").path) else {
            throw VPhoneBundleTransferError.badArchive(
                "This archive does not contain a valid VM. Choose an archive created by 'vphone-cli vm export'.")
        }
        let bundle = try VPhoneBundle.load(at: extracted)
        try fm.moveItem(at: extracted, to: dst)
        return VPhoneBundle(url: dst, manifest: bundle.manifest)
    }

    private static func fileByteSize(_ url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(size ?? 0)
    }
}
