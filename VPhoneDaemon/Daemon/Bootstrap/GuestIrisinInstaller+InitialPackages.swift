import Darwin
import Foundation
import VphonedNative

// MARK: - Initial packages

extension GuestIrisinInstaller {
    /// What a guest installs first: the base system, apt and dpkg, the
    /// shells, OpenSSH and the OwnGoal apps, in one transaction.
    static let initialPackages = ["owngoal-bootstrap-vphone"]

    /// The first package installation, through Irisin's own command line:
    /// `irisin-cli install --bootstrap-install` from the repositories
    /// Irisin's onboarding recommends, which irisin-cli refreshes into a
    /// catalogue of its own. Bootstrap Install places every package's files
    /// before any script runs: a first installation's scripts need the shell
    /// and tools the same transaction brings. The app's catalogue is left
    /// alone; the repositories are the app's to add when it is opened.
    static func installPackages(_ packages: [String]) throws -> [String: Any] {
        guard !GuestBootstrapPlatform.isTVOS else {
            return ["packages": [String](), "skipped": "Irisin's Apple TV package has no irisin-cli"]
        }
        installLock.lock()
        defer { installLock.unlock() }
        guard let installation = try completedBootstrap() else {
            throw GuestAPIError.operationFailed("Install the bootstrap before its packages")
        }
        let cli = installation.root + "/usr/bin/irisin-cli"
        guard access(cli, X_OK) == 0 else {
            throw GuestAPIError.operationFailed("This Irisin has no irisin-cli")
        }
        let help = try run(cli, ["install", "--help"])
        guard help.output.contains("--bootstrap-install"), help.output.contains("--repository") else {
            throw GuestAPIError.operationFailed(
                "This Irisin's irisin-cli cannot install from named repositories with Bootstrap Install; a newer Irisin can"
            )
        }
        let repositories = try recommendedRepositories(root: installation.root)
        setProgress(["phase": "packages", "layout": installation.layout, "packages": packages])
        let arguments = ["install", "-y", "--bootstrap-install"]
            + repositories.flatMap { ["--repository", $0] } + packages
        let result = try run(cli, arguments)
        guard result.status == 0 else {
            let lines = (result.output + result.errors).split(separator: "\n").suffix(6).joined(separator: "\n")
            let error = "irisin-cli install exited with status \(result.status):\n\(lines)"
            setProgress(["phase": "failed", "layout": installation.layout, "packages": packages, "error": error])
            throw GuestAPIError.operationFailed(error)
        }
        setProgress(["phase": "completed", "layout": installation.layout, "packages": packages])
        return ["packages": packages, "repositories": repositories, "jbroot": installation.root]
    }

    private static func recommendedRepositories(root: String) throws -> [String] {
        let app = URL(fileURLWithPath: root + "/Applications/irisin.app", isDirectory: true)
        guard let architecture = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["IrisinCurrentArchitecture"] as? String else {
            throw GuestAPIError.operationFailed("Irisin's Info.plist names no bootstrap architecture")
        }
        func list(_ name: String) -> [[String: Any]]? {
            NSArray(contentsOf: app.appendingPathComponent(name + ".plist")) as? [[String: Any]]
        }
        let sources = GuestBootstrapPlatform.recommendedSources(
            managed: list("default-list-managed"),
            packaged: list("default-list-\(architecture)"),
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        )
        guard !sources.isEmpty else {
            throw GuestAPIError.operationFailed("Irisin recommends no repositories for \(architecture) on this system")
        }
        return sources
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let words = [path] + arguments
        var argv: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) } + [nil]
        defer { argv.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var status: Int32 = 0
        var output: UnsafeMutablePointer<CChar>?
        var errors: UnsafeMutablePointer<CChar>?
        defer {
            free(output)
            free(errors)
        }
        let failure = vp_spawn_collect(path, &argv, nil, &status, &output, &errors)
        guard failure == 0 else {
            throw GuestAPIError.operationFailed("\(path): \(String(cString: strerror(failure)))")
        }
        let signal = status & 0x7F
        return (
            signal == 0 ? (status >> 8) & 0xFF : -1,
            output.map { String(cString: $0) } ?? "",
            errors.map { String(cString: $0) } ?? "",
        )
    }
}
