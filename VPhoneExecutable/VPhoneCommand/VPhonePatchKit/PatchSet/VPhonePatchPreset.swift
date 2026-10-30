// VPhonePatchPreset.swift — A named, prewritten combination of patch sets.
//
// Presets ship inside the bundle at `Contents/Resources/patches_presets/`. They
// are written by this project, not filled in by users: a preset is a reviewed
// claim that this combination boots. `standard` is what every VM gets; any other
// preset is opted into explicitly with `--preset`.
//
// A per-VM override does not edit a preset — it narrows one, through
// ``VPhonePatchSelection/blocking(_:)``.

import Foundation

/// Where a plan finds a patch set.
///
/// Both cases name the identifier the preset expects. An external set is loaded
/// from a path, and the manifest found there must declare that identifier —
/// otherwise replacing the file at that path would silently change which patches
/// a preset applies.
public enum VPhonePatchSetReference: Sendable, Hashable {
    /// A set built into the bundle, named by identifier.
    case bundled(String)
    /// A `.vphonepatchset` outside the bundle, at a path on the host.
    ///
    /// Root `cfw install` refuses these outright: an external set reaches a
    /// privileged run only after the Launchpad helper has imported it and pinned
    /// its cdhash.
    case external(identifier: String, path: String)
}

public extension VPhonePatchSetReference {
    /// The set identity this reference expects, whichever way it points at it.
    var identifier: String {
        switch self {
        case let .bundled(identifier): identifier
        case let .external(identifier, _): identifier
        }
    }
}

public struct VPhonePatchPreset: Sendable, Hashable, Codable, Identifiable {
    /// Selection identity, passed to `--preset`.
    public var identifier: String
    /// Display name for a picker.
    public var title: String
    /// One line on what the preset is for.
    public var summary: String
    /// The sets this preset draws patches from, in listed order.
    public var patchSets: [VPhonePatchSetReference]
    /// Which of the declared patches are on.
    public var selection: VPhonePatchSelection
    /// Free-form knobs a patch set reads, such as a size override.
    public var parameters: [String: String]

    public var id: String {
        identifier
    }

    public init(
        identifier: String,
        title: String,
        summary: String = "",
        patchSets: [VPhonePatchSetReference],
        selection: VPhonePatchSelection = .all,
        parameters: [String: String] = [:],
    ) {
        self.identifier = identifier
        self.title = title
        self.summary = summary
        self.patchSets = patchSets
        self.selection = selection
        self.parameters = parameters
    }

    /// The identifier a VM gets when nothing asked for another preset.
    public static let standardIdentifier = "standard"

    /// The identifier an Apple TV guest gets when nothing asked for another
    /// preset: standard without the iOS payloads tvOS has no port of.
    public static let tvOSIdentifier = "tvos"

    /// The identifier of the preset that patches no boot chain, kernel or TXM and
    /// customises the system before the restore instead.
    public static let minimalIdentifier = "minimal"

    /// The preset an Apple TV 4K guest gets: the TV preset for an arm64e
    /// userland taken from the device's OTA.
    public static let tvOS4KIdentifier = "tvos-4k"

    /// HomePod mini's own arm64e TVOS IPSW, without an OTA userland swap.
    public static let homeViewIdentifier = "homeview"

    public static let homePodMiniIdentifier = "homepod-mini"
    /// The identifier an Apple Watch guest gets: ``minimalIdentifier`` for a
    /// watch, which presents its own board.
    public static let watchOSIdentifier = "watchos"

    /// Whether this is the preset a VM gets by default.
    public var isStandard: Bool {
        identifier == Self.standardIdentifier
    }

    /// True when the preset draws on a set from outside the bundle. Root
    /// `cfw install` refuses such a preset unless the set was imported first.
    public var usesExternalPatchSets: Bool {
        patchSets.contains {
            if case .external = $0 {
                true
            } else {
                false
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier = "Identifier"
        case title = "Title"
        case summary = "Summary"
        case patchSets = "PatchSets"
        case selection = "Selection"
        case parameters = "Parameters"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        patchSets = try container.decode([VPhonePatchSetReference].self, forKey: .patchSets)
        selection = try container.decodeIfPresent(VPhonePatchSelection.self, forKey: .selection) ?? .all
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        guard !identifier.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: container,
                debugDescription: "A preset identifier is what --preset names; it cannot be empty",
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(title, forKey: .title)
        if !summary.isEmpty {
            try container.encode(summary, forKey: .summary)
        }
        try container.encode(patchSets, forKey: .patchSets)
        try container.encode(selection, forKey: .selection)
        if !parameters.isEmpty {
            try container.encode(parameters, forKey: .parameters)
        }
    }
}

// MARK: - Reference Coding

extension VPhonePatchSetReference: Codable {
    private enum Kind: String, Codable {
        case bundled = "Bundled"
        case external = "External"
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "Kind"
        case identifier = "Identifier"
        case path = "Path"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .bundled:
            self = try .bundled(container.decode(String.self, forKey: .identifier))
        case .external:
            self = try .external(
                identifier: container.decode(String.self, forKey: .identifier),
                path: container.decode(String.self, forKey: .path),
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bundled(identifier):
            try container.encode(Kind.bundled, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        case let .external(identifier, path):
            try container.encode(Kind.external, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
            try container.encode(path, forKey: .path)
        }
    }
}

extension VPhonePatchSetReference: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .bundled(identifier): identifier
        case let .external(identifier, path): "\(identifier) (external, \(path))"
        }
    }
}

// MARK: - Plist IO

public extension VPhonePatchPreset {
    /// The bundle subdirectory holding the shipped presets.
    static let resourceDirectoryName = "patches_presets"

    /// Read every preset in a `patches_presets` directory, sorted by identifier
    /// with `standard` first so a picker's order is stable.
    static func readAll(fromDirectory directory: URL) throws -> [VPhonePatchPreset] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var presets: [VPhonePatchPreset] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            let url = directory.appendingPathComponent(name)
            try presets.append(decode(Data(contentsOf: url)))
        }
        return presets.sorted {
            if $0.isStandard != $1.isStandard {
                return $0.isStandard
            }
            return $0.identifier < $1.identifier
        }
    }

    static func decode(_ data: Data) throws -> VPhonePatchPreset {
        try PropertyListDecoder().decode(VPhonePatchPreset.self, from: data)
    }

    func encodedPlist() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }
}
