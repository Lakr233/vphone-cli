// KernelCacheMixer.swift — A vphone600-capable kernelcache from the research board's.
//
// A cloudOS without vphone600 components ships only the research board's
// kernelcache, which lacks the iPhone virtualisation kexts (paravirtual GPU,
// touch, audio, FairPlay, ...). The mix:
//
//   1. extracts the donor kernelcache, the vphone600 one of the 26.4 beta
//      cloudOS, into a KDK, naming its stripped symbols from the recipe's map
//      (cached);
//   2. extracts the base, the cloudOS's `kernelcache.release.vresearch101`, the
//      same way;
//   3. keeps the recipe's bundle list: the base without its research-board-only
//      kexts, plus the donor's virtualisation kexts;
//   4. stages the bundles as a volume and links it with kmutil;
//   5. restores Apple's CPU subtype if the builder wrote another, branches
//      straight past the auth stubs macOS 27's builder keeps
//      (KernelCollectionStubCalls), checks every bundle was linked, and caches
//      the result.
//
// The maps are research results: BinDiff symbolication against a symbolicated
// KDK of the same family, plus verified fixes (see the README beside the
// recipes). Extraction runs natively in this process; kmutil still performs the link.

import Foundation
import Img4tool
import VPhoneArchiveKit
import VPhoneCoreKit
import VPhonePatchKit

public final class KernelCacheMixer {
    let recipes: KernelCacheRecipes
    let cacheDirectory: URL
    let verbose: Bool

    /// kmutil records the absolute path of every codeless kext, so the length of
    /// the volume's path decides where `__PRELINK_INFO` ends and every page after
    /// it. The link gives it the length of the build root Apple linked the base
    /// with, read from the base itself: the output then depends on nothing about
    /// this Mac, and the base rebuilt from its own extraction is Apple's
    /// kernelcache byte for byte, apart from the CPU subtype.
    static func buildRootLength(of payload: Data) throws -> Int {
        let key = Data("<key>_CodelessKextBundlePath</key>".utf8)
        guard let keyRange = payload.range(of: key),
              let open = payload.range(of: Data("<string>".utf8), in: keyRange.upperBound ..< payload.endIndex),
              let extensions = payload.range(of: Data("/System/Library/Extensions/".utf8), in: open.upperBound ..< min(open.upperBound + 2048, payload.endIndex))
        else {
            throw PatcherError.invalidFormat("the base kernelcache records no codeless kext path to take its build root from")
        }
        return extensions.lowerBound - open.upperBound
    }

    /// Bump when the steps change, so cached mixes are rebuilt.
    static let revision = 6

    /// Legacy source-compatibility constant. Native extraction does not read it.
    public static let ipswEnvironmentVariable = "VPHONE_IPSW"

    public init(
        recipes: KernelCacheRecipes,
        cacheDirectory: URL = VPhoneResources.userDataRoot().appending(path: "kernelcache"),
        verbose: Bool = true,
    ) {
        self.recipes = recipes
        self.cacheDirectory = cacheDirectory
        self.verbose = verbose
    }

    // MARK: - Identification

    /// A research board kernelcache to rebuild, and the guest it boots.
    public struct Input {
        /// The kernelcache as shipped (IM4P or decompressed).
        public let kernelcache: Data
        /// `VPhoneGuestDevice.Family` raw value of the guest.
        public let guest: String
        /// The VM's restore tree, which holds a donor the guest's IPSW ships.
        public let restoreTree: URL

        public init(kernelcache: Data, guest: String, restoreTree: URL) {
            self.kernelcache = kernelcache
            self.guest = guest
            self.restoreTree = restoreTree
        }
    }

