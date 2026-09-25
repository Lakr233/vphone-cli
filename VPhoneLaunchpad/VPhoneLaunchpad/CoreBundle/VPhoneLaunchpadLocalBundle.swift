import CryptoKit
import Foundation

/// A VPhone.bundle built on this Mac, chosen either as the bundle folder or as
/// a .zip that holds `VPhone.bundle` at its top level, like a release asset.
///
/// It goes through the helper's normal install verb: the app hands over a zip
/// and its SHA-256, and the helper hashes the copy it takes and validates the
/// bundle's code signature before it moves it into the store. A local build
/// has no published digest, so the hash only proves that the helper installs
/// the bytes prepared here.
nonisolated struct VPhoneLaunchpadLocalBundle: Sendable {
    /// Local builds are stored as `<version>-local`. They never replace a
    /// release of the same version, and a newer local build of that version
    /// replaces the older one.
    static let versionSuffix = "-local"
    static let bundleIdentifier = "com.vphone.bundle"

    let version: String
    let archive: URL
    let sha256: String
    /// Removed once the install finishes. It holds the zip made from a
    /// folder; a chosen .zip is read where it is.
    let workDirectory: URL

    static func isLocal(version: String) -> Bool {
        version.hasSuffix(versionSuffix)
    }

    // MARK: - Prepare

    /// Reads the version from the bundle's Info.plist and produces the zip
    /// and digest the helper expects.
    @concurrent static func prepare(_ source: URL) async throws -> VPhoneLaunchpadLocalBundle {
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory ?? false
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("vphone-launchpad-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        do {
            let infoPlist: Data
            let archive: URL
            if isDirectory {
                guard source.pathExtension == "bundle" else {
                    throw unsupported()
                }
                guard let data = try? Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")) else {
                    throw notVPhoneBundle(source)
                }
                infoPlist = data
                // The helper expects VPhone.bundle at the top of the zip, so a
                // renamed build is copied under that name first.
                var bundle = source
                if source.lastPathComponent != "VPhone.bundle" {
                    bundle = work.appendingPathComponent("VPhone.bundle", isDirectory: true)
                    try run("/usr/bin/ditto", [source.path, bundle.path])
                }
                archive = work.appendingPathComponent("VPhone.zip")
                try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.path, archive.path])
            } else {
                guard source.pathExtension.lowercased() == "zip" else {
                    throw unsupported()
                }
                guard let data = try? run("/usr/bin/unzip", ["-p", source.path, "VPhone.bundle/Contents/Info.plist"]),
                      !data.isEmpty
                else {
                    throw VPhoneLaunchpadError(
                        String(localized: "\(source.lastPathComponent) does not contain VPhone.bundle at its top level."),
                        detail: String(localized: "Zip the bundle with `ditto -c -k --keepParent VPhone.bundle VPhone.zip`, or choose the VPhone.bundle folder."),
                    )
                }
                infoPlist = data
                archive = source
            }

            let version = try version(from: infoPlist, source: source)
            return try VPhoneLaunchpadLocalBundle(
                version: version,
                archive: archive,
                sha256: sha256(of: archive),
                workDirectory: work,
            )
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    private static func version(from infoPlist: Data, source: URL) throws -> String {
        guard let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              let shortVersion = plist["CFBundleShortVersionString"] as? String
        else {
            throw notVPhoneBundle(source)
        }
        let version = shortVersion + versionSuffix
        guard VPhoneLaunchpadNames.isValidVersion(version) else {
            throw VPhoneLaunchpadError(String(localized: "VPhone.bundle has an unsupported version \"\(shortVersion)\"."))
        }
        return version
    }

    // MARK: - Helpers

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a system tool and returns its standard output.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        // Drain stderr on its own thread so a chatty tool cannot block on a
        // full pipe while stdout is read here.
        let errorData = LockedData()
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            errorData.set(error.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.get(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw VPhoneLaunchpadError(
                String(localized: "Unable to read the local build."),
                detail: message.isEmpty ? "\(tool) exited with status \(process.terminationStatus)." : message,
            )
        }
        return data
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ value: Data) {
            lock.withLock { data = value }
        }

        func get() -> Data {
            lock.withLock { data }
        }
    }

    private static func unsupported() -> VPhoneLaunchpadError {
        VPhoneLaunchpadError(String(localized: "Choose a VPhone.bundle folder or a .zip that contains one."))
    }

    private static func notVPhoneBundle(_ source: URL) -> VPhoneLaunchpadError {
        VPhoneLaunchpadError(
            String(localized: "\(source.lastPathComponent) is not a VPhone.bundle."),
            detail: String(localized: "Its Info.plist must have the bundle identifier \(bundleIdentifier) and a version."),
        )
    }
}
