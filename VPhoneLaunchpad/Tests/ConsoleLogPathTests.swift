import Foundation
import VPhoneCoreKit

/// `VPhoneLaunchpadConsoleLog`, the naming the GUI library's `consoleLog`
/// delegates to, must name a machine's log from `(libraryRoot,
/// VPHONE_LIBRARY_ROOT, home)` alone, never from the Host-Setup chosen
/// library. A Host-Setup bookmark is put in `UserDefaults` first,
/// as the running app has one, to prove the path ignores it: were the naming
/// made bookmark-aware again, a machine in the chosen library would drop its
/// digest and this test would fail.
@main
struct ConsoleLogPathTests {
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        precondition(condition, "line \(line): \(message())")
    }

    static func main() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // A Host-Setup bookmark, under the key VPhoneLaunchpadMachineLocations
        // reads, pointing at a real folder that will be the machine's library.
        let chosen = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-log-path-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosen) }
        if let data = try? chosen.bookmarkData() {
            UserDefaults.standard.set(data, forKey: "VPhoneLaunchpadLibraryBookmark")
        }
        defer { UserDefaults.standard.removeObject(forKey: "VPhoneLaunchpadLibraryBookmark") }

        // No VPHONE_LIBRARY_ROOT: the default library is ~/.vphone/machines.
        unsetenv("VPHONE_LIBRARY_ROOT")
        let library = VPhoneMachineConsoleLog.canonical(chosen)
        let digest = VPhoneMachineConsoleLog.digest(library)

        // A machine in the chosen library keeps its digest: the bookmark does
        // not make it the default library for naming.
        let url = VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: "m1")
        expect(url.lastPathComponent == "m1-\(digest).log",
               "a chosen-library machine keeps the digest, got \(url.lastPathComponent)")
        expect(url.deletingLastPathComponent().path.hasSuffix("Library/Logs/vphone-launchpad"),
               "logs live under ~/Library/Logs/vphone-launchpad, got \(url.path)")
        expect(VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: "m1", suffix: "-patch").lastPathComponent
               == "m1-\(digest)-patch.log", "the suffix rides along with the digest")

        // A machine in the default library (~/.vphone/machines) keeps a plain name.
        let defaultRoot = VPhoneMachineConsoleLog.defaultRoot()
        expect(defaultRoot == VPhoneMachineConsoleLog.canonical(home.appendingPathComponent(".vphone/machines", isDirectory: true)),
               "with VPHONE_LIBRARY_ROOT unset the default library is ~/.vphone/machines, got \(defaultRoot)")
        expect(VPhoneLaunchpadConsoleLog.url(libraryRoot: defaultRoot, name: "m1").lastPathComponent == "m1.log",
               "a default-library machine keeps a plain name")

        // VPHONE_LIBRARY_ROOT, not the bookmark, chooses the default library:
        // point it at the former chosen library and the digest drops.
        setenv("VPHONE_LIBRARY_ROOT", library, 1)
        defer { unsetenv("VPHONE_LIBRARY_ROOT") }
        expect(VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: "m1").lastPathComponent == "m1.log",
               "VPHONE_LIBRARY_ROOT set to the library makes it the default library")

        print("Console-log path tests passed: chosen library ignored, VPHONE_LIBRARY_ROOT honoured, suffix and default-library naming")
    }
}