    public func base(for input: Input) throws -> KernelCacheBase {
        if let base = try recipes.base(forKernelcache: input.kernelcache, guest: input.guest) {
            return base
        }
        let supported = (try? recipes.bases().map { ($0.guest.map { "\($0) " } ?? "iOS ") + $0.id }.joined(separator: ", ")) ?? "none"
        throw PatcherError.invalidFormat(
            "this cloudOS has no vphone600 components, and no kernelcache recipe covers its research board kernelcache "
                + "(SHA-256 \(KernelCacheRecipes.sha256(input.kernelcache))) for this \(input.guest) guest "
                + "to rebuild with the virtualisation kexts; recipes exist for \(supported)",
        )
    }

    /// The recipe for the research board kernelcache `restoreDir` restores
    /// with. `fw prepare` asks, so a cloudOS no recipe covers is refused before
    /// anything is patched.
    public static func recipe(forRestoreTree restoreDir: URL) throws -> KernelCacheBase {
        try KernelCacheMixer(recipes: .locate(), verbose: false).base(for: input(forRestoreTree: restoreDir))
    }

    /// Throws what `mix` would for `restoreDir`, without building anything.
    /// `vm create` asks as soon as `fw prepare` finds the recipe, not at
    /// `fw patch` after the restores.
    public static func checkMixable(restoreTree restoreDir: URL) throws {
        let input = try Self.input(forRestoreTree: restoreDir)
        let mixer = try KernelCacheMixer(recipes: .locate(), verbose: false)
        let state = try mixer.state(for: input)
        guard state != .mixed else { return }
        guard try geteuid() == 0 || mixer.linksRemotely(input) else {
            throw PatcherError.invalidFormat(linkInstructions(staged: state == .staged))
        }
        if state == .missing, geteuid() == 0 {
            throw PatcherError.invalidFormat(linkInstructions(staged: false))
        }
    }

    static func input(forRestoreTree restoreDir: URL) throws -> Input {
        let path = try FirmwarePipeline.manifestComponentPath("RestoreKernelCache", in: restoreDir)
        let data = try Data(contentsOf: restoreDir.appending(path: path), options: .mappedIfSafe)
        return Input(kernelcache: data, guest: FirmwarePipeline.guestFamily(restoreDir: restoreDir), restoreTree: restoreDir)
    }

    // MARK: - Mix

    /// What becomes of a research board kernelcache in the cache.
    public enum State: Equatable, Sendable {
        /// Linked: `fw patch` takes it from the cache.
        case mixed
        /// Extracted and staged; linking it needs root.
        case staged
        /// Neither yet.
        case missing
    }

    public func state(for input: Input) throws -> State {
        let (_, paths) = try locations(for: input)
        if FileManager.default.fileExists(atPath: paths.mixed.path) {
            return .mixed
        }
        return Self.isStaged(paths.staged) ? .staged : .missing
    }

    /// The mixed kernelcache (an IMG4 `krnl` container) for a research board
    /// one: from the cache, linked from a staged volume (root), or staged and
    /// linked from a volume staged by the invoking user.
    public func mix(_ input: Input) throws -> Data {
        let (base, paths) = try locations(for: input)
        log("  [kc] base \(base.id) (\(base.productVersion)), donors \(base.donors.joined(separator: ", "))")
        if let data = try cachedMix(at: paths.mixed), !data.isEmpty {
            log("  [kc] using the cached mix \(paths.mixed.path)")
            return data
        }
        guard try geteuid() == 0 || linksRemotely(input) else {
            throw PatcherError.invalidFormat(Self.linkInstructions(staged: Self.isStaged(paths.staged)))
        }
        if !Self.isStaged(paths.staged) {
            try stage(input)
        }
        return try link(input)
    }

