@testable import VPhoneCore
import Foundation
import Testing

struct ResourcesTests {
    @Test func bundledLayoutResolvesToContentsResources() {
        let exe = "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli"
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == "/Applications/vphone-cli.app/Contents/Resources")
        #expect(r.fwPrepareScript.path == "/Applications/vphone-cli.app/Contents/Resources/scripts/fw_prepare.sh")
        #expect(r.cfwPy.path == "/Applications/vphone-cli.app/Contents/Resources/scripts/patchers/cfw.py")
    }

    @Test func devLayoutWalksUpToProjectRoot() throws {
        // Fake a dev tree: <root>/.build/release/vphone-cli with a <root>/scripts dir.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/release"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent(".build/release/vphone-cli").path
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == root.resolvingSymlinksInPath().path)
        #expect(r.resourceArchivesDir.path == root.resolvingSymlinksInPath()
            .appendingPathComponent("scripts/resources").path)
    }

    @Test func cacheDirsAreHomeRelativeAndToolsBinIsBaseRelative() {
        // The VPHONE_ROOT override would relocate the cache; only assert the default.
        if ProcessInfo.processInfo.environment["VPHONE_ROOT"] != nil { return }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/Applications/vphone-cli.app/Contents/Resources"))
        #expect(r.userCacheDir.path.hasSuffix("/.vphone"))
        #expect(r.toolsBinDir.path == r.base.appendingPathComponent(".tools/bin").path)
    }

    /// These all shell out; a missing interpreter must return false, not throw.
    @Test func venvProbesAreTotalForAMissingInterpreter() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        let missing = URL(fileURLWithPath: "/nonexistent/bin/python3")
        #expect(r.pythonIsUsable(missing) == false)
        #expect(r.keystoneIsUsable(missing) == false)
        #expect(r.venvIsUsable(missing) == false)
        #expect(r.repairKeystone(missing) == false)
    }

    @Test func managedVenvDefaultsUnderDotVphone() {
        // The override env vars would change this; only assert the default.
        if ProcessInfo.processInfo.environment["VPHONE_VENV_DIR"] != nil { return }
        if ProcessInfo.processInfo.environment["VPHONE_ROOT"] != nil { return }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        #expect(r.managedVenvDir.path.hasSuffix("/.vphone/venv"))
    }

    @Test func userCacheDirHonorsVPHONERoot() {
        unsetenv("VPHONE_VENV_DIR")
        setenv("VPHONE_ROOT", "/tmp/vphone-test-root", 1)
        defer { unsetenv("VPHONE_ROOT") }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        #expect(r.userCacheDir.path == "/tmp/vphone-test-root")
        #expect(r.ipswCacheDir.path == "/tmp/vphone-test-root/ipsws")
        #expect(r.sealVolumeCacheDir.path == "/tmp/vphone-test-root/tools")
        #expect(r.debsCacheDir.path == "/tmp/vphone-test-root/debs")
        #expect(r.managedVenvDir.path == "/tmp/vphone-test-root/venv")
    }

    @Test func managedVenvOverrideBeatsVPHONERoot() {
        setenv("VPHONE_ROOT", "/tmp/vphone-test-root", 1)
        setenv("VPHONE_VENV_DIR", "/tmp/custom-venv", 1)
        defer {
            unsetenv("VPHONE_ROOT")
            unsetenv("VPHONE_VENV_DIR")
        }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        #expect(r.managedVenvDir.path == "/tmp/custom-venv")
    }

    @Test func pythonUsabilityProbeRejectsMissingAcceptsDevVenv() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let r = VPhoneResources(base: cwd)
        // A non-existent interpreter is never usable.
        #expect(r.pythonIsUsable(URL(fileURLWithPath: "/does/not/exist/python3")) == false)
        // The dev .venv (when present) carries a modern ipsw_parser and must pass.
        let devVenv = cwd.appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: devVenv.path) {
            #expect(r.pythonIsUsable(devVenv) == true)
        }
    }
}
