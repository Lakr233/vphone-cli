import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// The host's MIL sources for the guest's TextRecognition E5 models.
///
/// The iPhone firmware ships each E5 model compiled for its own Neural Engine
/// only (`cr_td_model_v3_e5.mlmodelc.bundle/H18.bundle`), without the
/// `model.mil` it was built from; the `H18.e5` records the `espressoc`
/// invocation over that file. On the paravirtual Neural Engine, E5RT looks for
/// the host's family (H14 and its variants on an M2), then compiles
/// `<bundle>/model.mil`, which is absent. macOS ships the same models as MIL
/// and compiles them per process, so the host has exactly what is missing.
///
/// This adds the host's `model.mil` and the weight files it reads beside the
/// hardware binaries, and nothing else. A model is accepted only when every
/// file both sides carry (the recognizers' code maps and positional encodings)
/// is byte-identical and each of the guest's hardware descriptors names every
/// input and output the host model declares. Every model is checked before
/// anything is written. What was written is journaled, so turning the patch off
/// removes exactly that. See `DyldSharedCacheTextRecognitionANEPatcher` for the
/// selection change that makes TextRecognition use these models.
public enum CustomFirmwareTextRecognitionModels {
    public static let guestFramework = "System/Library/PrivateFrameworks/TextRecognition.framework"
    public static let hostResources = "/System/Library/PrivateFrameworks/TextRecognition.framework/Resources"
    public static let journalPath = "usr/share/vphone/TextRecognitionModels.plist"
    static let program = "model.mil"
    static let bundleSuffix = "_e5.mlmodelc.bundle"

    public struct Plan: Sendable {
        /// System-relative path to contents.
        public let files: [String: Data]
        /// System-relative folders the files are put in that vphone creates.
        public let directories: [String]
        /// Models whose sources are added.
        public let models: [String]
    }

    /// What vphone added, relative to the system volume.
    public struct Journal: Equatable, Sendable {
        public var files: [String]
        public var directories: [String]

        public init(files: [String], directories: [String]) {
            self.files = files
            self.directories = directories
        }
    }

    // MARK: - Planning