    /// Extracts both kernelcaches and stages the volume kmutil links, as the
    /// invoking user, entirely in process. Does nothing when the mix
    /// or its volume is already in the cache.
    /// The legacy ipsw argument is accepted as a no-op throughout 2.12.x.
    public func stage(_ input: Input, ipsw _: String? = nil) throws {
        let (base, paths) = try locations(for: input)
        guard !FileManager.default.fileExists(atPath: paths.mixed.path), !Self.isStaged(paths.staged) else { return }
        guard geteuid() != 0 else {
            throw PatcherError.invalidFormat("Stage the kernelcache as your user first with `vphone-cli fw kernelcache <vm>`, then run `sudo vphone-cli fw kernelcache <vm> --link-only`. Extraction writes to the invoking user's cache; root only links a staged volume.")
        }
        let location = try KernelCollectionBuilder.location(for: base)
        let donors = try base.donors.map { try recipes.donor(id: $0) }

        let fm = FileManager.default
        try? fm.removeItem(at: paths.staged)
        let work = paths.staged.appending(path: "work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("  [kc] staging in \(paths.staged.path)")

        let donorKDKs = try donors.map { try donorKDK($0, restoreTree: input.restoreTree) }
        let payload = try Self.payload(of: input.kernelcache)
        try Self.check(payload, base.kernel.decompressedSHA256, "decompressed \(base.kernel.file)")
        let decompressed = work.appending(path: "\(base.kernel.file).decompressed")
        try payload.write(to: decompressed)
        log("  [kc] extracting the base kernelcache with its symbol map")
        let baseKDK = try extract(
            kernelcache: decompressed, symbols: base.symbolsURL, kdk: base.kernel.kdk,
            into: work.appending(path: "base"),
        )

        let identifiers = try base.kextIdentifiers()
        let mixKDK = work.appending(path: "mix/\(base.kernel.kdk)")
        let sources = base.kextSources.map { source in
            base.donors.firstIndex(of: source).map { donorKDKs[$0] } ?? baseKDK
        }
        let pinned = try base.pinnedSources()
        let (removed, added) = try KernelCacheKDK.mix(
            base: baseKDK, sources: sources, wanted: identifiers, output: mixKDK, pinned: pinned,
        )
        let addedText = zip(donors, donorKDKs).map { "\(added[$1]?.count ?? 0) from \($0.id)" }.joined(separator: ", ")
        log("  [kc] mix: \(identifiers.count) kexts, \(removed.count) research board kexts removed, \(addedText)")
        try KernelCacheKDK.makeVolume(kdk: mixKDK, identifiers: identifiers, output: paths.staged.appending(path: "volume"))
        try fm.removeItem(at: work)
        try Data(KDKExtraction.revision.utf8).write(to: paths.staged.appending(path: "extractor.version"))
        try Data().write(to: paths.staged.appending(path: Self.stagedMarker))
        // Under sudo, so the user's later runs can replace it.
        if geteuid() == 0 {
            try VPhoneHostFilePermissions.makeAccessible(at: cacheDirectory)
        }
        if case .remote = location {
            log("  [kc] staged")
        } else {
            log("  [kc] staged; linking needs root")
        }
    }

    /// Links a staged volume, as root, and caches the result:
    /// the volume is copied into a directory only root can reach, with nothing
    /// in it that points outside, and kmutil links that copy.
    @discardableResult
    public func link(_ input: Input) throws -> Data {
        let (base, paths) = try locations(for: input)
        if let data = try cachedMix(at: paths.mixed), !data.isEmpty {
            return data
        }
        let location = try KernelCollectionBuilder.location(for: base)
        if case .host = location, geteuid() != 0 {
            throw PatcherError.invalidFormat(Self.linkInstructions(staged: Self.isStaged(paths.staged)))
        }
        guard Self.isStaged(paths.staged) else {
            throw PatcherError.fileNotFound("the staged \(base.id) kernelcache volume in \(paths.staged.path); run `vphone-cli fw kernelcache` as your user first")
        }

        let payload = try Self.payload(of: input.kernelcache)
        if case let .remote(builder) = location {
            return try linkRemotely(base: base, paths: paths, payload: payload, builder: builder)
        }
        let copy = try KernelCacheVolumeCopy(
            staged: paths.staged.appending(path: "volume"), kdk: base.kernel.kdk, pathLength: Self.buildRootLength(of: payload),
        )
        defer { copy.remove() }
        log("  [kc] linking with kmutil")
        let identifiers = try base.kextIdentifiers()
        let kmutilLog = copy.root.appending(path: "kmutil.log")
        // Beside the mix, whether the link worked or not: kmutil leaves out a
        // kext it does not accept without failing.
        defer {
            if let text = try? Data(contentsOf: kmutilLog) {
                try? storeMix(text, at: paths.mixed.deletingPathExtension().appendingPathExtension("kmutil.log"))
            }
        }
        var output = try KernelCollectionBuilder.link(
            volume: copy.volume, kernel: copy.kernel, identifiers: identifiers, log: kmutilLog,
        )
        output = try finalize(output, original: payload, identifiers: identifiers, work: copy.root)
        try storeMix(output, at: paths.mixed)
        log("  [kc] mixed kernelcache: \(output.count) bytes, cached at \(paths.mixed.path)")
        return output
    }

    /// Links the staged volume on the Mac `VPHONE_KMUTIL_SSH` names. Root there
    /// links what it is sent, so this side needs no root: the stage is checked
    /// for links outside it and sent as it is.
    func linkRemotely(
        base: KernelCacheBase, paths: (mixed: URL, staged: URL), payload: Data, builder: RemoteKernelCollectionBuilder,
    ) throws -> Data {
        guard geteuid() != 0 else {
            throw PatcherError.invalidFormat("Remote linking does not need local root. Run `vphone-cli fw kernelcache <vm>` as your user with VPHONE_KMUTIL_SSH set, then run the privileged firmware step.")
        }
        let volume = paths.staged.appending(path: "volume")
        try KernelCacheVolumeCopy.checkLinks(in: volume, kdk: base.kernel.kdk)
        let work = paths.staged.appending(path: "link")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let kmutilLog = work.appending(path: "kmutil.log")
        defer {
            if let text = try? Data(contentsOf: kmutilLog) {
                try? storeMix(text, at: paths.mixed.deletingPathExtension().appendingPathExtension("kmutil.log"))
            }
        }
        let identifiers = try base.kextIdentifiers()
        var output = try builder.link(
            staged: volume, kernel: "Library/Developer/KDKs/\(base.kernel.kdk)/System/Library/Kernels/kernel",
            identifiers: identifiers, pathLength: Self.buildRootLength(of: payload), work: work, log: kmutilLog,
        )
        output = try finalize(output, original: payload, identifiers: identifiers, work: work)
        try storeMix(output, at: paths.mixed)
        log("  [kc] mixed kernelcache: \(output.count) bytes, cached at \(paths.mixed.path)")
        return output
    }

    /// Whether `input` is linked by another Mac over ssh, which needs no root here.
    public func linksRemotely(_ input: Input) throws -> Bool {
        let (base, _) = try locations(for: input)
        if case .remote = try KernelCollectionBuilder.location(for: base) {
            return true
        }
        return false
    }

    // MARK: - Cache

    /// A privileged patch run must not follow a cache link to another host
    /// file. Keep the descriptor alive through the read, including a rename.
    func cachedMix(at url: URL) throws -> Data? {
        do {
            let root = try VPhoneConfinedDirectory.pin(absolutePath: cacheDirectory.path)
            guard url.path.hasPrefix(cacheDirectory.path + "/") else {
                throw PatcherError.invalidFormat("The kernelcache input is outside its cache directory.")
            }
            let relative = String(url.path.dropFirst(cacheDirectory.path.count + 1))
            let file = try root.openRegularFile(relative, requireSingleLink: true)
            let uid = VPhoneInvokingUser.current?.uid ?? getuid()
            guard file.owner == 0 || file.owner == uid else {
                throw PatcherError.invalidFormat("The cached kernelcache belongs to another user.")
            }
            return try withExtendedLifetime(file) {
                try FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false).readToEnd()
            }
        } catch VPhoneConfinedDirectoryError.missing {
            return nil
        }
    }

