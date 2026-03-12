import ArgumentParser
import Foundation

struct BuildHostCLI: AsyncParsableCommand {
    enum BuildConfiguration: String, ExpressibleByArgument {
        case debug
        case release

        var swiftBuildArgument: String {
            switch self {
            case .debug: "debug"
            case .release: "release"
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "build-host",
        abstract: "Build and sign the host-side vphone-cli binary"
    )

    @Option(name: .customLong("project-root"), help: "Project root path.", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    @Option(name: .customLong("configuration"), help: "Swift build configuration.")
    var configuration: BuildConfiguration = .release

    mutating func run() async throws {
        let result = try await HostBuildSupport.buildHostBinary(
            projectRoot: projectRoot.standardizedFileURL,
            configuration: configuration
        )
        print("[+] Built host binary: \(result.path)")
    }
}

struct BundleAppCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-app",
        abstract: "Assemble a signed vphone-cli.app bundle"
    )

    @Option(name: .customLong("project-root"), help: "Project root path.", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    @Option(name: .customLong("bundle-path"), help: "Output app bundle path.", transform: URL.init(fileURLWithPath:))
    var bundlePath: URL?

    mutating func run() async throws {
        let projectRoot = projectRoot.standardizedFileURL
        let outputURL = try await HostBuildSupport.bundleApp(
            projectRoot: projectRoot,
            bundleURL: (bundlePath ?? HostBuildSupport.defaultBundleURL(projectRoot: projectRoot)).standardizedFileURL
        )
        print("[+] Bundled app: \(outputURL.path)")
    }
}

enum HostBuildSupport {
    static func defaultBundleURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".build/vphone-cli.app")
    }

    static func buildInfoURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("sources/vphone-cli/VPhoneBuildInfo.swift")
    }

    static func entitlementsURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("sources/vphone.entitlements")
    }

    static func releaseBinaryURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".build/release/vphone-cli")
    }

    static func builtBinaryURL(projectRoot: URL, configuration: BuildHostCLI.BuildConfiguration) -> URL {
        projectRoot.appendingPathComponent(".build/\(configuration.swiftBuildArgument)/vphone-cli")
    }

    static func writeBuildInfo(projectRoot: URL, gitHash: String) throws {
        let contents = """
        // Auto-generated — do not edit
        enum VPhoneBuildInfo { static let commitHash = "\(gitHash)" }
        """
        try contents.write(to: buildInfoURL(projectRoot: projectRoot), atomically: true, encoding: .utf8)
    }

    static func currentGitHash(projectRoot: URL) async throws -> String {
        let result = try await VPhoneHost.runCommand(
            "git",
            arguments: ["-C", projectRoot.path, "rev-parse", "--short", "HEAD"],
            requireSuccess: false
        )
        let hash = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? "unknown" : hash
    }

    static func buildHostBinary(projectRoot: URL, configuration: BuildHostCLI.BuildConfiguration) async throws -> URL {
        let gitHash = try await currentGitHash(projectRoot: projectRoot)
        try writeBuildInfo(projectRoot: projectRoot, gitHash: gitHash)
        _ = try await VPhoneHost.runCommand(
            "swift",
            arguments: ["build", "-c", configuration.swiftBuildArgument, "--package-path", projectRoot.path],
            requireSuccess: true
        )

        let binaryURL = builtBinaryURL(projectRoot: projectRoot, configuration: configuration)
        _ = try await VPhoneHost.runCommand(
            "codesign",
            arguments: ["--force", "--sign", "-", "--entitlements", entitlementsURL(projectRoot: projectRoot).path, binaryURL.path],
            requireSuccess: true
        )
        return binaryURL
    }

    static func bundleApp(projectRoot: URL, bundleURL: URL) async throws -> URL {
        let releaseBinary = try await buildHostBinary(projectRoot: projectRoot, configuration: .release)
        let ldidURL = try VPhoneHost.resolveExecutableURL(
            explicit: nil,
            name: "ldid",
            additionalSearchDirectories: [projectRoot.appendingPathComponent(".tools/bin", isDirectory: true)]
        )

        let fileManager = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let bundledBinaryURL = macOSURL.appendingPathComponent("vphone-cli")
        let bundledLDIDURL = macOSURL.appendingPathComponent("ldid")

        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        try fileManager.copyItem(at: releaseBinary, to: bundledBinaryURL)
        try fileManager.copyItem(at: projectRoot.appendingPathComponent("sources/Info.plist"), to: contentsURL.appendingPathComponent("Info.plist"))
        try fileManager.copyItem(at: projectRoot.appendingPathComponent("sources/AppIcon.icns"), to: resourcesURL.appendingPathComponent("AppIcon.icns"))
        try fileManager.copyItem(at: projectRoot.appendingPathComponent("scripts/vphoned/signcert.p12"), to: resourcesURL.appendingPathComponent("signcert.p12"))
        try fileManager.copyItem(at: ldidURL, to: bundledLDIDURL)

        _ = try await VPhoneHost.runCommand(
            "codesign",
            arguments: ["--force", "--sign", "-", bundledLDIDURL.path],
            requireSuccess: true
        )
        _ = try await VPhoneHost.runCommand(
            "codesign",
            arguments: ["--force", "--sign", "-", "--entitlements", entitlementsURL(projectRoot: projectRoot).path, bundledBinaryURL.path],
            requireSuccess: true
        )
        return bundleURL
    }
}
