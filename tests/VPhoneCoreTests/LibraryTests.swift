@testable import VPhoneCore
import Foundation
import Testing

// Serialized: defaultRootHonorsEnvOverride / defaultRootIsShellSafe mutate the
// process-global VPHONE_LIBRARY_ROOT; run in parallel they race (a set/unset
// from one can land inside the other's assertion).
@Suite(.serialized)
struct LibraryTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeBundle(_ name: String, in root: URL) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 8, memorySize: 8 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin",
                             avpSEPBooter: "AVPSEPBooter.vresearch1.bin"))
        try manifest.write(to: dir.appendingPathComponent("config.plist"))
    }

    @Test func scansOnlyDirsWithManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle("alpha", in: root)
        try writeBundle("beta", in: root)
        // A stray dir without config.plist must be ignored.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("junk"), withIntermediateDirectories: true)

        let names = try VPhoneLibrary(root: root).bundles().map(\.name)
        #expect(names == ["alpha", "beta"])
    }

    @Test func bundleNamedThrowsWhenMissing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: VPhoneLibraryError.self) {
            _ = try VPhoneLibrary(root: root).bundle(named: "nope")
        }
    }

    @Test func defaultRootHonorsEnvOverride() {
        setenv("VPHONE_LIBRARY_ROOT", "/tmp/vphone-test-root", 1)
        defer { unsetenv("VPHONE_LIBRARY_ROOT") }
        #expect(VPhoneLibrary.defaultRoot().path == "/tmp/vphone-test-root")
    }

    @Test func defaultRootHonorsVPHONERoot() {
        unsetenv("VPHONE_LIBRARY_ROOT")
        setenv("VPHONE_ROOT", "/tmp/vphone-test-root", 1)
        defer { unsetenv("VPHONE_ROOT") }
        #expect(VPhoneLibrary.defaultRoot().path == "/tmp/vphone-test-root/VMs")
    }

    @Test func defaultRootIsShellSafe() {
        // The default root feeds the shell/make firmware pipeline; a space in it
        // (e.g. "Application Support") breaks unquoted expansion. Must stay space-free.
        unsetenv("VPHONE_LIBRARY_ROOT")
        unsetenv("VPHONE_ROOT")
        #expect(!VPhoneLibrary.defaultRoot().path.contains(" "))
    }

    @Test func scanReportsCorruptBundlesInsteadOfDropping() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle("good", in: root)
        // A directory WITH config.plist but corrupt contents must be reported, not silently dropped.
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: bad.appendingPathComponent("config.plist"))

        let result = try VPhoneLibrary(root: root).scan()
        #expect(result.bundles.map(\.name) == ["good"])
        #expect(result.skipped.map(\.name) == ["bad"])
    }
}
