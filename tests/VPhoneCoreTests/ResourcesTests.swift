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
        #expect(r.pmd3Bridge.path
            == "/Applications/vphone-cli.app/Contents/Resources/scripts/pymobiledevice3_bridge.py")
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

    /// The probe shells out; a missing interpreter must return false, not throw.
    @Test func venvProbeIsTotalForAMissingInterpreter() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        let missing = URL(fileURLWithPath: "/nonexistent/bin/python3")
        #expect(r.pythonIsUsable(missing) == false)
    }

    /// The venv exists for `scripts/pymobiledevice3_bridge.py` and nothing else
    /// now that the firmware patchers are Swift, so the requirements must not
    /// name a patcher-only package. capstone, keystone-engine and pyimg4 were
    /// the three; pyimg4 still arrives transitively via pymobiledevice3.
    @Test func fallbackRequirementsCarryNoPatcherOnlyPackages() {
        let names = VPhoneResources.fallbackRequirements
        for dead in ["capstone", "keystone-engine", "pyimg4"] {
            #expect(names.contains { $0.hasPrefix(dead) } == false, "\(dead) is patcher-only")
        }
        #expect(names.contains { $0.hasPrefix("pymobiledevice3") })
        #expect(names.contains("ipsw-parser"))
    }

    /// `fallbackRequirements` claims to mirror requirements.txt, so check the
    /// real file rather than trusting the comment. Derived from `#filePath`:
    /// `swift test` makes no promise about the working directory.
    @Test func requirementsFileMatchesTheFallbackList() throws {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent() // VPhoneCoreTests
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // <root>
        let file = repoRoot.appending(path: "requirements.txt")
        try #require(FileManager.default.fileExists(atPath: file.path))
        let listed = try String(contentsOf: file, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(listed == VPhoneResources.fallbackRequirements)
    }

    @Test func managedVenvDefaultsUnderDotVphone() {
        // The override env vars would change this; only assert the default.
        if ProcessInfo.processInfo.environment["VPHONE_VENV_DIR"] != nil { return }
        if ProcessInfo.processInfo.environment["VPHONE_ROOT"] != nil { return }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        #expect(r.managedVenvDir.path.hasSuffix("/.vphone/venv"))
    }

    @Test func userDataRootHonorsVPHONERoot() {
        unsetenv("VPHONE_VENV_DIR")
        setenv("VPHONE_ROOT", "/tmp/vphone-test-root", 1)
        defer { unsetenv("VPHONE_ROOT") }
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"))
        #expect(VPhoneResources.userDataRoot().path == "/tmp/vphone-test-root")
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
