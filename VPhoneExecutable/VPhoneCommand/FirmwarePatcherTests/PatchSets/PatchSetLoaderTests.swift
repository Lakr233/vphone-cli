// PatchSetLoaderTests.swift — Loading a `.vphonepatchset` from outside the tool.
//
// These run against `VPhonePatchSetExample.vphonepatchset`, built beside the test
// bundle, so they exercise the real loader against a real bundle rather than a
// mock of one: the manifest read before any code is mapped, the signature check,
// `dlopen` through `Bundle`, the principal class, and the patcher it hands back.
//
// The signature tests work on copies in a temporary directory, never on the built
// product. A set straight out of Xcode is *linker* ad hoc signed — the Mach-O
// carries a signature but the bundle has no sealed resources — which is exactly
// the "arrived unsigned or invalid" case `vphone-cli patchset import` fixes, so
// these tests reproduce that repair with the same `codesign` invocation instead of
// asserting anything about how Xcode happened to leave the product.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

// MARK: - Fixture

/// Where the example set is, and how to get sealed and tampered copies of it.
private enum ExamplePatchSet {
    static let identifier = "com.vphone.patchset.example"
    static let patchIdentifier = "ibec-exp-string_rewrite"

    /// The built product, beside the running `.xctest`.
    static func url() throws -> URL {
        let xctest = try #require(
            Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") },
            "the test bundle has to be findable to locate the products directory",
        )
        let products = URL(fileURLWithPath: xctest.bundlePath).deletingLastPathComponent()
        let url = products.appendingPathComponent(
            "VPhonePatchSetExample.\(VPhonePatchSetBundle.pathExtension)",
            isDirectory: true,
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("VPhonePatchSetExample is not in \(products.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// A copy under `directory`, ad hoc signed the way `patchset import` signs one.
    static func sealedCopy(into directory: URL) throws -> URL {
        let copy = directory.appendingPathComponent(
            "Copy.\(VPhonePatchSetBundle.pathExtension)",
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url(), to: copy)
        try codesign(copy)
        return copy
    }

    /// `codesign --force --sign -`, no `--deep`: one pass over the bundle is what
    /// seals its resources. See `VPhonePatchSetStore.adHocSign`.
    static func codesign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "codesign should seal a copy of the example")
    }

    static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-patchset-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

// MARK: - Inspecting

@Suite("Patch set bundles are read before they are loaded")
struct PatchSetInspectionTests {
    @Test
    func `The manifest comes out of the bundle without loading any code`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        #expect(set.manifest.identifier == ExamplePatchSet.identifier)
        #expect(set.manifest.patches.count == 1)
        let patch = try #require(set.manifest.patches.first)
        #expect(patch.identifier == ExamplePatchSet.patchIdentifier)
        #expect(patch.target == .firmware(.iBEC))
        // Nothing is version-pinned, so the example applies to any pairing.
        #expect(patch.applicability.matches(iOSBase: VPhoneVersion("18.6"), cloudOS: nil))
        #expect(patch.applicability.matches(iOSBase: VPhoneVersion("27.0"), cloudOS: nil))
    }

    @Test
    func `Anything that is not a patch set bundle is refused`() throws {
        let plain = URL(fileURLWithPath: "/usr/bin/codesign")
        #expect(throws: VPhonePatchSetError.notABundle(path: plain.path)) {
            try VPhonePatchSetBundle.inspect(at: plain)
        }
    }

    @Test
    func `A path with the right extension but no manifest is refused`() throws {
        let directory = ExamplePatchSet.temporaryDirectory()
        let empty = directory.appendingPathComponent(
            "Empty.\(VPhonePatchSetBundle.pathExtension)",
            isDirectory: true,
        )
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var thrown: VPhonePatchSetError?
        do {
            _ = try VPhonePatchSetBundle.inspect(at: empty)
        } catch let error as VPhonePatchSetError {
            thrown = error
        }
        guard case .manifestUnreadable = try #require(thrown) else {
            Issue.record("expected manifestUnreadable, got \(String(describing: thrown))")
            return
        }
    }
}

// MARK: - Validating

