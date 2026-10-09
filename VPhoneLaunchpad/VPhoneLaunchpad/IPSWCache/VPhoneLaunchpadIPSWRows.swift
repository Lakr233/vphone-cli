import Foundation

// MARK: - Rows

/// One IPSW in the Downloaded Firmware table.
nonisolated struct VPhoneLaunchpadIPSWRow: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var fileName: String
    var kind: VPhoneLaunchpadIPSW.Kind
    var kindLabel: String
    /// The product types the IPSW restores, `iPhone17,3`, which tell apart
    /// two IPSWs of one release.
    var devices: String
    var size: Int64
    var usedBy: [String]
    var isDownloading: Bool
    /// What deleting the IPSW now would break; nil when nothing. Deletion
    /// goes ahead either way, after the confirmation repeats it.
    var deletionWarning: String?
}

// MARK: - Catalog names

/// Names from `fw catalog --json`, found by the file a catalog URL becomes
/// in the cache, or by the URL's own file name for a copy kept elsewhere.
nonisolated struct VPhoneLaunchpadIPSWCatalogNames: Sendable {
    private var names: [String: String] = [:]

    /// Each image's name and URL.
    init(images: [(name: String, url: String)]) {
        for image in images {
            guard let url = URL(string: image.url) else {
                continue
            }
            names[VPhoneLaunchpadIPSW.cacheName(for: url)] = image.name
            names[url.lastPathComponent] = image.name
        }
    }

    func name(forFile fileName: String) -> String? {
        names[fileName]
    }
}

// MARK: - Machines

/// What a machine was restored from, or is being created from, for the Used
/// By column and the deletion rules.
nonisolated struct VPhoneLaunchpadIPSWUse: Hashable, Sendable {
    struct Release: Hashable, Sendable {
        var version: String
        var build: String
    }

    var machine: String
    /// `guestProductType` from the machine's config.plist.
    var productType: String?
    var ios: Release?
    var cloudOS: Release?
    /// The `--iphone-source` and `--cloudos-source` of a creation: URLs, or
    /// paths of local files.
    var sources: [String] = []
    var isCreating = false
    /// A creation that has not finished: under way, or stopped short and
    /// waiting for a retry, which reads its sources again.
    var needsSources = false

    func uses(_ file: VPhoneLaunchpadIPSWFile) -> Bool {
        if sources.contains(where: { Self.source($0, is: file) }) {
            return true
        }
        guard let facts = file.facts else {
            return false
        }
        if facts.kind == .cloudOS {
            return cloudOS == Release(version: facts.version, build: facts.build)
        }
        guard ios == Release(version: facts.version, build: facts.build) else {
            return false
        }
        guard let productType, !facts.productTypes.isEmpty else {
            return true
        }
        return facts.productTypes.contains(productType)
    }

    /// Whether a creation's source is this file: a URL by the name `fw
    /// prepare` gives its download, a local file by its path.
    static func source(_ source: String, is file: VPhoneLaunchpadIPSWFile) -> Bool {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return VPhoneLaunchpadIPSW.cacheName(for: url) == file.name
        }
        let path = source.hasPrefix("file://") ? URL(string: source)?.path ?? source : source
        return URL(fileURLWithPath: path).standardizedFileURL.path == file.url.standardizedFileURL.path
    }
}

// MARK: - Building

nonisolated enum VPhoneLaunchpadIPSWRows {
    /// iPhone IPSWs first, then iPad, cloudOS and unknown, each newest first.
    static func rows(
        _ files: [VPhoneLaunchpadIPSWFile],
        catalog: VPhoneLaunchpadIPSWCatalogNames?,
        uses: [VPhoneLaunchpadIPSWUse],
        isCreating: Bool = false,
    ) -> [VPhoneLaunchpadIPSWRow] {
        files.map { file in
            let facts = file.facts
            let kind = facts?.kind ?? .unknown
            let catalogName = catalog?.name(forFile: file.name)
            return VPhoneLaunchpadIPSWRow(
                id: file.id,
                title: title(file, catalogName: catalogName),
                fileName: file.name,
                kind: kind,
                kindLabel: kindLabel(kind),
                devices: facts?.productTypes.joined(separator: ", ") ?? "",
                size: file.size,
                usedBy: uses.filter { $0.uses(file) }.map { use in
                    use.isCreating ? String(localized: "\(use.machine) (creating)") : use.machine
                },
                isDownloading: file.isDownloading,
                deletionWarning: deletionWarning(file, uses: uses, isCreating: isCreating),
            )
        }
        .sorted { lhs, rhs in
            lhs.kind == rhs.kind
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedDescending
                : order(lhs.kind) < order(rhs.kind)
        }
    }

    private static func order(_ kind: VPhoneLaunchpadIPSW.Kind) -> Int {
        switch kind {
        case .iPhone: 0
        case .iPad: 1
        case .cloudOS: 2
        case .unknown: 3
        }
    }

    /// The catalog's name with the build, `iOS 27.0 RC (24A435)`, else the
    /// manifest's `iOS 27.0 (24A435)`, else the file name.
    static func title(_ file: VPhoneLaunchpadIPSWFile, catalogName: String?) -> String {
        if let catalogName {
            guard let build = file.facts?.build, !catalogName.contains(build) else {
                return catalogName
            }
            return "\(catalogName) (\(build))"
        }
        return file.facts?.title ?? file.name
    }

    static func kindLabel(_ kind: VPhoneLaunchpadIPSW.Kind) -> String {
        switch kind {
        case .iPhone: String(localized: "iPhone")
        case .iPad: String(localized: "iPad")
        case .cloudOS: String(localized: "cloudOS")
        case .unknown: String(localized: "Unknown")
        }
    }

    // MARK: Deleting

    /// What deleting `file` now would break, or nil. A restored machine no
    /// longer reads its IPSWs: Update Kernel and Update Guest Environment
    /// work from the machine folder. So only a creation that has not
    /// finished needs one, since a retry reads its sources again. A partial
    /// file is a download, and only a creation under way downloads
    /// (`isCreating`). None of this refuses the deletion: that creation
    /// fails instead, and is retried or deleted.
    static func deletionWarning(
        _ file: VPhoneLaunchpadIPSWFile,
        uses: [VPhoneLaunchpadIPSWUse],
        isCreating: Bool,
    ) -> String? {
        let creations = uses
            .filter { use in use.needsSources && use.sources.contains { VPhoneLaunchpadIPSWUse.source($0, is: file) } }
            .map(\.machine)
        if !creations.isEmpty {
            return String(localized: "Creating \(creations.joined(separator: ", ")) reads this IPSW until the creation finishes.")
        }
        if file.isDownloading, isCreating {
            return String(localized: "This IPSW is still downloading.")
        }
        return nil
    }

    /// The confirmation's text: what goes, which machines keep working, and
    /// what brings it back, then what the deletion breaks.
    static func deletionMessage(_ row: VPhoneLaunchpadIPSWRow) -> String {
        let warning = row.deletionWarning.map { " \($0)" } ?? ""
        if row.isDownloading {
            return String(localized: "The partial download of \(row.fileName) is deleted.") + warning
        }
        let deleted = String(localized: "\(row.fileName) is deleted from the IPSW cache.")
        let again = String(localized: "Creating a machine from this release downloads it again.")
        guard !row.usedBy.isEmpty else {
            return "\(deleted) \(again)\(warning)"
        }
        let keep = String(localized: "\(row.usedBy.joined(separator: ", ")) keep working without it.")
        return "\(deleted) \(keep) \(again)\(warning)"
    }
}
