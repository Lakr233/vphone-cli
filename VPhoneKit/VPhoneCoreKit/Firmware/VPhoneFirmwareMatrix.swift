import Foundation

// MARK: - VPhoneFirmwareSupport

/// How much confidence this project has in one downloadable iPhone firmware.
///
/// `supported` means the compatibility guide's "Tested Environments" table records a boot on
/// that exact version/build; `notTested` means Apple still serves it but nobody
/// wrote a row for it. `unsupported` is never a table verdict — it is the
/// prefix the selector puts on "nothing matched", and it exists here only
/// because it shares the colour table with the other two.
public enum VPhoneFirmwareSupport: String, Sendable, CaseIterable {
    case supported = "Supported"
    case notTested = "Not Tested"
    case unsupported = "Unsupported"

    /// SGR introducer for this verdict. Green/amber/red, matching the palette
    /// the rest of the tool uses for status.
    var ansiColor: String {
        switch self {
        case .supported: "\u{1B}[32m"
        case .notTested: "\u{1B}[33m"
        case .unsupported: "\u{1B}[31m"
        }
    }
}

// MARK: - VPhoneStatusStyle

/// Whether ANSI colour may be written to one particular stream.
///
/// Three checks that have to stay together, and the order matters:
///
/// 1. `NO_COLOR` set to a non-empty value wins over everything.
/// 2. Otherwise colour follows `isatty` **of this stream**, not of the process.
/// 3. `CLICOLOR_FORCE=1` turns colour on even when the stream is a pipe.
///
/// The per-stream part is not a detail: the firmware listing styles stdout, the
/// selector's failure paths style stderr, and a run that pipes one and not the
/// other has to get a different answer for each. Getting this wrong means
/// escape codes land in a pipe, or colour disappears in a terminal.
public struct VPhoneStatusStyle: Sendable, Equatable {
    public let isColored: Bool

    public init(isColored: Bool) {
        self.isColored = isColored
    }

    /// The policy above, resolved for one file descriptor.
    public static func forStream(
        _ fileDescriptor: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> VPhoneStatusStyle {
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty {
            return VPhoneStatusStyle(isColored: false)
        }
        if isatty(fileDescriptor) != 0 {
            return VPhoneStatusStyle(isColored: true)
        }
        return VPhoneStatusStyle(isColored: environment["CLICOLOR_FORCE"] == "1")
    }

    /// `status`, left-justified to `width` and only then wrapped in colour.
    ///
    /// The padding goes *inside* the escape sequence. That is deliberate: it is
    /// where the shell's Python put it, and it keeps the plain and coloured
    /// renderings the same width on screen, so the STATUS column lines up in
    /// both. Moving the padding outside would change every byte of the output.
    public func render(_ status: VPhoneFirmwareSupport, width: Int = 0) -> String {
        let text = VPhoneFirmwareMatrix.leftJustified(status.rawValue, width)
        guard isColored else { return text }
        return "\(status.ansiColor)\(text)\u{1B}[0m"
    }
}

// MARK: - VPhoneFirmwareRelease

/// One downloadable restore image, as named by its own URL.
public struct VPhoneFirmwareRelease: Sendable, Hashable {
    public let version: String
    public let build: String
    public let url: String

    public init(version: String, build: String, url: String) {
        self.version = version
        self.build = build
        self.url = url
    }
}

// MARK: - VPhoneFirmwareBuildID

/// The (version, build) pair the compatibility table and the URL list are joined on.
public struct VPhoneFirmwareBuildID: Sendable, Hashable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

// MARK: - VPhoneFirmwareListing

/// Result of the `--list` path.
public enum VPhoneFirmwareListing: Sendable, Equatable {
    /// The rendered matrix. Goes to stdout; exit 0.
    case matrix(String)
    /// Nothing downloadable for the device. Goes to stderr; exit 1.
    case nothingDownloadable(String)
}

// MARK: - VPhoneFirmwareSelection

/// Result of resolving a version/build selector against the download list.
public enum VPhoneFirmwareSelection: Sendable, Equatable {
    /// One firmware and its verdict. Goes to stdout as `resolvedLine`; exit 0.
    case selected(release: VPhoneFirmwareRelease, support: VPhoneFirmwareSupport)
    /// A bare version that maps to several builds. Goes to stderr; exit 2 —
    /// `fw_prepare.sh` forwards that 2 so a caller can tell "ambiguous" from
    /// "no such firmware".
    case ambiguous(String)
    /// Nothing matched. Goes to stderr; exit 1.
    case unmatched(String)

