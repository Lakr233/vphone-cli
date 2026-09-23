@testable import VPhoneCore
import Foundation
import Testing

/// `.serialized` because several of these set and unset `VPHONE_ROOT`, and the
/// environment is process-global: run in parallel, one test's
/// `defer { unsetenv(...) }` clears the variable another is still relying on.
/// That was a real intermittent failure — roughly one run in ten —
/// and the reason two tests below bail out early when `VPHONE_ROOT` is already
/// set, which was a way of tolerating the race rather than fixing it.
@Suite(.serialized)
struct ResourcesTests {
    @Test func bundledLayoutResolvesToContentsResources() {
        let exe = "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli"
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == "/Applications/vphone-cli.app/Contents/Resources")
        #expect(r.fwPrepareScript.path == "/Applications/vphone-cli.app/Contents/Resources/scripts/fw_prepare.sh")
        #expect(r.cfwInstallHostScript.path
            == "/Applications/vphone-cli.app/Contents/Resources/scripts/cfw_install_host.sh")
    }

    @Test func devLayoutWalksUpToProjectRoot() throws {
        // Fake a dev tree: <root>/.build/release/vphone-cli with a <root>/scripts dir.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/release"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent(".build/release/vphone-cli").path
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == root.resolvingSymlinksInPath().path)
        #expect(r.resourceArchivesDir.path == root.resolvingSymlinksInPath()
            .appendingPathComponent("scripts/resources").path)
    }

    @Test func cacheDirsAreHomeRelative() {
        // The VPHONE_ROOT override would relocate the cache; only assert the default.
        if ProcessInfo.processInfo.environment["VPHONE_ROOT"] != nil { return }
        #expect(VPhoneResources.userDataRoot().path.hasSuffix("/.vphone"))
    }

    @Test func userDataRootHonorsVPHONERoot() {
        setenv("VPHONE_ROOT", "/tmp/vphone-test-root", 1)
        defer { unsetenv("VPHONE_ROOT") }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        #expect(VPhoneResources.userDataRoot().path == "/tmp/vphone-test-root")
        #expect(r.ipswCacheDir.path == "/tmp/vphone-test-root/ipsws")
        #expect(r.sealVolumeCacheDir.path == "/tmp/vphone-test-root/tools")
        #expect(r.debsCacheDir.path == "/tmp/vphone-test-root/debs")
    }

    /// `VPhoneResources` resolves programs as siblings of the running image and
    /// scripts under `scriptsDir`, and nothing else — no `PATH` walk, no
    /// interpreter. That claim is what the deleted venv tests used to guard
    /// from the other side, so assert it directly: every URL this type hands
    /// out is rooted in `base` or in the user data root.
    @Test func everyResourceIsRootedInTheBaseOrTheDataRoot() {
        setenv("VPHONE_ROOT", "/tmp/vphone-test-root", 1)
        defer { unsetenv("VPHONE_ROOT") }
        let base = URL(fileURLWithPath: "/x")
        let r = VPhoneResources(base: base)
        let rooted = [
            r.scriptsDir, r.resourceArchivesDir, r.fwPrepareScript,
            r.cfwInstallHostScript, r.preflightScript, r.signcert, r.vphoned,
        ]
        for url in rooted {
            #expect(url.path.hasPrefix("/x/"), "\(url.path) escapes the resource base")
        }
        for url in [r.ipswCacheDir, r.sealVolumeCacheDir, r.debsCacheDir] {
            #expect(url.path.hasPrefix("/tmp/vphone-test-root/"))
        }
    }

    /// A companion binary is found beside the running image, never on `PATH` —
    /// the property that made the interpreter ladder removable.
    @Test func siblingExecutableSitsBesideTheRunningImage() {
        let me = VPhoneResources.runningExecutable()
        let sibling = VPhoneResources.siblingExecutable("vphone-vm")
        #expect(sibling.deletingLastPathComponent().path == me.deletingLastPathComponent().path)
        #expect(sibling.lastPathComponent == "vphone-vm")
    }
}
