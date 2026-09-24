import Foundation
import Testing
@testable import VPhoneCoreKit

/// `.serialized` because several of these set and unset `VPHONE_ROOT`, and the
/// environment is process-global: run in parallel, one test's
/// `defer { unsetenv(...) }` clears the variable another is still relying on.
/// That was a real intermittent failure — roughly one run in ten.
///
/// `.serialized` alone did not fix it, and the "roughly one run in ten" stayed
/// true: it orders this suite's tests against each other and says nothing about
/// `LibraryTests`, which drives the same two variables from its own serialized
/// suite in a different file. Both sides now go through `ProcessEnvironment`,
/// which is the lock that actually spans them.
@Suite(.serialized)
struct ResourcesTests {
    @Test func `bundled layout resolves to contents resources`() {
        let exe = "/Applications/VPhone.bundle/Contents/MacOS/vphone-cli"
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == "/Applications/VPhone.bundle/Contents/Resources")
    }

    @Test func `dev layout walks up to project root`() throws {
        // Fake a dev tree: <root>/.build/release/vphone-cli with a <root>/scripts dir.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/release"),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent(".build/release/vphone-cli").path
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == root.resolvingSymlinksInPath().path)
    }

    @Test func `cache dirs are home relative`() {
        // The VPHONE_ROOT override would relocate the cache; assert the default
        // with the variable held clear, rather than bailing out when some other
        // suite happens to have set it — that skip was the old way of living
        // with the race `ProcessEnvironment` now closes.
        ProcessEnvironment.withOverrides(["VPHONE_ROOT": nil]) {
            #expect(VPhoneResources.userDataRoot().path.hasSuffix("/.vphone"))
        }
    }

    @Test func `user data root honors VPHONE root`() {
        ProcessEnvironment.withOverrides(["VPHONE_ROOT": "/tmp/vphone-test-root"]) {
            let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
            #expect(VPhoneResources.userDataRoot().path == "/tmp/vphone-test-root")
            #expect(r.ipswCacheDir.path == "/tmp/vphone-test-root/ipsws")
            #expect(r.sealVolumeCacheDir.path == "/tmp/vphone-test-root/tools")
        }
    }

    /// `VPhoneResources` resolves programs as siblings of the running image and
    /// scripts under `scriptsDir`, and nothing else — no `PATH` walk, no
    /// interpreter. That claim is what the deleted venv tests used to guard
    /// from the other side, so assert it directly: every URL this type hands
    /// out is rooted in `base` or in the user data root.
    @Test func `every resource is rooted in the base or the data root`() {
        ProcessEnvironment.withOverrides(["VPHONE_ROOT": "/tmp/vphone-test-root"]) {
            let base = URL(fileURLWithPath: "/x")
            let r = VPhoneResources(base: base)
            let rooted = [
                r.scriptsDir,
                r.vphoned,
            ]
            for url in rooted {
                #expect(url.path.hasPrefix("/x/"), "\(url.path) escapes the resource base")
            }
            for url in [r.ipswCacheDir, r.sealVolumeCacheDir] {
                #expect(url.path.hasPrefix("/tmp/vphone-test-root/"))
            }
        }
    }

    /// A companion binary is found beside the running image, never on `PATH` —
    /// the property that made the interpreter ladder removable.
    @Test func `sibling executable sits beside the running image`() {
        let me = VPhoneResources.runningExecutable()
        let sibling = VPhoneResources.siblingExecutable("vphone-vm")
        #expect(sibling.deletingLastPathComponent().path == me.deletingLastPathComponent().path)
        #expect(sibling.lastPathComponent == "vphone-vm")
    }
}