    /// `version\tbuild\turl\tstatus`, which `fw_prepare.sh` reads back with
    /// `IFS=$'\t' read -r`.
    ///
    /// Plain even when the rest of the run is coloured. The shell echoes field
    /// 4 through its own `style_status`, so an escape sequence here would be
    /// wrapped in a second one.
    public var resolvedLine: String? {
        guard case let .selected(release, support) = self else { return nil }
        return "\(release.version)\t\(release.build)\t\(release.url)\t\(support.rawValue)\n"
    }
}

// MARK: - VPhoneFirmwareMatrix

/// The firmware support matrix: the compatibility guide's "Tested Environments" table joined
/// against the restore images Apple still serves.
///
/// This replaces the two Python heredocs that used to live inside
/// `scripts/fw_prepare.sh` (`list_firmwares` and `resolve_selector_from_downloads`).
/// They were 166 lines that duplicated the same three parsers — the Markdown
/// section scan, the URL scan, and the version sort — once each, so this is one
/// parser with two renderers on top of it.
public enum VPhoneFirmwareMatrix {
    // MARK: Parsing

    /// Every `(version, build)` the compatibility guide's "Tested Environments" section
    /// records for `device`.
    ///
    /// The section runs from the `## Tested Environments` heading to the next
    /// `## ` heading. Inside it, any backticked `17,3_26.1_23B85` cell whose
    /// device part equals `device` minus its `iPhone` prefix counts as tested;
    /// the cloudOS column uses `26.1-23B85`, which cannot match. A missing
    /// guide is not an error — it just means nothing is known to be tested.
    public static func testedBuilds(readme: String?, device: String) -> Set<VPhoneFirmwareBuildID> {
        guard let readme else { return [] }
        let deviceSuffix = device.hasPrefix("iPhone")
            ? String(device.dropFirst("iPhone".count))
            : device
        guard let cell = try? NSRegularExpression(
            pattern: "`(\\d+,\\d+)_([^_`]+)_([A-Za-z0-9]+)`",
        ) else { return [] }

        var tested: Set<VPhoneFirmwareBuildID> = []
        var inSection = false
        for line in normalizedLines(of: readme) {
            if line.hasPrefix("## Tested Environments") {
                inSection = true
                continue
            }
            if inSection, line.hasPrefix("## ") {
                break
            }
            guard inSection else { continue }

            for match in cell.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let device = group(1, of: match, in: line),
                      let version = group(2, of: match, in: line),
                      let build = group(3, of: match, in: line),
                      device == deviceSuffix
                else { continue }
                tested.insert(VPhoneFirmwareBuildID(version: version, build: build))
            }
        }
        return tested
    }