@Suite("What a patch set has to satisfy before it is loaded")
struct PatchSetValidationTests {
    @Test
    func `The identifier the preset pinned has to be the one the manifest declares`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        #expect(throws: VPhonePatchSetError.identifierMismatch(
            path: set.url.path,
            expected: "com.example.other",
            found: ExamplePatchSet.identifier,
        )) {
            // Signature off: this test is about identity, and the built product is
            // not sealed until `patchset import` signs a copy of it.
            try set.validate(expecting: "com.example.other", requireSignature: false)
        }
    }

    @Test
    func `A set built against a newer PatchKit is refused`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let ancient = try #require(VPhoneVersion("0.1"))
        #expect(throws: VPhonePatchSetError.patchKitTooOld(
            patchSet: ExamplePatchSet.identifier,
            required: set.manifest.minimumPatchKitVersion,
            available: ancient,
        )) {
            try set.validate(expecting: nil, patchKitVersion: ancient, requireSignature: false)
        }
        // And is accepted by the framework it was actually built against.
        #expect(set.manifest.minimumPatchKitVersion <= .currentPatchKit)
    }

    @Test
    func `An ad hoc signed copy passes every check the loader makes`() throws {
        let directory = ExamplePatchSet.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = try ExamplePatchSet.sealedCopy(into: directory)

        let set = try VPhonePatchSetBundle.inspect(at: copy)
        // The full check, signature included — what `patchset import` ends with and
        // what `resolvePlan` runs before it loads anything.
        try set.validate(expecting: ExamplePatchSet.identifier)
        #expect(try !set.codeDirectoryHash().isEmpty)
    }

    @Test
    func `A set altered after signing no longer validates`() throws {
        let directory = ExamplePatchSet.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = try ExamplePatchSet.sealedCopy(into: directory)
        let sealed = try VPhonePatchSetBundle.inspect(at: copy)
        try sealed.requireValidSignature()

        // Rewrite a sealed resource. This is the case the signature exists for:
        // the manifest decides which patches the plan believes it is getting, so a
        // manifest edited behind the plan's back has to stop the load.
        let manifest = copy
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(VPhonePatchSetManifest.resourceName)
        var contents = try String(contentsOf: manifest, encoding: .utf8)
        contents = contents.replacingOccurrences(
            of: "<string>Example</string>",
            with: "<string>Tampered</string>",
        )
        try contents.write(to: manifest, atomically: true, encoding: .utf8)

        let altered = try VPhonePatchSetBundle.inspect(at: copy)
        #expect(altered.manifest.name == "Tampered")
        var thrown: (any Error)?
        do {
            try altered.validate(expecting: ExamplePatchSet.identifier)
        } catch {
            thrown = error
        }
        guard case .signatureInvalid = try #require(thrown as? VPhonePatchSetError) else {
            Issue.record("expected signatureInvalid, got \(String(describing: thrown))")
            return
        }
    }

    @Test
    func `A boot-chain-only set has no guest-side patch to refuse`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let guestSide = set.manifest.patches.filter { !$0.target.isBootChain }
        #expect(guestSide.isEmpty)
        // The refusal itself is the resolver's rule and is covered where the
        // manifest model is tested; here the point is that the example obeys it,
        // because a set that did not could never be imported at all.
    }
}

// MARK: - Loading

@Suite("Loading the principal class and the patcher it builds")
struct PatchSetLoadingTests {
    /// An iBEC-shaped buffer: the anchor, NUL terminated, inside other bytes.
    private static func syntheticIBEC(anchor: String) -> Data {
        var data = Data(repeating: 0x41, count: 0x40)
        data.append(anchor.data(using: .ascii)!)
        data.append(0)
        data.append(Data(repeating: 0x42, count: 0x40))
        return data
    }

    private static func context(
        parameters: [String: String],
        gate: VPhonePatchGate = .unrestricted,
    ) -> VPhonePatchSetContext {
        VPhonePatchSetContext(
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
            gate: gate,
            parameters: parameters,
            verbose: false,
        )
    }

    @Test
    func `The exported factory loads and resolves VPhonePatchKit at runtime`() throws {
        // Two things are load-bearing here. The link: the bundle's executable names
        // `@rpath/VPhonePatchKit.framework`, and dyld has to find the same framework
        // this process already has — a second copy would make the cast inside
        // `loadPrincipal` fail, because the two `VPhonePatchSetPrincipal`s would be
        // different types. And the entry point: the set is reached through the C
        // symbol it exports, not through `NSPrincipalClass`, which cannot work for a
        // class whose superclass is resilient.
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let principal = try set.loadPrincipal()
        #expect(String(describing: type(of: principal)) == "VPhoneExamplePatchSet")
        // Loading twice hands back a second principal rather than failing: dlopen on
        // a mapped image returns its handle.
        #expect(try String(describing: type(of: set.loadPrincipal())) == "VPhoneExamplePatchSet")
    }