    /// Check the host's models against the guest's and read what to add.
    /// Nothing is written.
    public static func plan(
        system: VPhoneConfinedDirectory,
        host: VPhoneConfinedDirectory,
        journal: Journal?,
    ) throws -> Plan {
        let ownedFiles = Set(journal?.files ?? [])
        let ownedDirectories = Set(journal?.directories ?? [])
        guard try system.isDirectory(guestFramework) else {
            throw PatcherError.fileNotFound("/\(guestFramework)")
        }
        let framework = try system.directory(guestFramework)
        let bundles = try framework.entries().filter {
            try $0.hasSuffix(bundleSuffix) && framework.isDirectory($0)
        }
        guard !bundles.isEmpty else {
            throw PatcherError.patchSiteNotFound("TextRecognition has no E5 models")
        }

        var files: [String: Data] = [:]
        var directories: Set<String> = []
        var models: [String] = []
        for name in bundles {
            let path = "\(guestFramework)/\(name)"
            let guest = try framework.directory(name)
            let entries = try guest.entries()
            if entries.contains(program), !ownedFiles.contains("\(path)/\(program)") {
                // The firmware already carries this model's source.
                continue
            }
            let variants = try entries.filter { try $0.hasPrefix("H") && $0.hasSuffix(".bundle") && guest.isDirectory($0) }
            guard !variants.isEmpty else {
                throw PatcherError.invalidFormat("\(name) has neither a hardware binary nor MIL")
            }
            guard try host.isDirectory(name) else {
                throw PatcherError.fileNotFound("\(hostResources)/\(name)")
            }
            let source = try host.directory(name)
            let mil = try source.readData(program)
            let install = [program] + (try weightPaths(in: mil, model: name))

            for entry in entries where !install.contains(entry) {
                guard try guest.isRegularFile(entry), try source.isRegularFile(entry) else { continue }
                guard try guest.readData(entry) == source.readData(entry) else {
                    throw PatcherError.patchVerificationFailed("\(name)/\(entry) differs from the host's; the host has another version of this model")
                }
            }
            let names = try interface(of: source.readData("metadata.json"), model: name)
            for variant in variants {
                let descriptor = try guest.readData("\(variant)/\(variant.dropLast(".bundle".count)).e5")
                for feature in names where descriptor.range(of: flatBufferString(feature)) == nil {
                    throw PatcherError.patchVerificationFailed("\(name)/\(variant) does not name the host model's \(feature)")
                }
            }

            for relative in install {
                if try guest.exists(relative), !ownedFiles.contains("\(path)/\(relative)") {
                    throw PatcherError.patchVerificationFailed("\(name)/\(relative) already exists and was not added by vphone")
                }
                files["\(path)/\(relative)"] = try source.readData(relative)
                var parent = (relative as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    if try !guest.exists(parent) || ownedDirectories.contains("\(path)/\(parent)") {
                        directories.insert("\(path)/\(parent)")
                    }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            models.append(name)
        }
        return Plan(files: files, directories: directories.sorted(), models: models)
    }

    /// The files a MIL program reads through `@model_path`, relative to its bundle.
    static func weightPaths(in mil: Data, model: String) throws -> [String] {
        let text = String(decoding: mil, as: UTF8.self)
        let marker = "@model_path/"
        var paths: Set<String> = []
        var cursor = text.startIndex
        while let start = text.range(of: marker, range: cursor ..< text.endIndex) {
            guard let end = text[start.upperBound...].firstIndex(of: "\"") else {
                throw PatcherError.invalidFormat("\(model)/\(program) has an unterminated @model_path")
            }
            let path = String(text[start.upperBound ..< end])
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw PatcherError.invalidFormat("\(model)/\(program) reads an unsupported path: \(path)")
            }
            paths.insert(path)
            cursor = end
        }
        return paths.sorted()
    }

    /// Input and output feature names from a compiled model's `metadata.json`.
    static func interface(of metadata: Data, model: String) throws -> [String] {
        let root = try JSONSerialization.jsonObject(with: metadata)
        guard let description = (root as? [[String: Any]])?.first ?? root as? [String: Any] else {
            throw PatcherError.invalidFormat("\(model)/metadata.json is not a model description")
        }
        func names(_ key: String) -> [String] {
            (description[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        let inputs = names("inputSchema"), outputs = names("outputSchema")
        guard !inputs.isEmpty, !outputs.isEmpty else {
            throw PatcherError.invalidFormat("\(model)/metadata.json declares no inputs or outputs")
        }
        return inputs + outputs
    }

    /// A FlatBuffers string: its length, its UTF-8 bytes and a terminating NUL.
    static func flatBufferString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var length = UInt32(bytes.count).littleEndian
        return Data(bytes: &length, count: 4) + bytes + Data([0])
    }

    // MARK: - Install and removal

    /// Write a checked plan, replacing what an earlier run added.
    public static func install(
        _ plan: Plan,
        system: VPhoneConfinedDirectory,
        journal: Journal?,
        owner: (uid: uid_t, gid: gid_t),
    ) throws {
        let next = Journal(files: plan.files.keys.sorted(), directories: plan.directories)
        let previous = journal ?? Journal(files: [], directories: [])
        // Journal everything this run may leave behind before touching it.
        try writeJournal(
            Journal(
                files: Array(Set(previous.files).union(next.files)).sorted(),
                directories: Array(Set(previous.directories).union(next.directories)).sorted(),
            ),
            system: system, owner: owner,
        )
        try remove(
            Journal(
                files: previous.files.filter { plan.files[$0] == nil },
                directories: previous.directories.filter { !next.directories.contains($0) },
            ),
            from: system,
        )
        for directory in next.directories {
            _ = try system.directory(directory, create: true, mode: 0o755)
            try system.setOwner(directory, uid: owner.uid, gid: owner.gid)
            try system.setMode(directory, 0o755)
        }
        for (path, data) in plan.files.sorted(by: { $0.key < $1.key }) {
            // E5RT keys every app's compiled models by the source file, not
            // its contents: rewriting an identical file recompiles them all.
            if try system.isRegularFile(path), try system.readData(path) == data { continue }
            try system.writeFile(path, contents: data, mode: 0o644, owner: owner)
        }
        try writeJournal(next, system: system, owner: owner)
    }

    /// Remove what the journal records, then the journal. Returns false when
    /// there is no journal.
    @discardableResult
    public static func uninstall(system: VPhoneConfinedDirectory) throws -> Bool {
        guard let journal = try readJournal(system: system) else { return false }
        try remove(journal, from: system)
        try system.removeItem(journalPath)
        // The journal's folder is vphone's; leave it only if something else uses it.
        let folder = (journalPath as NSString).deletingLastPathComponent
        if try system.isDirectory(folder), try system.directory(folder).entries().isEmpty {
            try system.removeItem(folder)
        }
        return true
    }

    static func remove(_ journal: Journal, from system: VPhoneConfinedDirectory) throws {
        for file in journal.files {
            try system.removeItem(file)
        }
        // Deepest first; a folder something else has since filled stays.
        for directory in journal.directories.sorted(by: { $0.count > $1.count }) {
            guard try system.isDirectory(directory), try system.directory(directory).entries().isEmpty else { continue }
            try system.removeItem(directory)
        }
    }

    // MARK: - Journal

    public static func readJournal(system: VPhoneConfinedDirectory) throws -> Journal? {
        guard try system.exists(journalPath) else { return nil }
        guard let root = try PropertyListSerialization.propertyList(from: system.readData(journalPath), format: nil) as? [String: Any],
              let files = root["Files"] as? [String], let directories = root["Directories"] as? [String]
        else { throw PatcherError.invalidFormat("/\(journalPath) is not a TextRecognition model journal") }
        // A journal only ever names paths inside the E5 bundles.
        for path in files + directories {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix(guestFramework + "/"), components.count > 5,
                  components[4].hasSuffix(bundleSuffix),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw PatcherError.invalidFormat("/\(journalPath) names a path outside the E5 models: \(path)") }
        }
        return Journal(files: files, directories: directories)
    }

    static func writeJournal(_ journal: Journal, system: VPhoneConfinedDirectory, owner: (uid: uid_t, gid: gid_t)) throws {
        _ = try system.directory((journalPath as NSString).deletingLastPathComponent, create: true, mode: 0o755)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Files": journal.files, "Directories": journal.directories],
            format: .xml, options: 0,
        )
        try system.writeFile(journalPath, contents: data, mode: 0o644, owner: owner)
    }
}
