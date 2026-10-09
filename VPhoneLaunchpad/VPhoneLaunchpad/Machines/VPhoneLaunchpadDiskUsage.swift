import Darwin
import Foundation

/// What a machine or template folder takes on disk.
///
/// `allocated` counts every block its files hold (`st_blocks`), shared or
/// not. `exclusive` counts the blocks no other measured folder holds: what
/// deleting the folder frees once nothing else keeps them. A machine cloned
/// from a template shares every block it has not written with the template
/// and its other clones, so its exclusive size is a fraction of what is
/// allocated.
///
/// It is measured by comparing physical extents (`VPhoneLaunchpadDiskExtents`),
/// not with APFS's private size (`ATTR_CMNEXT_PRIVATESIZE`): a Time Machine
/// local snapshot shares every block that existed when it was taken, so
/// after each hourly snapshot the private size of every machine is 0 until
/// it writes again. The blocks a snapshot holds are still freed when it
/// expires, and the comparison counts them as the folder's own.
nonisolated struct VPhoneLaunchpadDiskUsage: Hashable, Sendable {
    var allocated: Int64
    /// Nil when it could not be measured (the volume maps no extents, or the
    /// measurement ran out of time).
    var exclusive: Int64?

    /// `17.58 GB`, decimal as the Finder counts.
    static func format(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The inspector's value: `0.61 GB of 17.58 GB`, or the allocated size
    /// alone when the exclusive size is unknown.
    func summary(locale: Locale = .current) -> String {
        guard let exclusive else {
            return Self.format(allocated, locale: locale)
        }
        return String(localized: "\(Self.format(exclusive, locale: locale)) of \(Self.format(allocated, locale: locale))")
    }
}

// MARK: - Opening

/// Whether the meter may open a machine's files, from what Launchpad knows
/// of the machine.
///
/// Mapping opens the file, and while it is open `lsof` lists Launchpad for
/// it. `vm stop` signals every process `lsof` lists for a disk (SIGINT, then
/// SIGKILL to whoever is left at its timeout), and `cfw install` and
/// `update-environment` refuse a disk anyone else holds. So the meter opens
/// only the files of a machine that nothing runs, nothing holds and nothing
/// works on; any other machine keeps the extents last mapped.
nonisolated struct VPhoneLaunchpadDiskAccess: Hashable, Sendable {
    /// Launchpad's `vm launch` for the machine has not exited: starting,
    /// running, stopping, or panicked and not yet ended.
    var isLaunched = false
    /// `lsof` listed a process other than Launchpad for its disk image: a
    /// machine started elsewhere, or anything else holding it.
    var isHeld = false
    /// Launchpad has an operation on the machine: a creation or the template
    /// build in it, an export (queued or running), a CFW install, an
    /// environment or kernel update, a shutdown, a stop, a rename.
    var isBusy = false
    /// Launchpad has an operation on a whole library (an import, a template
    /// deletion), which can write any folder in it.
    var isLibraryBusy = false

    var mayOpen: Bool {
        !isLaunched && !isHeld && !isBusy && !isLibraryBusy
    }

    /// Whether the meter may open a template's files: no operation on a
    /// whole library runs (a template deletion), and no creation is at a
    /// step in `creationSteps` (the current step of each running one) that
    /// saves or clones a template. Mapping the image of a template saved a
    /// moment before made `vm create --template` refuse it as in use
    /// (Launchpad 2.9.0, New Machine failed at its clone step).
    static func templatesMayOpen(isLibraryBusy: Bool, creationSteps: [VPhoneLaunchpadCreationStep]) -> Bool {
        !isLibraryBusy && !creationSteps.contains(where: \.needsTemplatesToItself)
    }
}

// MARK: - Measuring

/// Measures machine and template folders against each other, keeping each
/// file's extents between passes.
///
/// A file is mapped again only when its size, modification or change time
/// is different, so a stopped machine's 20 GB image is opened once after it
/// changes, not on every pass. Mapping opens the file: `lsof` then lists
/// Launchpad for it, which `vm stop` and `cfw install` read as the machine
/// running. A folder is opened only while `VPhoneLaunchpadDiskAccess` allows
/// it (`Folder.mayOpen`, asked again right before each file is mapped), and
/// Launchpad leaves its own process out when it asks `lsof` which machines
/// run.
actor VPhoneLaunchpadDiskMeter {
    nonisolated struct Folder: Hashable, Sendable {
        var path: String
        /// False while something runs, holds or works on the folder: its
        /// files' last extents are used, and a file never mapped leaves it
        /// unknown.
        var mayOpen = true
    }

    /// What a pass does with one file.
    nonisolated enum FileUse: Equatable, Sendable {
        /// The extents mapped last are current: nothing is opened.
        case current
        /// The file changed (or was never mapped) and may be opened.
        case map
        /// The file may not be opened: the extents mapped last stand in.
        case last
        /// Nothing to go on: the folder's exclusive size is unknown.
        case unknown
    }

    /// The decision for one file. Only a changed file is ever opened, and
    /// only when its folder may be opened and the pass has time left.
    nonisolated static func use(isCurrent: Bool, hasLast: Bool, mayOpen: Bool, hasTime: Bool) -> FileUse {
        if isCurrent {
            return .current
        }
        guard mayOpen else {
            return hasLast ? .last : .unknown
        }
        // A changed file the budget leaves out is unknown, not stale, so a
        // folder that is still being written does not show a wrong size.
        return hasTime ? .map : .unknown
    }

    private nonisolated struct FileKey: Hashable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modified: Int
        var modifiedNanoseconds: Int
        var changed: Int
        var changedNanoseconds: Int
    }

    private nonisolated struct Mapped {
        var key: FileKey
        /// Nil for a file the volume does not map (a compressed file): its
        /// allocated size counts as its folder's own.
        var extents: VPhoneLaunchpadDiskExtents?
    }

    private var cache: [String: Mapped] = [:]
    private let budget: Duration

    /// `budget` bounds the mapping of one pass. Files left over are mapped
    /// on a later pass, and their folders are unknown meanwhile.
    init(budget: Duration = .seconds(15)) {
        self.budget = budget
    }

    /// Each folder's usage, by `Folder.path`. Files are not followed through
    /// links.
    ///
    /// `mayOpenNow` is asked with the folder's path right before one of its
    /// files is mapped, so a machine started, held or worked on since the
    /// pass began is not opened. The meter has one caller at a time; a
    /// second pass running while this one waits on `mayOpenNow` would only
    /// leave the cache less complete.
    func measure(
        _ folders: [Folder],
        mayOpenNow: (@Sendable (String) async -> Bool)? = nil,
    ) async -> [String: VPhoneLaunchpadDiskUsage] {
        let deadline = ContinuousClock.now + budget
        var seen: Set<String> = []
        var owners: [[VPhoneLaunchpadDiskExtents]] = []
        var usages: [VPhoneLaunchpadDiskUsage] = []
        var unmappedBytes: [Int64] = []
        for folder in folders {
            var mayOpen = folder.mayOpen
            var usage = VPhoneLaunchpadDiskUsage(allocated: 0, exclusive: 0)
            var extents: [VPhoneLaunchpadDiskExtents] = []
            var unmapped: Int64 = 0
            for file in Self.files(in: folder.path) {
                var status = stat()
                guard lstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    continue
                }
                seen.insert(file)
                let allocated = Int64(status.st_blocks) * 512
                usage.allocated += allocated
                guard allocated > 0 else {
                    continue
                }
                let key = FileKey(
                    device: Int64(status.st_dev), inode: status.st_ino, size: status.st_size,
                    modified: status.st_mtimespec.tv_sec, modifiedNanoseconds: status.st_mtimespec.tv_nsec,
                    changed: status.st_ctimespec.tv_sec, changedNanoseconds: status.st_ctimespec.tv_nsec,
                )
                let last = cache[file]
                func decide() -> FileUse {
                    Self.use(isCurrent: last?.key == key, hasLast: last != nil, mayOpen: mayOpen, hasTime: ContinuousClock.now < deadline)
                }
                var decision = decide()
                if decision == .map, let mayOpenNow, await !mayOpenNow(folder.path) {
                    mayOpen = false
                    decision = decide()
                }
                var found: Mapped?
                switch decision {
                case .current, .last:
                    // A folder that may not be opened keeps what was last
                    // mapped, which is close: its blocks rarely move.
                    found = last
                case .map:
                    switch VPhoneLaunchpadDiskExtents.map(file, deadline: deadline) {
                    case let .success(result):
                        found = Mapped(key: key, extents: result)
                    case .failure(.unsupported):
                        found = Mapped(key: key, extents: nil)
                    case .failure(.tooLarge):
                        break
                    }
                    if let found {
                        cache[file] = found
                    }
                case .unknown:
                    break
                }
                guard let found else {
                    usage.exclusive = nil
                    continue
                }
                if let result = found.extents {
                    extents.append(result)
                } else {
                    unmapped += allocated
                }
            }
            owners.append(extents)
            usages.append(usage)
            unmappedBytes.append(unmapped)
        }
        cache = cache.filter { seen.contains($0.key) }
        let exclusive = VPhoneLaunchpadDiskExtents.exclusiveBytes(of: owners)
        var result: [String: VPhoneLaunchpadDiskUsage] = [:]
        for (index, folder) in folders.enumerated() {
            var usage = usages[index]
            // Rounding to whole blocks can only add to what st_blocks says.
            usage.exclusive = usage.exclusive.map { _ in min(usage.allocated, exclusive[index] + unmappedBytes[index]) }
            result[folder.path] = usage
        }
        return result
    }

    /// Every entry under `path`, not through links. The walk does not
    /// descend into a linked directory, and `lstat` rejects a linked file.
    private nonisolated static func files(in path: String) -> [String] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            return []
        }
        var files: [String] = []
        for case let file as URL in walker {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(file.path)
            }
        }
        return files
    }

    /// Whether a library's `.templates` holds a `.building-…` folder: a
    /// template build under way, or one that stopped before it finished.
    nonisolated static func hasTemplateBuilds(in libraryRoot: String) -> Bool {
        let templates = URL(fileURLWithPath: libraryRoot, isDirectory: true).appendingPathComponent(".templates", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: templates.path)) ?? []
        return names.contains { $0.hasPrefix(".building-") }
    }

    /// The template folders of a library: `.templates/<12 hex>`. Builds
    /// (`.building-…`) are left out; they are written while they exist.
    nonisolated static func templateFolders(in libraryRoot: String) -> [String] {
        let templates = URL(fileURLWithPath: libraryRoot, isDirectory: true).appendingPathComponent(".templates", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: templates.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.wholeMatch(of: /[0-9a-f]{12}/) != nil else {
                return nil
            }
            let folder = templates.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            guard lstat(folder.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                return nil
            }
            return folder.path
        }
    }
}
