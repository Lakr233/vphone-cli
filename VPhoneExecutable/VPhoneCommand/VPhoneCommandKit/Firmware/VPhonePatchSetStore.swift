// VPhonePatchSetStore.swift — Where an imported `.vphonepatchset` lives.
//
// The store is `~/.vphone/patchsets` (or `$VPHONE_ROOT/patchsets`). Importing a
// set copies it there under its own identifier and ad hoc signs it if it arrived
// unsigned, which is the one step that turns "a bundle somebody built" into "a
// bundle this tool will load".
//
// What the store is not: a trust boundary. A signature is re-verified from disk on
// every load, and that is what catches a set altered since it was signed. The
// recorded cdhash here is provenance — `patchset list` prints whether the set on
// disk is still the one that was imported — and the strong, pinned form of that
// check belongs to the Launchpad helper, which is the only component that acts as
// root. Root `cfw install` loads no external set at all, so a same-user rewrite of
// a bundle in this store crosses no privilege boundary that a rewrite of the preset
// naming it would not cross anyway.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

// MARK: - Record

/// What was imported, so `patchset list` can say whether it still matches.
public struct VPhoneImportedPatchSet: Codable, Sendable, Hashable {
    public var identifier: String
    public var name: String
    public var version: String
    public var codeDirectoryHash: String
    public var importedAt: Date

    private enum CodingKeys: String, CodingKey {
        case identifier = "Identifier"
        case name = "Name"
        case version = "Version"
        case codeDirectoryHash = "CDHash"
        case importedAt = "ImportedAt"
    }
}

// MARK: - Store

public enum VPhonePatchSetStore {
    public static let directoryName = "patchsets"
    public static let recordFileName = "Imported.plist"

    /// `~/.vphone/patchsets`, created on demand.
    public static func directory() -> URL {
        VPhoneResources.userDataRoot().appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Where a set with this identifier is kept.
    public static func url(forIdentifier identifier: String) -> URL {
        directory().appendingPathComponent(
            "\(identifier).\(VPhonePatchSetBundle.pathExtension)",
            isDirectory: true,
        )
    }

    // MARK: Records

    public static func imported() -> [String: VPhoneImportedPatchSet] {
        let url = directory().appendingPathComponent(recordFileName)
        guard let data = try? Data(contentsOf: url),
              let records = try? PropertyListDecoder().decode(
                  [String: VPhoneImportedPatchSet].self,
                  from: data,
              )
        else { return [:] }
        return records
    }

    private static func write(_ records: [String: VPhoneImportedPatchSet]) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        try encoder.encode(records).write(
            to: directory().appendingPathComponent(recordFileName),
            options: .atomic,
        )
    }

    // MARK: Contents

    /// Every set in the store, whether or not it has a record.
    ///
    /// The directory is the truth; a set whose record went missing still loads, it
    /// just cannot be checked against what was imported.
    public static func contents() throws -> [VPhonePatchSetBundle] {
        let directory = directory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var sets: [VPhonePatchSetBundle] = []
        for name in names.sorted()
            where name.hasSuffix("." + VPhonePatchSetBundle.pathExtension)
        {
            try sets.append(VPhonePatchSetBundle.inspect(
                at: directory.appendingPathComponent(name, isDirectory: true),
            ))
        }
        return sets
    }

    // MARK: Import

    /// Validate `source`, ad hoc sign it if it is unsigned, and copy it into the
    /// store under the identifier its manifest declares.
    ///
    /// The manifest is checked before anything is copied and before anything is
    /// signed — including the rule that every declared patch targets the boot
    /// chain — so a set that could never be loaded is never installed. Signing
    /// happens on the copy in the store, never on the file the user pointed at.
    ///
    /// No code from the set runs here. Importing is not loading.
    @discardableResult
    public static func importSet(from source: URL, replacing: Bool = false) throws -> VPhonePatchSetBundle {
        let candidate = try VPhonePatchSetBundle.inspect(at: source)
        try candidate.validate(expecting: nil, requireSignature: false)

        let destination = url(forIdentifier: candidate.manifest.identifier)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            guard replacing else {
                throw VPhonePatchSetStoreError.alreadyImported(
                    identifier: candidate.manifest.identifier,
                    path: destination.path,
                )
            }
            try manager.removeItem(at: destination)
        }
        try manager.createDirectory(at: directory(), withIntermediateDirectories: true)
        try manager.copyItem(at: candidate.url, to: destination)

        let installed = try VPhonePatchSetBundle.inspect(at: destination)
        if (try? installed.requireValidSignature()) == nil {
            try adHocSign(destination)
        }
        // Whatever we just did, the set has to pass the check the loader will make.
        try installed.validate(expecting: candidate.manifest.identifier)

        var records = imported()
        records[installed.manifest.identifier] = try VPhoneImportedPatchSet(
            identifier: installed.manifest.identifier,
            name: installed.manifest.name,
            version: installed.manifest.version,
            codeDirectoryHash: installed.codeDirectoryHash(),
            importedAt: Date(),
        )
        try write(records)
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: destination)
        return installed
    }

    public static func remove(identifier: String) throws {
        let url = url(forIdentifier: identifier)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VPhonePatchSetStoreError.notImported(identifier: identifier)
        }
        try FileManager.default.removeItem(at: url)
        var records = imported()
        records[identifier] = nil
        try write(records)
    }

    // MARK: Signing

    /// `codesign --force --sign -`, the same ad hoc seal the rest of this project
    /// puts on a binary it produced. `/usr/bin/codesign` is part of macOS, not of
    /// Xcode, so this holds on a machine with no developer tools.
    ///
    /// No `--deep`: signing a bundle seals its resources, which is exactly what a
    /// set straight out of Xcode is missing — the linker ad hoc signs the Mach-O but
    /// writes no `CodeResources`, so `codesign --verify` answers "code has no
    /// resources but signature indicates they must be present". One pass over the
    /// bundle fixes that, and `--deep` for signing is discouraged by Apple.
    private static func adHocSign(_ url: URL) throws {
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["--force", "--sign", "-", url.path],
        )
        guard result.succeeded else {
            throw VPhonePatchSetStoreError.signingFailed(
                path: url.path,
                reason: (result.stderr + result.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
            )
        }
    }
}

// MARK: - Errors

public enum VPhonePatchSetStoreError: Error, CustomStringConvertible, Sendable {
    case alreadyImported(identifier: String, path: String)
    case notImported(identifier: String)
    case signingFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .alreadyImported(identifier, path):
            "\(identifier) is already imported at \(path). Pass --replace to overwrite it."
        case let .notImported(identifier):
            "No imported patch set with identifier \(identifier)"
        case let .signingFailed(path, reason):
            "Could not ad hoc sign \(path): \(reason)"
        }
    }
}