    @Test
    func `A component the manifest never declared is a loud error`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let principal = try set.loadPrincipal()
        var thrown: (any Error)?
        do {
            _ = try principal.makePatcher(
                for: .kernelcache,
                data: Data(),
                context: Self.context(parameters: [:]),
            )
        } catch {
            thrown = error
        }
        guard case let .componentUnsupported(_, component) =
            try #require(thrown as? VPhonePatchSetError)
        else {
            Issue.record("expected componentUnsupported, got \(String(describing: thrown))")
            return
        }
        #expect(component == VPhoneFirmwareComponent.kernelcache.rawValue)
    }

    @Test
    func `The loaded patcher rewrites the string the preset named`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let principal = try set.loadPrincipal()
        let original = Self.syntheticIBEC(anchor: "VPHONE-ANCHOR")

        let patcher = try principal.makePatcher(
            for: .iBEC,
            data: original,
            context: Self.context(parameters: [
                "ExampleFindString": "VPHONE-ANCHOR",
                // One byte shorter than the anchor, so the rewrite also has to NUL
                // pad rather than leave the tail of the old string behind.
                "ExampleReplaceString": "vphone-patch",
            ]),
        )
        let records = try patcher.findAll()
        #expect(records.count == 1)
        #expect(try patcher.apply() == 1)

        let patched = patcher.patchedData
        #expect(patched.count == original.count)
        let buffer = BinaryBuffer(patched)
        #expect(buffer.findAll(Data("VPHONE-ANCHOR".utf8)).isEmpty)
        let sites = buffer.findAll(Data("vphone-patch".utf8))
        #expect(try sites == [#require(records.first).fileOffset])
        // The byte the shorter replacement freed is a NUL, not the old tail.
        #expect(try patched[#require(sites.first) + 12] == 0)
    }

    @Test
    func `A replacement longer than the anchor is refused rather than shifting bytes`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let principal = try set.loadPrincipal()
        let patcher = try principal.makePatcher(
            for: .iBEC,
            data: Self.syntheticIBEC(anchor: "SHORT"),
            context: Self.context(parameters: [
                "ExampleFindString": "SHORT",
                "ExampleReplaceString": "MUCH LONGER REPLACEMENT",
            ]),
        )
        #expect(throws: (any Error).self) { try patcher.findAll() }
    }

    @Test
    func `A patcher whose patch the plan turned off writes nothing`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let principal = try set.loadPrincipal()
        let original = Self.syntheticIBEC(anchor: "VPHONE-ANCHOR")
        let parameters = [
            "ExampleFindString": "VPHONE-ANCHOR",
            "ExampleReplaceString": "vphone-patch",
        ]

        let off = try principal.makePatcher(
            for: .iBEC,
            data: original,
            context: Self.context(
                parameters: parameters,
                gate: VPhonePatchGate(
                    declared: [ExamplePatchSet.patchIdentifier],
                    enabled: [],
                ),
            ),
        )
        #expect(try off.findAll().isEmpty)
        #expect(try off.apply() == 0)
        #expect(off.patchedData == original)

        // Declared and enabled: the same patcher writes.
        let on = try principal.makePatcher(
            for: .iBEC,
            data: original,
            context: Self.context(
                parameters: parameters,
                gate: VPhonePatchGate(
                    declared: [ExamplePatchSet.patchIdentifier],
                    enabled: [ExamplePatchSet.patchIdentifier],
                ),
            ),
        )
        #expect(try on.findAll().count == 1)
        #expect(try on.apply() == 1)
        #expect(on.patchedData != original)
    }

    @Test
    func `Without the preset's parameters the set patches nothing`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let principal = try set.loadPrincipal()
        let original = Self.syntheticIBEC(anchor: "VPHONE-ANCHOR")
        let patcher = try principal.makePatcher(
            for: .iBEC,
            data: original,
            context: Self.context(parameters: [:]),
        )
        #expect(try patcher.findAll().isEmpty)
        #expect(patcher.patchedData == original)
    }
}

// MARK: - Plan Integration

@Suite("An external set inside a resolved plan")
struct PatchSetPlanIntegrationTests {
    private func preset(
        path: String,
        selection: VPhonePatchSelection = .all,
    ) -> VPhonePatchPreset {
        VPhonePatchPreset(
            identifier: "loader-test",
            title: "Loader test",
            patchSets: [.external(identifier: ExamplePatchSet.identifier, path: path)],
            selection: selection,
            parameters: ["ExampleFindString": "VPHONE-ANCHOR"],
        )
    }

