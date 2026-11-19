// FirmwarePipelineOriginals.swift — The untouched copy of each boot-chain file.
//
// `fw patch` rewrites a firmware component in place: it loads the file, patches
// the payload, saves over the same path. Run it twice and the second run hands
// the patchers the first run's output, they find none of the shapes they already
// replaced, and the component fails outright — `Patch site not found: iBSS`.
// `fw prepare` refuses to re-extract over an existing restore tree, so there was
// no way back either: a VM could be patched once and never again, and editing its
// `PatchSelection.plist` to turn a patch off changed nothing on disk.
//
// The answer lives here. The first run copies each boot-chain file into
// `<vmDirectory>/FirmwareOriginals/`, mirroring its path, before anything is
// written; every run after that patches those bytes rather than the ones it wrote
// last time. `fw patch` is then idempotent by construction — same VM, same plan,
// same file on disk however many times it runs — and a plan that turns a
// component's patches off puts the unpatched image back instead of leaving the
// previous run's patches stranded with nothing selecting them.
//
// The stash is a direct child of the VM directory, never of the restore tree, so
// neither `findRestoreDirectory` (which matches a directory name containing
// "Restore") nor a component glob (rooted at the restore tree, or non-recursive in
// the VM root) can resolve a component to its own pristine copy.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

extension FirmwarePipeline {
    // MARK: - Locations

    /// The stash directory's name inside the VM bundle.
    ///
    /// Defined in ``VPhoneBundleOperations`` because `fw prepare` and bundle export
    /// have to agree about it — see the declaration there.
    static let originalsDirectoryName = VPhoneBundleOperations.firmwareOriginalsDirectoryName

    var originalsDirectory: URL {
        vmDirectory.appendingPathComponent(Self.originalsDirectoryName)
    }

    /// Where `fileURL`'s untouched bytes belong: the same path, re-rooted in the stash.
    ///
    /// Nil for a file outside the VM directory, which the stash cannot describe and
    /// so does not claim. Callers read nil as "no original for this one" rather than
    /// as an error, which leaves a pipeline pointed somewhere it does not own
    /// behaving exactly as it did before originals existed.
    func originalURL(for fileURL: URL) -> URL? {
        // Both sides resolved: the VM directory may arrive as `/var/...` while the
        // directory scan that produced `fileURL` returns the `/private/var/...`
        // realpath, and an unresolved prefix test would then reject every component.
        let root = vmDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let file = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix) else { return nil }
        let relative = String(file.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix(Self.originalsDirectoryName + "/") else { return nil }
        return originalsDirectory.appendingPathComponent(relative)
    }

    // MARK: - Reading

    /// Whether `fileURL` or its stashed original is there to read.
    func hasPristineInput(for fileURL: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: fileURL.path) || originalURL(for: fileURL).map { fm.fileExists(atPath: $0.path) } == true
    }

    /// The file this run should take `fileURL`'s bytes from, stashing them first
    /// if no earlier run did.
    ///
    /// `created` says whether this run is the one that made the copy, which is the
    /// only case where the stashed bytes have not yet been shown to be pristine: on
    /// a VM patched by a build that kept no originals, the "original" is really the
    /// old run's output. The caller undoes the copy if patching then fails.
    func pristineInput(for fileURL: URL) throws -> (url: URL, created: Bool) {
        guard let stashURL = originalURL(for: fileURL) else { return (fileURL, false) }
        let fm = FileManager.default
        if fm.fileExists(atPath: stashURL.path) {
            return (stashURL, false)
        }
        try fm.createDirectory(at: stashURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fileURL, to: stashURL)
        return (stashURL, true)
    }

    // MARK: - Writing

    /// Put the untouched image back at `fileURL`, and say whether that wrote anything.
    ///
    /// False when there is no stash, and false when the file already matches it, so
    /// a component nobody has ever patched keeps the modification date the restore
    /// gave it instead of being rewritten on every run.
    @discardableResult
    func restorePristine(to fileURL: URL) throws -> Bool {
        let fm = FileManager.default
        guard let stashURL = originalURL(for: fileURL),
              fm.fileExists(atPath: stashURL.path)
        else { return false }
        if try filesMatch(stashURL, fileURL) {
            return false
        }
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        try fm.copyItem(at: stashURL, to: fileURL)
        return true
    }

    /// Drop a stash this run created, so bytes that turned out not to be pristine
    /// never become the baseline every later run patches from.
    func discardStash(for fileURL: URL) {
        guard let stashURL = originalURL(for: fileURL) else { return }
        try? FileManager.default.removeItem(at: stashURL)
    }

    // MARK: - Diagnostics

    /// The failure to report when a component would not patch and this run was the
    /// one that stashed its supposed original.
    ///
    /// Only `patchSiteNotFound` is rewritten. Every other failure — a malformed
    /// container, a verification mismatch — means what it says whether or not an
    /// original was kept, and is passed through untouched.
    func staleFirmwareError(component: String, underlying: any Error) -> any Error {
        guard let patcherError = underlying as? PatcherError,
              case .patchSiteNotFound = patcherError
        else { return underlying }
        return PatcherError.patchSiteNotFound(
            """
            \(component): no patch site in a file this run had to take as unpatched.

            This VM was patched by a build that kept no copy of its original boot \
            chain, so \(component) on disk is already patched and cannot be patched \
            again. Nothing was changed.

            Delete the VM's *_Restore directory and run `vphone-cli fw prepare` again \
            to lay down a clean boot chain. From then on every `fw patch` re-patches \
            the originals kept in \(Self.originalsDirectoryName)/ and can be re-run \
            as often as you like.
            """,
        )
    }

    // MARK: - Comparison

    /// Whether two files hold the same bytes.
    ///
    /// Both mappings are scoped to this call so they are gone before any caller
    /// writes: a mapped buffer that outlives the file it came from takes SIGBUS on
    /// the next touch.
    private func filesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: rhs.path) else { return false }
        let lhsSize = try lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let rhsSize = try rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard lhsSize == rhsSize else { return false }
        return try Data(contentsOf: lhs, options: .mappedIfSafe)
            == Data(contentsOf: rhs, options: .mappedIfSafe)
    }
}