    /// Every restore image for `device` named by the `ipsw download … --urls`
    /// output, in the order the lines arrive and with duplicates dropped.
    ///
    /// A line counts when it *ends* with `/<device>_<version>_<build>_Restore.ipsw`,
    /// so the surrounding CDN path — which differs per release and is sometimes
    /// a bare UUID — is ignored.
    public static func releases(downloadURLs: String, device: String) -> [VPhoneFirmwareRelease] {
        let pattern = "/(" + NSRegularExpression.escapedPattern(for: device)
            + "_([^_]+)_([A-Za-z0-9]+)_Restore\\.ipsw)$"
        guard let name = try? NSRegularExpression(pattern: pattern) else { return [] }

        var seen: Set<VPhoneFirmwareRelease> = []
        var found: [VPhoneFirmwareRelease] = []
        for rawLine in normalizedLines(of: downloadURLs) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = name.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let version = group(2, of: match, in: line),
                  let build = group(3, of: match, in: line)
            else { continue }
            let release = VPhoneFirmwareRelease(version: version, build: build, url: line)
            if seen.insert(release).inserted {
                found.append(release)
            }
        }
        return found
    }

    /// The verdict for one release, given what the compatibility guide records.
    public static func support(
        of release: VPhoneFirmwareRelease,
        tested: Set<VPhoneFirmwareBuildID>,
    ) -> VPhoneFirmwareSupport {
        tested.contains(VPhoneFirmwareBuildID(version: release.version, build: release.build))
            ? .supported
            : .notTested
    }

    // MARK: Rendering — the listing

    /// The full `--list` report, rendered for a stream with `style`'s colour policy.
    public static func listing(
        device: String,
        readme: String?,
        downloadURLs: String,
        style: VPhoneStatusStyle,
    ) -> VPhoneFirmwareListing {
        let releases = releases(downloadURLs: downloadURLs, device: device)
        guard !releases.isEmpty else {
            return .nothingDownloadable("No downloadable IPSWs found for \(device)\n")
        }
        let tested = testedBuilds(readme: readme, device: device)
        let rows = releases.sorted { isNewer($0, than: $1) }

        var out = "Available downloadable IPSWs for \(device):\n"
        out += "\n"
        out += "Status: \(style.render(.supported, width: statusWidth))"
            + " \(style.render(.notTested, width: statusWidth))"
            + " \(style.render(.unsupported, width: statusWidth))\n"
        out += "\n"
        out += "\(leftJustified("VERSION", versionWidth)) \(leftJustified("BUILD", buildWidth)) STATUS\n"
        for row in rows {
            let status = support(of: row, tested: tested)
            out += "\(leftJustified(row.version, versionWidth))"
                + " \(leftJustified(row.build, buildWidth))"
                + " \(style.render(status, width: statusWidth))\n"
        }
        return .matrix(out)
    }

    // MARK: Rendering — the selector

    /// Resolve a version and/or build selector against the download list.
    ///
    /// Empty strings mean "unconstrained", which is how the shell passes an
    /// unset `IPHONE_VERSION`/`IPHONE_BUILD`. A bare version that matches more
    /// than one build is reported as ambiguous rather than guessed at; anything
    /// else resolves to the highest build that matched.
    public static func selection(
        device: String,
        version: String,
        build: String,
        readme: String?,
        downloadURLs: String,
        style: VPhoneStatusStyle,
    ) -> VPhoneFirmwareSelection {
        let matches = releases(downloadURLs: downloadURLs, device: device).filter {
            (version.isEmpty || $0.version == version) && (build.isEmpty || $0.build == build)
        }
        guard !matches.isEmpty else {
            let prefix = style.render(.unsupported)
            let selector = if !version.isEmpty, !build.isEmpty {
                "device=\(device) version=\(version) build=\(build)"
            } else if !build.isEmpty {
                "device=\(device) build=\(build)"
            } else {
                "device=\(device) version=\(version)"
            }
            return .unmatched("\(prefix): no downloadable IPSW matched \(selector)\n")
        }

        let tested = testedBuilds(readme: readme, device: device)
        let byBuild = matches.sorted { hasHigherBuild($0, than: $1) }

        if !version.isEmpty, build.isEmpty, Set(matches.map(\.build)).count > 1 {
            var out = "Version \(version) is ambiguous for \(device); specify one of these builds:\n"
            out += "\(leftJustified("BUILD", buildWidth)) STATUS\n"
            for match in byBuild {
                out += "\(leftJustified(match.build, buildWidth)) \(style.render(support(of: match, tested: tested)))\n"
            }
            return .ambiguous(out)
        }

        let selected = byBuild[0]
        return .selected(release: selected, support: support(of: selected, tested: tested))
    }

    // MARK: Ordering

    /// One dot-separated component of a version, compared the way the shell's
    /// Python compared it: numerically where it parses as a number, textually
    /// otherwise.
    ///
    /// The Python built a tuple and let Python compare it, which *raises* on a
    /// number-against-text comparison (`26.1` vs `26.beta`). Nothing Apple
    /// serves produces that, and raising is not a behaviour worth porting, so
    /// numbers sort before text here.
    enum VersionPart: Comparable {
        case number(Int)
        case text(String)

        static func < (lhs: VersionPart, rhs: VersionPart) -> Bool {
            switch (lhs, rhs) {
            case let (.number(l), .number(r)): l < r
            case let (.text(l), .text(r)): codePointsAscending(l, r)
            case (.number, .text): true
            case (.text, .number): false
            }
        }
    }

    /// `"26.4.1"` → `[26, 4, 1]`. Shorter sorts before longer on a common
    /// prefix, so `26.4` < `26.4.1`.
    static func versionKey(_ version: String) -> [VersionPart] {
        version.components(separatedBy: ".").map { part in
            if let number = Int(part) {
                .number(number)
            } else {
                .text(part)
            }
        }
    }

    /// Newest first: version descending, then build descending.
    ///
    /// URL breaks the remaining ties. The Python had nothing there — it sorted
    /// a `set`, so two rows sharing a version *and* a build came out in hash
    /// order, which is to say a different order per run. That is not a
    /// behaviour to reproduce, so the order here is total and reproducible.
    static func isNewer(_ lhs: VPhoneFirmwareRelease, than rhs: VPhoneFirmwareRelease) -> Bool {
        let (l, r) = (versionKey(lhs.version), versionKey(rhs.version))
        for (lp, rp) in zip(l, r) where lp != rp {
            return rp < lp
        }
        if l.count != r.count {
            return r.count < l.count
        }
        return hasHigherBuild(lhs, than: rhs)
    }

    /// Build descending, URL descending as the tie-break.
    static func hasHigherBuild(_ lhs: VPhoneFirmwareRelease, than rhs: VPhoneFirmwareRelease) -> Bool {
        if lhs.build != rhs.build {
            return codePointsAscending(rhs.build, lhs.build)
        }
        return codePointsAscending(rhs.url, lhs.url)
    }

    // MARK: Text helpers

    static let versionWidth = 12
    static let buildWidth = 10
    static let statusWidth = 11

    /// `String.padding(toLength:)` truncates; this does not, which is what the
    /// `f"{value:<12}"` it replaces did. Width is counted in code points, again
    /// to match.
    static func leftJustified(_ text: String, _ width: Int) -> String {
        let count = text.unicodeScalars.count
        guard count < width else { return text }
        return text + String(repeating: " ", count: width - count)
    }

    /// Code-point order, not Swift's canonical `String` ordering, because the
    /// comparison it stands in for was Python's.
    static func codePointsAscending(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return false
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(l), .some(r)):
                if l.value != r.value {
                    return l.value < r.value
                }
            }
        }
    }

    /// Text-mode line splitting: CRLF and CR collapse to LF, and a trailing
    /// newline does not produce a final empty line.
    static func normalizedLines(of text: String) -> [String] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        if normalized.isEmpty {
            return []
        }
        return normalized.components(separatedBy: "\n")
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - VPhoneFirmwareMatrixCommandLine