    @Test
    func `A preset naming the set by path resolves to its manifest`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(path: set.url.path),
            patchSets: [set.manifest],
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(plan.includesPatchSet(ExamplePatchSet.identifier))
        #expect(plan.isEnabled(ExamplePatchSet.patchIdentifier))
        #expect(plan.parameters["ExampleFindString"] == "VPHONE-ANCHOR")
        // The manifest decides which components the set's code is asked about.
        #expect(set.enabledComponents(in: plan) == [.iBEC])
    }

    @Test
    func `A set whose every patch is off is asked for no patcher at all`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(
                path: set.url.path,
                selection: .block([ExamplePatchSet.patchIdentifier]),
            ),
            patchSets: [set.manifest],
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(!plan.isEnabled(ExamplePatchSet.patchIdentifier))
        #expect(set.enabledComponents(in: plan).isEmpty)
    }

    @Test
    func `The pipeline loads the set the preset names and runs it over iBEC`() throws {
        // The whole path, without a restore tree: resolvePlan opens the bundle the
        // preset names — signature required, identifier pinned — buildComponentList
        // appends its patcher to the iBEC component, and patchData runs it.
        //
        // A signed copy, because this is the check the loader actually makes.
        let directory = ExamplePatchSet.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = try ExamplePatchSet.sealedCopy(into: directory)

        let pipeline = FirmwarePipeline(
            vmDirectory: directory,
            variant: .jb,
            verbose: false,
            preset: preset(path: copy.path, selection: .all),
            patchSets: FirmwarePatchSetCatalog.bundled,
        )
        let plan = try #require(try pipeline.resolvePlan(
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
        ))
        #expect(plan.includesPatchSet(ExamplePatchSet.identifier))
        #expect(!pipeline.loadedPatchSets.isEmpty)

        let components = pipeline.buildComponentList(
            restoreDir: directory,
            iOSBase: VPhoneVersion("27.0"),
            plan: plan,
            gate: VPhonePatchGate(plan: plan),
        )
        let iBEC = try #require(components.first { $0.name == "iBEC" })
        let external = try #require(
            iBEC.patcherFactories.last,
            "the external set's patcher has to be appended to iBEC",
        )
        // Last, not first: an external patcher sees the bytes the bundled boot-chain
        // patchers already wrote.
        let patcher = try external(Data(repeating: 0x41, count: 0x20), false)
        #expect(String(describing: type(of: patcher)) == "VPhoneExampleStringPatcher")

        // And the bytes come back out through BufferedPatcher, which is the only way
        // the pipeline can read a patcher it has never heard of.
        var anchored = Data(repeating: 0x41, count: 0x20)
        anchored.append(Data("VPHONE-ANCHOR".utf8))
        anchored.append(0)
        let (patched, records) = try pipeline.patchData(
            anchored,
            componentName: "iBEC",
            patcherFactories: [external],
        )
        #expect(records.map(\.patchID) == [ExamplePatchSet.patchIdentifier])
        #expect(patched != anchored)
        #expect(patched.count == anchored.count)
    }

    @Test
    func `A set the preset pins but never imported stops the run`() throws {
        // The built product is linker-signed with no sealed resources, which is what
        // a set nobody imported looks like. resolvePlan has to refuse it rather than
        // load it, and the message has to point at `patchset import`.
        let pipeline = try FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            variant: .jb,
            verbose: false,
            preset: preset(path: ExamplePatchSet.url().path),
            patchSets: FirmwarePatchSetCatalog.bundled,
        )
        var thrown: (any Error)?
        do {
            _ = try pipeline.resolvePlan(iOSBase: VPhoneVersion("27.0"), cloudOS: VPhoneVersion("26.4"))
        } catch {
            thrown = error
        }
        let error = try #require(thrown as? VPhonePatchSetError)
        switch error {
        case .unsigned, .signatureInvalid:
            #expect(pipeline.loadedPatchSets.isEmpty)
        default:
            Issue.record("expected a signature refusal, got \(error)")
        }
    }

    @Test
    func `The preset has to name the identifier the file declares`() throws {
        let set = try VPhonePatchSetBundle.inspect(at: ExamplePatchSet.url())
        // What `resolvePlan` does with a preset whose pinned identifier does not
        // match the bundle at the path: refuse before loading, so swapping the file
        // cannot silently change which patches apply.
        #expect(throws: (any Error).self) {
            try set.validate(expecting: "com.vphone.patchset.somethingelse", requireSignature: false)
        }
    }
}
