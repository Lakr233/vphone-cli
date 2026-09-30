// VPhonePatchSetManifest.swift — What one patch set declares about itself.
//
// Every patch set — the ones built into the bundle and the ones loaded from a
// `.vphonepatchset` — carries this as `Contents/Resources/Manifest.plist`. It is
// read before any code from the set runs, so the resolver can reject a broken
// combination without loading a single patch.

import Foundation

public struct VPhonePatchSetManifest: Sendable, Hashable, Codable, Identifiable {
    /// Reverse-DNS identity, unique across a plan. Also an implicit capability.
    public var identifier: String
    /// Display name for a preset picker.
    public var name: String
    /// The set's own version, for logs and bug reports.
    public var version: String
    /// One line on what the set is for.
    public var summary: String
    /// The PatchKit API this set needs. A newer requirement is refused.
    public var minimumPatchKitVersion: VPhoneVersion
    /// Every patch the set can apply, in the order it applies them.
    public var patches: [VPhonePatchDeclaration]
    /// Capabilities that must be present, provided by this set or another.
    public var requires: [String]
    /// Capability names this set supplies beyond its own identifier.
    public var provides: [String]
    /// Sets or capabilities this one cannot sit beside. Enforced symmetrically:
    /// either side naming the other is a conflict, so a set need not be patched
    /// to learn about a newer rival.
    public var conflictsWith: [String]
    /// Sets or capabilities that must run before this one, when both are present.
    public var after: [String]

    public var id: String {
        identifier
    }

    public init(
        identifier: String,
        name: String,
        version: String = "1.0",
        summary: String = "",
        minimumPatchKitVersion: VPhoneVersion = VPhoneVersion(major: 1, minor: 0),
        patches: [VPhonePatchDeclaration],
        requires: [String] = [],
        provides: [String] = [],
        conflictsWith: [String] = [],
        after: [String] = [],
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.summary = summary
        self.minimumPatchKitVersion = minimumPatchKitVersion
        self.patches = patches
        self.requires = requires
        self.provides = provides
        self.conflictsWith = conflictsWith
        self.after = after
    }

    /// The set's identity plus everything it declares it provides.
    public var capabilities: Set<String> {
        Set(provides).union([identifier])
    }

    /// The declaration owning `recordIdentifier`, if this set emits it.
    public func declaration(coveringRecord recordIdentifier: String) -> VPhonePatchDeclaration? {
        // Longest identifier first, so `kernel-cfw-debugger.ret` is attributed to
        // `kernel-cfw-debugger` rather than to a shorter umbrella.
        patches
            .filter { $0.covers(recordIdentifier: recordIdentifier) }
            .max { $0.identifier.count < $1.identifier.count }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier = "Identifier"
        case name = "Name"
        case version = "Version"
        case summary = "Summary"
        case minimumPatchKitVersion = "MinimumPatchKitVersion"
        case patches = "Patches"
        case requires = "Requires"
        case provides = "Provides"
        case conflictsWith = "ConflictsWith"
        case after = "After"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        minimumPatchKitVersion = try container.decodeIfPresent(
            VPhoneVersion.self,
            forKey: .minimumPatchKitVersion,
        ) ?? VPhoneVersion(major: 1, minor: 0)
        patches = try container.decode([VPhonePatchDeclaration].self, forKey: .patches)
        requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
        provides = try container.decodeIfPresent([String].self, forKey: .provides) ?? []
        conflictsWith = try container.decodeIfPresent([String].self, forKey: .conflictsWith) ?? []
        after = try container.decodeIfPresent([String].self, forKey: .after) ?? []

        guard !identifier.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: container,
                debugDescription: "A patch set identifier is what a preset names; it cannot be empty",
            )
        }
        var seen = Set<String>()
        for patch in patches where !seen.insert(patch.identifier).inserted {
            throw DecodingError.dataCorruptedError(
                forKey: .patches,
                in: container,
                debugDescription: "\(identifier) declares \(patch.identifier) twice",
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        if !summary.isEmpty {
            try container.encode(summary, forKey: .summary)
        }
        try container.encode(minimumPatchKitVersion, forKey: .minimumPatchKitVersion)
        try container.encode(patches, forKey: .patches)
        if !requires.isEmpty {
            try container.encode(requires, forKey: .requires)
        }
        if !provides.isEmpty {
            try container.encode(provides, forKey: .provides)
        }
        if !conflictsWith.isEmpty {
            try container.encode(conflictsWith, forKey: .conflictsWith)
        }
        if !after.isEmpty {
            try container.encode(after, forKey: .after)
        }
    }
}

// MARK: - Plist IO

public extension VPhonePatchSetManifest {
    /// The path a patch-set bundle keeps its manifest at.
    static let resourceName = "Manifest.plist"

    /// Read a manifest from a `.vphonepatchset` bundle directory.
    static func read(fromBundle bundle: URL) throws -> VPhonePatchSetManifest {
        let url = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(resourceName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> VPhonePatchSetManifest {
        try PropertyListDecoder().decode(VPhonePatchSetManifest.self, from: data)
    }

    /// Encode as an XML plist, the form a patch set checks into source control.
    func encodedPlist() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }
}
