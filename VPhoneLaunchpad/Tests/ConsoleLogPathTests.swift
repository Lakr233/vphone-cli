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

        // Migration of a log written under the plain name before the naming
        // was shared. Unique machine names under the real logs directory,
        // removed afterwards.
        let files = FileManager.default
        let logs = url.deletingLastPathComponent()
        try? files.createDirectory(at: logs, withIntermediateDirectories: true)
        func legacyLog(_ name: String, _ text: String) -> URL {
            let file = logs.appendingPathComponent("\(name).log")
            try? Data(text.utf8).write(to: file)
            return file
        }
        func text(_ file: URL) -> String? {
            try? String(contentsOf: file, encoding: .utf8)
        }
        func migrate(_ name: String) -> URL {
            VPhoneLaunchpadConsoleLog.migrateLegacy(libraryRoot: library, name: name, legacyDefaultRoot: library)
            return VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: name)
        }

        let moved = "migrate-\(UUID().uuidString)"
        let movedLegacy = legacyLog(moved, "old")
        let movedCurrent = VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: moved)
        defer { try? files.removeItem(at: movedLegacy); try? files.removeItem(at: movedCurrent) }
        expect(migrate(moved) == movedCurrent && text(movedCurrent) == "old" && !files.fileExists(atPath: movedLegacy.path),
               "a legacy log moves to the digest name with its content")

        let both = "migrate-\(UUID().uuidString)"
        let bothLegacy = legacyLog(both, "old")
        let bothCurrent = VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: both)
        try? Data("new".utf8).write(to: bothCurrent)
        defer { try? files.removeItem(at: bothLegacy); try? files.removeItem(at: bothCurrent) }
        _ = migrate(both)
        expect(text(bothLegacy) == "old" && text(bothCurrent) == "new", "an existing current log is never overwritten")

        let plain = "migrate-\(UUID().uuidString)"
        let plainFile = legacyLog(plain, "keep")
        defer { try? files.removeItem(at: plainFile) }
        let other = library + "-other"
        VPhoneLaunchpadConsoleLog.migrateLegacy(libraryRoot: other, name: plain, legacyDefaultRoot: library)
        let otherCurrent = VPhoneLaunchpadConsoleLog.url(libraryRoot: other, name: plain)
        defer { try? files.removeItem(at: otherCurrent) }
        expect(text(plainFile) == "keep" && !files.fileExists(atPath: otherCurrent.path),
               "a machine outside the legacy default library is left alone")

        let missing = "migrate-\(UUID().uuidString)"
        let missingCurrent = migrate(missing)
        expect(missingCurrent.lastPathComponent == "\(missing)-\(digest).log"
            && !files.fileExists(atPath: missingCurrent.path)
            && !files.fileExists(atPath: logs.appendingPathComponent("\(missing).log").path),
            "a missing legacy log creates nothing and still yields the digest name")

        let stuck = "migrate-\(UUID().uuidString)"
        let stuckLegacy = legacyLog(stuck, "stay")
        let stuckCurrent = VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: stuck)
        chflags(stuckLegacy.path, UInt32(UF_IMMUTABLE))
        defer {
            chflags(stuckLegacy.path, 0)
            try? files.removeItem(at: stuckLegacy)
            try? files.removeItem(at: stuckCurrent)
        }
        expect(migrate(stuck) == stuckCurrent && text(stuckLegacy) == "stay" && !files.fileExists(atPath: stuckCurrent.path),
               "a failed move leaves the legacy log in place and still yields the digest name")

        // The suffix is part of the legacy name too.
        let suffixed = "migrate-\(UUID().uuidString)"
        let suffixedLegacy = legacyLog("\(suffixed)-patch", "patch")
        let suffixedCurrent = VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: suffixed, suffix: "-patch")
        defer { try? files.removeItem(at: suffixedLegacy); try? files.removeItem(at: suffixedCurrent) }
        VPhoneLaunchpadConsoleLog.migrateLegacy(libraryRoot: library, name: suffixed, suffix: "-patch", legacyDefaultRoot: library)
        expect(text(suffixedCurrent) == "patch" && !files.fileExists(atPath: suffixedLegacy.path),
               "a suffixed legacy log moves with its suffix")

        // The other direction: with Host Setup choosing `library`, a machine in
        // the home library used to carry a digest and now has a plain name.
        let back = "migrate-\(UUID().uuidString)"
        let backLegacy = logs.appendingPathComponent("\(back)-\(VPhoneMachineConsoleLog.digest(defaultRoot)).log")
        try? Data("home".utf8).write(to: backLegacy)
        let backCurrent = VPhoneLaunchpadConsoleLog.url(libraryRoot: defaultRoot, name: back)
        defer { try? files.removeItem(at: backLegacy); try? files.removeItem(at: backCurrent) }
        VPhoneLaunchpadConsoleLog.migrateLegacy(libraryRoot: defaultRoot, name: back, legacyDefaultRoot: library)
        expect(backCurrent.lastPathComponent == "\(back).log" && text(backCurrent) == "home" && !files.fileExists(atPath: backLegacy.path),
               "a home-library machine's digest-named log moves back to the plain name")

        // A machine in the log-naming default library is never touched.
        let inDefault = "migrate-\(UUID().uuidString)"
        let inDefaultFile = legacyLog(inDefault, "stay")
        let inDefaultDigest = logs.appendingPathComponent("\(inDefault)-\(VPhoneMachineConsoleLog.digest(defaultRoot)).log")
        try? Data("digest".utf8).write(to: inDefaultDigest)
        defer { try? files.removeItem(at: inDefaultFile); try? files.removeItem(at: inDefaultDigest) }
        VPhoneLaunchpadConsoleLog.migrateLegacy(libraryRoot: defaultRoot, name: inDefault, legacyDefaultRoot: defaultRoot)
        expect(text(inDefaultFile) == "stay" && text(inDefaultDigest) == "digest",
               "a default-library machine's logs are untouched")

        // VPHONE_LIBRARY_ROOT, not the bookmark, chooses the default library:
        // point it at the former chosen library and the digest drops.
        setenv("VPHONE_LIBRARY_ROOT", library, 1)
        defer { unsetenv("VPHONE_LIBRARY_ROOT") }
        expect(VPhoneLaunchpadConsoleLog.url(libraryRoot: library, name: "m1").lastPathComponent == "m1.log",
               "VPHONE_LIBRARY_ROOT set to the library makes it the default library")

        print("Console-log path tests passed: chosen library ignored, VPHONE_LIBRARY_ROOT honoured, suffix and default-library naming, legacy log migration (moved, moved back, kept, outside, missing, failed, suffixed, default library)")
    }
}