/// The two entry points `scripts/fw_prepare.sh` calls, including which stream
/// each half writes to and what it exits with.
///
/// Stream choice is load-bearing twice over. The listing styles **stdout**, so
/// `--list | less` gets plain text; every selector failure styles **stderr**,
/// so an error stays coloured even when the resolved URL is being captured in a
/// `$( … )`. Both are resolved independently, per stream.
public enum VPhoneFirmwareMatrixCommandLine {
    /// Print the support matrix. 0 on success, 1 when the device has nothing
    /// downloadable.
    public static func list(
        device: String,
        readmePath: String,
        downloadURLs: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
    ) -> Int32 {
        let readme = try? String(contentsOfFile: readmePath, encoding: .utf8)
        switch VPhoneFirmwareMatrix.listing(
            device: device,
            readme: readme,
            downloadURLs: downloadURLs,
            style: .forStream(stdout.fileDescriptor, environment: environment),
        ) {
        case let .matrix(text):
            write(text, to: stdout)
            return 0
        case let .nothingDownloadable(text):
            write(text, to: stderr)
            return 1
        }
    }

    /// Resolve a selector to `version\tbuild\turl\tstatus` on stdout. 0 on a
    /// hit, 2 when a bare version is ambiguous, 1 when nothing matched.
    public static func resolve(
        device: String,
        version: String,
        build: String,
        readmePath: String,
        downloadURLs: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
    ) -> Int32 {
        let readme = try? String(contentsOfFile: readmePath, encoding: .utf8)
        let selection = VPhoneFirmwareMatrix.selection(
            device: device,
            version: version,
            build: build,
            readme: readme,
            downloadURLs: downloadURLs,
            style: .forStream(stderr.fileDescriptor, environment: environment),
        )
        switch selection {
        case .selected:
            write(selection.resolvedLine ?? "", to: stdout)
            return 0
        case let .ambiguous(text):
            write(text, to: stderr)
            return 2
        case let .unmatched(text):
            write(text, to: stderr)
            return 1
        }
    }

    private static func write(_ text: String, to handle: FileHandle) {
        guard !text.isEmpty else { return }
        handle.write(Data(text.utf8))
    }
}
