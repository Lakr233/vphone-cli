import Foundation
import Observation
import SwiftUI

// MARK: - Import

/// Puts an IPSW the user already has into the shared IPSW cache, dropped on
/// the window or opened with Launchpad, so New Machine uses it rather than
/// downloading it.
///
/// `fw prepare` finds a cached IPSW only under the name it gives the file it
/// downloads from a catalog URL (`VPhoneLaunchpadIPSW.cacheName`), so the
/// IPSW is matched to the default Core Bundle's `fw catalog` by its manifest:
/// the same build, and a product type in common or, for cloudOS, a catalog
/// cloudOS. It is copied to a `.partial` file first, as a download is, and
/// renamed once complete; a cancelled or failed copy leaves nothing behind.
@MainActor
@Observable
final class VPhoneLaunchpadIPSWImport {
    struct Copy: Identifiable {
        let id = UUID()
        let fileName: String
        var fraction: Double = 0
    }

    struct Outcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// The copy under way; the progress sheet shows while it is set.
    private(set) var copy: Copy?
    /// What the last import did, for the alert that follows it.
    var outcome: Outcome?
    private var task: Task<Void, Never>?
    private var queue: [URL] = []

    static func isIPSW(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "ipsw"
    }

    /// Imports the IPSWs one after another, after any already waiting.
    func register(_ files: [URL], model: VPhoneLaunchpadModel) {
        queue += files.filter(Self.isIPSW)
        guard task == nil else {
            return
        }
        task = Task {
            while !queue.isEmpty {
                let file = queue.removeFirst()
                outcome = await importIPSW(file, model: model)
                // The next waits for this one's alert to be read.
                while outcome != nil, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            task = nil
        }
    }

    /// Stops the copy and drops the IPSWs waiting after it.
    func cancel() {
        queue = []
        task?.cancel()
    }

    // MARK: Steps

    private func importIPSW(_ file: URL, model: VPhoneLaunchpadModel) async -> Outcome? {
        let failure = String(localized: "Unable to Add \(file.lastPathComponent)")
        let facts: VPhoneLaunchpadIPSW
        do {
            facts = try await Self.read(file)
        } catch {
            return Outcome(title: failure, message: String(localized: "It is not an IPSW, or its BuildManifest cannot be read."))
        }
        let title = facts.title ?? file.lastPathComponent
        guard let catalog = await VPhoneLaunchpadNewMachineView.catalog(model) else {
            return Outcome(title: failure, message: String(localized: "The firmware catalog could not be read. Install a Core Bundle in Core Bundle, then try again."))
        }
        guard let source = Self.catalogURL(for: facts, named: file.lastPathComponent, in: catalog) else {
            return Outcome(title: failure, message: String(localized: "\(title) is not in the firmware catalog, so New Machine cannot use it from the IPSW cache. Choose it as a custom IPSW in New Machine instead."))
        }
        let directory = VPhoneLaunchpadIPSWCache.sharedDirectory
        let destination = directory.appendingPathComponent(VPhoneLaunchpadIPSW.cacheName(for: source))
        if FileManager.default.fileExists(atPath: destination.path) {
            return Outcome(title: String(localized: "\(title) Is Already Downloaded"), message: String(localized: "New Machine uses the copy in the IPSW cache."))
        }
        copy = Copy(fileName: file.lastPathComponent)
        defer { copy = nil }
        do {
            try await Self.copy(file, to: destination, in: directory) { [weak self] fraction in
                Task { @MainActor in self?.copy?.fraction = fraction }
            }
        } catch is CancellationError {
            return nil
        } catch {
            return Outcome(title: failure, message: error.localizedDescription)
        }
        return Outcome(title: String(localized: "\(title) Added"), message: String(localized: "New Machine uses it from the IPSW cache without downloading it."))
    }

    @concurrent
    private static func read(_ file: URL) async throws -> VPhoneLaunchpadIPSW {
        try VPhoneLaunchpadIPSW.read(file)
    }

    /// The catalog URL whose download this IPSW is: one with the same file
    /// name, else one whose name gives the same build and a product type in
    /// common, or a catalog cloudOS of the same build for a cloudOS IPSW.
    nonisolated static func catalogURL(
        for facts: VPhoneLaunchpadIPSW,
        named fileName: String,
        in catalog: VPhoneLaunchpadFirmwareCatalog,
    ) -> URL? {
        let pairings = catalog.guests.flatMap(\.pairings)
        let images = facts.kind == .cloudOS ? pairings.map(\.recommendedCloudOS) : pairings.map(\.ios)
        let urls = images.compactMap { URL(string: $0.url) }
        if let same = urls.first(where: { $0.lastPathComponent == fileName }) {
            return same
        }
        return urls.first { url in
            guard let named = VPhoneLaunchpadIPSW(fileName: url.lastPathComponent), named.build == facts.build else {
                return false
            }
            return facts.kind == .cloudOS || named.productTypes.isEmpty
                || !Set(named.productTypes).isDisjoint(with: facts.productTypes)
        }
    }

    /// Copies in 8 MB pieces, checking for cancellation between them.
    @concurrent
    private static func copy(
        _ file: URL,
        to destination: URL,
        in directory: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let pending = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard fm.createFile(atPath: pending.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: pending) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: pending)
        defer { try? output.close() }
        let total = try max(1, input.seekToEnd())
        try input.seek(toOffset: 0)
        var done: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty else {
                break
            }
            try output.write(contentsOf: chunk)
            done += UInt64(chunk.count)
            progress(Double(done) / Double(total))
        }
        try output.synchronize()
        try fm.moveItem(at: pending, to: destination)
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: destination.path)
    }
}

// MARK: - Progress

/// The copy's progress, with Cancel.
struct VPhoneLaunchpadIPSWImportView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model

    var body: some View {
        let importer = model.ipswImport
        VPhoneLaunchpadSheet(Text("Adding IPSW")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Copying \(importer.copy?.fileName ?? "") into the IPSW cache…")
                    .lineLimit(2)
                    .truncationMode(.middle)
                ProgressView(value: importer.copy?.fraction ?? 0)
            }
            .padding(16)
        } actions: {
            Button("Cancel") { importer.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