    static let stagedMarker = ".staged"

    static func isStaged(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: stagedMarker).path)
    }

    /// The recipe and where its mix and staged volume are kept.
    func locations(for input: Input) throws -> (base: KernelCacheBase, paths: (mixed: URL, staged: URL)) {
        let base = try base(for: input)
        let key = try cacheKey(base: base, donors: base.donors.map { try recipes.donor(id: $0) })
        return (base, (
            cacheDirectory.appending(path: "mix/\(base.id)/\(key).im4p"),
            cacheDirectory.appending(path: "staged/\(base.id)/\(key)"),
        ))
    }

    /// Writes the mix into the invoking user's cache without following a link:
    /// root writes there.
    func storeMix(_ data: Data, at url: URL) throws {
        let user = VPhoneInvokingUser.current
        let cache = cacheDirectory.path
        // A privileged linker only consumes an existing user stage. Do not
        // create or revisit a path through its user-writable ancestors as root.
        if geteuid() != 0 {
            try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        }
        let root = try VPhoneConfinedDirectory.pin(absolutePath: cache)
        guard url.path.hasPrefix(cache + "/") else {
            throw PatcherError.invalidFormat("The kernelcache output is outside its cache directory.")
        }
        let relative = String(url.path.dropFirst(cache.count + 1))
        let (directory, leaf) = try root.parent(of: relative, create: true)
        try directory.writeFile(leaf, contents: data, mode: 0o644, owner: user.map { ($0.uid, $0.gid) })
        // Under sudo, so the user's later runs, which link over ssh, can store here too.
        if geteuid() == 0 {
            var current = root
            try current.setPermissions(mode: 0o777, owner: user.map { ($0.uid, $0.gid) })
            for name in relative.split(separator: "/").dropLast() {
                current = try current.directory(String(name))
                try current.setPermissions(mode: 0o777, owner: user.map { ($0.uid, $0.gid) })
            }
        }
    }

    public static func linkInstructions(staged: Bool) -> String {
        let link = "sudo vphone-cli fw kernelcache <vm>"
        return staged
            ? "the kernelcache mix is staged; linking it needs root (kmutil only reads kexts owned by root). Run `\(link)`, or this command with sudo."
            : "the kernelcache mix is not built yet. Stage it as your user with `vphone-cli fw kernelcache <vm>`, then link it with `\(link) --link-only`."
    }

    // MARK: - Steps

    /// Puts back Apple's CPU subtype (the 26.x builder writes 0xc0000002 where
    /// some kernelcaches have 0x2) and checks every requested bundle was linked.
    func finalize(_ im4pData: Data, original: Data, identifiers: [String], work: URL) throws -> Data {
        guard let im4p = try? IM4P(im4pData) else {
            throw PatcherError.invalidFormat("kmutil's output is not an IM4P container")
        }
        var payload = try im4p.payload()
        guard payload.count > 12, original.count > 12, payload.prefix(4) == original.prefix(4) else {
            throw PatcherError.invalidFormat("kmutil's output is not a Mach-O kernel collection")
        }
        let missing = identifiers.filter { payload.range(of: Data(">\($0)<".utf8)) == nil }
        guard missing.isEmpty else {
            throw PatcherError.invalidFormat("kexts missing from the linked kernelcache: \(missing.joined(separator: ", "))")
        }
        var changed = false
        let start = payload.startIndex
        let subtype = payload[start + 8 ..< start + 12]
        let wanted = original[original.startIndex + 8 ..< original.startIndex + 12]
        if subtype != wanted {
            log("  [kc] restoring CPU subtype \(Data(wanted).hex) (the builder wrote \(Data(subtype).hex))")
            payload.replaceSubrange(start + 8 ..< start + 12, with: wanted)
            changed = true
        }
        let stubs = try KernelCollectionStubCalls.directCalls(in: payload)
        if stubs.branches > 0 {
            log("  [kc] the builder kept \(stubs.stubs) auth stubs; \(stubs.branches) calls now branch to their targets directly")
            payload = stubs.payload
            changed = true
        }
        guard changed else { return im4pData }
        let url = work.appending(path: "finalized.im4p")
        try IM4PHandler.save(patchedData: payload, originalIM4P: im4p, to: url)
        return try Data(contentsOf: url)
    }

    /// Extract natively. A kernelcache whose kexts carry no DTPlatformBuild
    /// gives KDK_<version>_.kdk; the recipe supplies the build.
    func extract(kernelcache: URL, symbols: URL?, kdk: String, into directory: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var messages: [String] = []
        defer { try? messages.joined(separator: "\n").write(to: directory.appending(path: "extract.log"), atomically: true, encoding: .utf8) }
        var known: [UInt64: [String]] = [:]
        if let symbols {
            let json = directory.appending(path: "symbols.json")
            try VPhoneArchiveWriter.decompress(symbols, to: json)
            known = try KDKLinkSymbols.loadKnown(Data(contentsOf: json))
            try fm.removeItem(at: json)
        }
        do {
            _ = try KDKExtraction.extract(Data(contentsOf: kernelcache, options: .mappedIfSafe), to: directory, known: known) {
                messages.append($0)
            }
        } catch {
            messages.append("ERROR: \(error)")
            throw error
        }

        let produced = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("KDK_") && $0.hasSuffix(".kdk") }
        guard produced.count == 1, let name = produced.first else {
            throw PatcherError.fileNotFound("the native KDK extraction wrote into \(directory.path) (found \(produced))")
        }
        var url = directory.appending(path: name)
        if name != kdk {
            let parts = kdk.dropFirst(4).dropLast(4).split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count == 2, name == "KDK_\(parts[0])_.kdk" else {
                throw PatcherError.invalidFormat("extracted \(name), the recipe expects \(kdk)")
            }
            let systemVersion = url.appending(path: "System/Library/CoreServices/SystemVersion.plist")
            var plist = try KernelCacheKDK.plist(at: systemVersion)
            plist["ProductBuildVersion"] = String(parts[1])
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: systemVersion)
            let renamed = directory.appending(path: kdk)
            try fm.moveItem(at: url, to: renamed)
            url = renamed
        }
        return url
    }

    /// The donor's KDK, extracted once into `donors/<id>`.
    func donorKDK(_ donor: KernelCacheDonor, restoreTree: URL) throws -> URL {
        let fm = FileManager.default
        let directory = cacheDirectory.appending(path: "donors/\(donor.id)")
        let kdk = directory.appending(path: "extract/\(donor.kernel.kdk)")
        let marker = directory.appending(path: "extract/.complete")
        var keyMaterial = Data(Self.identity(donor.kernel).utf8)
        if let symbols = donor.symbolsURL {
            keyMaterial += try Data(contentsOf: symbols)
        }
        keyMaterial += Data(KDKExtraction.revision.utf8)
        let key = KernelCacheRecipes.sha256(keyMaterial)
        if (try? String(contentsOf: marker, encoding: .utf8)) == key, fm.fileExists(atPath: kdk.path) {
            log("  [kc] using the cached donor KDK \(kdk.path)")
            return kdk
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = try Self.payload(of: donorKernelcache(donor, in: directory, restoreTree: restoreTree))
        try Self.check(payload, donor.kernel.decompressedSHA256, "decompressed donor \(donor.kernel.file)")
        let decompressed = directory.appending(path: "\(donor.kernel.file).decompressed")
        try payload.write(to: decompressed)
        defer { try? fm.removeItem(at: decompressed) }
        log("  [kc] extracting the donor kernelcache \(donor.id)")
        let extracted = try extract(
            kernelcache: decompressed, symbols: donor.symbolsURL, kdk: donor.kernel.kdk,
            into: directory.appending(path: "extract"),
        )
        try key.write(to: marker, atomically: true, encoding: .utf8)
        return extracted
    }

    /// The donor kernelcache: from the guest's restore tree for one its IPSW
    /// ships, else kept in `directory` once read from its cloudOS IPSW, of
    /// which only that one entry is downloaded.
    func donorKernelcache(_ donor: KernelCacheDonor, in directory: URL, restoreTree: URL) throws -> Data {
        guard let cloudOSSource = donor.cloudOSSource else {
            let data = try Data(contentsOf: restoreTree.appending(path: donor.kernel.file), options: .mappedIfSafe)
            guard donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) else {
                throw PatcherError.invalidFormat("the guest's \(donor.kernel.file) does not match the \(donor.id) recipe")
            }
            return data
        }
        let local = directory.appending(path: donor.kernel.file)
        if let data = try? Data(contentsOf: local), donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) {
            return data
        }
        guard let source = URL(string: cloudOSSource) else {
            throw PatcherError.invalidFormat("the \(donor.id) recipe has no valid cloudOS URL")
        }
        log("  [kc] reading \(donor.kernel.file) from \(source.absoluteString)")
        let file = donor.kernel.file
        let data = try vphoneRunBlocking {
            let zip = try await VPhoneRemoteZip.open(source)
            return try await zip.read(zip.entry(endingWith: file))
        }
        guard donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) else {
            throw PatcherError.invalidFormat("the downloaded \(file) does not match the \(donor.id) recipe")
        }
        try data.write(to: local)
        return data
    }

    // MARK: - Helpers

    /// What decides the output: the kernelcaches, maps and bundle list, the
    /// layout, native extractor revision and this file's steps.
    func cacheKey(base: KernelCacheBase, donors: [KernelCacheDonor]) throws -> String {
        var material = Data("\(Self.identity(base.kernel))|".utf8)
        for donor in donors {
            material += Data("\(Self.identity(donor.kernel))|".utf8)
        }
        for url in [base.symbolsURL, base.kextsURL] + donors.compactMap(\.symbolsURL) {
            material += try Data(contentsOf: url)
        }
        material += Data("\(Self.revision)|\(base.builderLayout.rawValue)|\(KDKExtraction.revision)".utf8)
        // A recipe with its own source order is keyed on it too.
        if base.sources != nil {
            material += Data("|\(base.kextSources.joined(separator: ","))".utf8)
        }
        if let overrides = base.kextOverrides {
            material += Data("|\(overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))".utf8)
        }
        return String(KernelCacheRecipes.sha256(material).prefix(16))
    }

    static func identity(_ kernel: KernelCacheFile) -> String {
        "\(kernel.file)|\(kernel.sha256)|\(kernel.decompressedSHA256)|\(kernel.kdk)"
    }

    static func check(_ data: Data, _ sha: String, _ what: String) throws {
        let actual = KernelCacheRecipes.sha256(data)
        guard actual == sha else {
            throw PatcherError.invalidFormat("\(what): SHA-256 \(actual), the recipe expects \(sha)")
        }
    }

    static func payload(of data: Data) throws -> Data {
        if let im4p = try? IM4P(data) {
            return try im4p.payload()
        }
        return data
    }

    /// Runs a tool with its output in `log`, which a failure quotes the end of.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], log: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: log.path) {
            fm.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(25).joined(separator: "\n")
            throw PatcherError.invalidFormat("\((executable as NSString).lastPathComponent) failed with exit code \(process.terminationStatus) (log: \(log.path)):\n\(tail)")
        }
    }

    func log(_ message: String) {
        if verbose {
            print(message)
        }
    }
}
