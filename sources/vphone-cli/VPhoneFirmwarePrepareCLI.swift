import ArgumentParser
import FirmwarePatcher
import Foundation

struct PrepareFirmwareCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare-firmware",
        abstract: "Download, extract, merge, and generate the hybrid restore firmware tree"
    )

    static let defaultIPhoneDevice = "iPhone17,3"
    static let defaultIPhoneSource = "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw"
    static let defaultCloudOSSource = "https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349"

    @Flag(name: .customLong("list"), help: "List downloadable IPSWs for the selected device and exit.")
    var listFirmwares = false

    @Option(name: .customLong("device"), help: "iPhone device identifier.")
    var iPhoneDevice: String?

    @Option(name: .customLong("version"), help: "iOS version to resolve via the ipsw CLI.")
    var iPhoneVersion: String?

    @Option(name: .customLong("build"), help: "iOS build to resolve via the ipsw CLI.")
    var iPhoneBuild: String?

    @Option(name: .customLong("iphone-source"), help: "Direct iPhone IPSW URL or local path.")
    var iPhoneSource: String?

    @Option(name: .customLong("cloudos-source"), help: "Direct cloudOS IPSW URL or local path.")
    var cloudOSSource: String?

    @Option(name: .customLong("ipsw-dir"), help: "Directory used to cache downloaded/copied IPSWs.", transform: URL.init(fileURLWithPath:))
    var ipswDirectory: URL?

    @Option(name: .customLong("project-root"), help: "Repository root path.", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    @Argument(help: "Optional positional iPhone source/version/build selector.")
    var positionalIPhone: String?

    @Argument(help: "Optional positional cloudOS source.")
    var positionalCloudOS: String?

    mutating func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let workingDirectory = VPhoneHost.currentDirectoryURL()
        let readmeURL = projectRoot.appendingPathComponent("README.md")

        let list = listFirmwares || env["LIST_FIRMWARES"] == "1"
        let device = iPhoneDevice ?? env["IPHONE_DEVICE"] ?? Self.defaultIPhoneDevice
        var version = iPhoneVersion ?? env["IPHONE_VERSION"]
        var build = iPhoneBuild ?? env["IPHONE_BUILD"]
        var iPhoneSource = iPhoneSource ?? env["IPHONE_SOURCE"]
        var cloudOSSource = cloudOSSource ?? env["CLOUDOS_SOURCE"]
        let ipswDirectory = self.ipswDirectory ?? URL(fileURLWithPath: env["IPSW_DIR"] ?? projectRoot.appendingPathComponent("ipsws").path, isDirectory: true)

        if iPhoneSource == nil, version == nil, build == nil, let positionalIPhone {
            if looksLikeSource(positionalIPhone, relativeTo: workingDirectory) {
                iPhoneSource = positionalIPhone
            } else if looksLikeBuild(positionalIPhone) {
                build = positionalIPhone
            } else {
                version = positionalIPhone
            }
        }
        if cloudOSSource == nil, let positionalCloudOS {
            cloudOSSource = positionalCloudOS
        }

        if list {
            try await listDownloadableFirmwares(device: device, readmeURL: readmeURL)
            return
        }

        if iPhoneSource != nil, (version != nil || build != nil) {
            throw ValidationError("Use either IPHONE_SOURCE or version/build selection, not both")
        }

        if version != nil || build != nil {
            let selection = try await resolveSelector(
                device: device,
                version: version,
                build: build,
                readmeURL: readmeURL
            )
            iPhoneSource = selection.url
            print("==> Selected downloadable firmware:")
            print("    Device:  \(device)")
            print("    Version: \(selection.version)")
            print("    Build:   \(selection.build)")
            print("    URL:     \(selection.url)")
            print("    Status:  \(selection.status)")
        }

        let finalIPhoneSource = iPhoneSource ?? Self.defaultIPhoneSource
        let finalCloudOSSource = cloudOSSource ?? Self.defaultCloudOSSource

        try FileManager.default.createDirectory(at: ipswDirectory, withIntermediateDirectories: true)

        let iPhoneIPSWName = URL(string: finalIPhoneSource)?.lastPathComponent ?? URL(fileURLWithPath: finalIPhoneSource).lastPathComponent
        let iPhoneDirectoryName = iPhoneIPSWName.replacingOccurrences(of: ".ipsw", with: "")
        var cloudOSIPSWName = URL(string: finalCloudOSSource)?.lastPathComponent ?? URL(fileURLWithPath: finalCloudOSSource).lastPathComponent
        if !cloudOSIPSWName.hasSuffix(".ipsw") {
            cloudOSIPSWName = "pcc-base.ipsw"
        }
        let cloudOSDirectoryName = cloudOSIPSWName.replacingOccurrences(of: ".ipsw", with: "")

        let iPhoneIPSWPath = ipswDirectory.appendingPathComponent(iPhoneIPSWName)
        let cloudOSIPSWPath = ipswDirectory.appendingPathComponent(cloudOSIPSWName)
        let iPhoneCache = ipswDirectory.appendingPathComponent(iPhoneDirectoryName, isDirectory: true)
        let cloudOSCache = ipswDirectory.appendingPathComponent(cloudOSDirectoryName, isDirectory: true)
        let iPhoneOutput = workingDirectory.appendingPathComponent(iPhoneDirectoryName, isDirectory: true)
        let cloudOSOutput = workingDirectory.appendingPathComponent(cloudOSDirectoryName, isDirectory: true)

        print("=== prepare_firmware ===")
        print("  Device:   \(device)")
        print("  iPhone:   \(finalIPhoneSource)")
        print("  CloudOS:  \(finalCloudOSSource)")
        print("  IPSWs:    \(ipswDirectory.path)")
        print("  Output:   \(iPhoneOutput.path)/")
        print("")

        try await fetch(source: finalIPhoneSource, outputURL: iPhoneIPSWPath, workingDirectory: workingDirectory)
        try await fetch(source: finalCloudOSSource, outputURL: cloudOSIPSWPath, workingDirectory: workingDirectory)

        try await extractArchive(ipswURL: iPhoneIPSWPath, cacheURL: iPhoneCache, outputURL: iPhoneOutput)
        try await extractArchive(ipswURL: cloudOSIPSWPath, cacheURL: cloudOSCache, outputURL: cloudOSOutput)

        try cleanupOldRestoreDirectories(keeping: iPhoneOutput.lastPathComponent, in: workingDirectory)
        try mergeCloudOS(into: iPhoneOutput, from: cloudOSOutput)

        let buildManifestBackup = iPhoneOutput.appendingPathComponent("BuildManifest-iPhone.plist")
        let buildManifest = iPhoneOutput.appendingPathComponent("BuildManifest.plist")
        if FileManager.default.fileExists(atPath: buildManifestBackup.path) {
            try FileManager.default.removeItem(at: buildManifestBackup)
        }
        try FileManager.default.copyItem(at: buildManifest, to: buildManifestBackup)

        print("==> Generating hybrid plists ...")
        try FirmwareManifest.generate(iPhoneDir: iPhoneOutput, cloudOSDir: cloudOSOutput)

        print("==> Cleaning up ...")
        try? FileManager.default.removeItem(at: cloudOSOutput)

        print("==> Done. Restore directory ready: \(iPhoneOutput.lastPathComponent)/")
        print("    Run 'make fw_patch' to patch boot-chain components.")
    }
}

private extension PrepareFirmwareCLI {
    struct Selection {
        let version: String
        let build: String
        let url: String
        let status: String
    }

    func looksLikeSource(_ value: String, relativeTo baseURL: URL) -> Bool {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return true
        }
        if value.hasSuffix(".ipsw") || value.contains("/") {
            return true
        }
        return FileManager.default.fileExists(atPath: resolveLocalPath(value, relativeTo: baseURL).path)
    }

    func looksLikeBuild(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{2}[A-Z][0-9A-Z]+$"#, options: .regularExpression) != nil
    }

    func resolveLocalPath(_ path: String, relativeTo baseURL: URL) -> URL {
        let url = URL(fileURLWithPath: path)
        if url.path.hasPrefix("/") {
            return url
        }
        return baseURL.appendingPathComponent(path)
    }

    func supportedPairs(readmeURL: URL, device: String) throws -> Set<String> {
        let deviceSuffix = String(device.dropFirst("iPhone".count))
        let contents = try String(contentsOf: readmeURL, encoding: .utf8)
        var inSection = false
        var pairs = Set<String>()
        let regex = try NSRegularExpression(pattern: #"`(?<device>\d+,\d+)_(?<version>[^_`]+)_(?<build>[A-Za-z0-9]+)`"#)
        for line in contents.split(whereSeparator: \.isNewline) {
            let string = String(line)
            if string.hasPrefix("## Tested Environments") {
                inSection = true
                continue
            }
            if inSection, string.hasPrefix("## ") {
                break
            }
            if !inSection {
                continue
            }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            for match in regex.matches(in: string, range: range) {
                guard
                    let deviceRange = Range(match.range(withName: "device"), in: string),
                    let versionRange = Range(match.range(withName: "version"), in: string),
                    let buildRange = Range(match.range(withName: "build"), in: string)
                else {
                    continue
                }
                if String(string[deviceRange]) == deviceSuffix {
                    pairs.insert("\(string[versionRange])|\(string[buildRange])")
                }
            }
        }
        return pairs
    }

    func downloadableIPSWURLs(device: String) async throws -> [String] {
        let result = try await VPhoneHost.runCommand(
            "ipsw",
            arguments: ["download", "ipsw", "--device", device, "--urls"],
            requireSuccess: true
        )
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func parseDownloadableIPSWs(device: String, urls: [String]) -> [(version: String, build: String, url: String)] {
        let pattern = "/\(NSRegularExpression.escapedPattern(for: device))_(?<version>[^_]+)_(?<build>[A-Za-z0-9]+)_Restore\\.ipsw$"
        let regex = try? NSRegularExpression(pattern: pattern)
        return urls.compactMap { line in
            guard let regex else { return nil }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let versionRange = Range(match.range(withName: "version"), in: line),
                  let buildRange = Range(match.range(withName: "build"), in: line)
            else {
                return nil
            }
            return (String(line[versionRange]), String(line[buildRange]), line)
        }
    }

    func listDownloadableFirmwares(device: String, readmeURL: URL) async throws {
        let urls = try await downloadableIPSWURLs(device: device)
        let supported = try supportedPairs(readmeURL: readmeURL, device: device)
        let parsedRows = parseDownloadableIPSWs(device: device, urls: urls)
        let encodedRows = parsedRows.map { "\($0.version)|\($0.build)|\($0.url)" }
        let uniqueRows = Array(Set(encodedRows))
        let rows = uniqueRows.compactMap { encoded -> (String, String, String)? in
            let parts = encoded.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return (parts[0], parts[1], parts[2])
        }.sorted { lhs, rhs in
            let lhsKey = versionSortKey(lhs.0)
            let rhsKey = versionSortKey(rhs.0)
            if compareVersionKeys(lhsKey, rhsKey) != .orderedSame {
                return compareVersionKeys(lhsKey, rhsKey) == .orderedDescending
            }
            return lhs.1 > rhs.1
        }

        guard !rows.isEmpty else {
            throw ValidationError("No downloadable IPSWs found for \(device)")
        }

        print("Available downloadable IPSWs for \(device):")
        print("")
        print(String(format: "%-12s %-10s %s", "VERSION", "BUILD", "STATUS"))
        for row in rows {
            let status = supported.contains("\(row.0)|\(row.1)") ? "Supported" : "Not Tested"
            print(String(format: "%-12s %-10s %s", row.0, row.1, status))
        }
    }

    func resolveSelector(device: String, version: String?, build: String?, readmeURL: URL) async throws -> Selection {
        let urls = try await downloadableIPSWURLs(device: device)
        let supported = try supportedPairs(readmeURL: readmeURL, device: device)
        let matches = parseDownloadableIPSWs(device: device, urls: urls).filter { entry in
            if let version, entry.version != version {
                return false
            }
            if let build, entry.build != build {
                return false
            }
            return true
        }

        guard !matches.isEmpty else {
            throw ValidationError("No downloadable IPSW matched device=\(device) version=\(version ?? "-") build=\(build ?? "-")")
        }

        if let version, build == nil {
            let uniqueBuilds = Set(matches.map(\.build))
            if uniqueBuilds.count > 1 {
                let builds = matches
                    .map(\.build)
                    .sorted(by: >)
                    .joined(separator: ", ")
                throw ValidationError("Version \(version) is ambiguous for \(device); specify one of these builds: \(builds)")
            }
        }

        let selected = matches.sorted { lhs, rhs in
            lhs.build > rhs.build
        }[0]
        let status = supported.contains("\(selected.version)|\(selected.build)") ? "Supported" : "Not Tested"
        return Selection(version: selected.version, build: selected.build, url: selected.url, status: status)
    }

    func versionSortKey(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    func compareVersionKeys(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let maxCount = max(lhs.count, rhs.count)
        for index in 0..<maxCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left > right {
                return .orderedDescending
            }
            if left < right {
                return .orderedAscending
            }
        }
        return .orderedSame
    }

    func fetch(source: String, outputURL: URL, workingDirectory: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if !source.hasPrefix("http://"), !source.hasPrefix("https://") {
                print("==> Skipping: '\(outputURL.lastPathComponent)' already exists.")
                return
            }
            print("==> Found existing \(outputURL.lastPathComponent), skipping download.")
            return
        }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            print("==> Downloading \(outputURL.lastPathComponent) ...")
            _ = try await VPhoneHost.runCommand(
                "/usr/bin/curl",
                arguments: ["--fail", "--location", "--progress-bar", "-o", outputURL.path, source],
                requireSuccess: true
            )
            return
        }

        let localURL = resolveLocalPath(source, relativeTo: workingDirectory)
        try VPhoneHost.requireFile(localURL)
        print("==> Copying \(localURL.lastPathComponent) ...")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: localURL, to: outputURL)
    }

    func extractArchive(ipswURL: URL, cacheURL: URL, outputURL: URL) async throws {
        if !directoryHasContents(cacheURL) {
            print("==> Extracting \(ipswURL.lastPathComponent) ...")
            try? FileManager.default.removeItem(at: cacheURL)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            _ = try await VPhoneHost.runCommand(
                "/usr/bin/unzip",
                arguments: ["-oq", ipswURL.path, "-d", cacheURL.path],
                requireSuccess: true
            )
        } else {
            print("==> Cached: \(cacheURL.lastPathComponent)")
        }

        try? FileManager.default.removeItem(at: outputURL)
        print("==> Cloning \(cacheURL.lastPathComponent) -> \(outputURL.lastPathComponent) ...")
        try FileManager.default.copyItem(at: cacheURL, to: outputURL)
    }

    func directoryHasContents(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        return enumerator.nextObject() != nil
    }

    func cleanupOldRestoreDirectories(keeping keptDirectoryName: String, in workingDirectory: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let stale = try entries.filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true &&
                url.lastPathComponent != keptDirectoryName &&
                url.lastPathComponent.contains("Restore")
        }
        guard !stale.isEmpty else { return }
        print("==> Removing stale restore directories ...")
        for url in stale {
            print("    rm -rf \(url.lastPathComponent)")
            try FileManager.default.removeItem(at: url)
        }
    }

    func mergeCloudOS(into iPhoneDirectory: URL, from cloudOSDirectory: URL) throws {
        print("==> Importing cloudOS firmware components ...")
        try copyMatching(prefix: "kernelcache.", from: cloudOSDirectory, to: iPhoneDirectory, overwrite: true)

        for subdirectory in ["agx", "all_flash", "ane", "dfu", "pmp"] {
            let source = cloudOSDirectory.appendingPathComponent("Firmware/\(subdirectory)", isDirectory: true)
            let destination = iPhoneDirectory.appendingPathComponent("Firmware/\(subdirectory)", isDirectory: true)
            try copyContents(of: source, to: destination, overwrite: true)
        }

        try copyMatching(suffix: ".im4p", from: cloudOSDirectory.appendingPathComponent("Firmware", isDirectory: true), to: iPhoneDirectory.appendingPathComponent("Firmware", isDirectory: true), overwrite: true)
        try copyMatching(suffix: ".dmg", from: cloudOSDirectory, to: iPhoneDirectory, overwrite: false)
        try copyMatching(suffix: ".dmg.trustcache", from: cloudOSDirectory.appendingPathComponent("Firmware", isDirectory: true), to: iPhoneDirectory.appendingPathComponent("Firmware", isDirectory: true), overwrite: false)
    }

    func copyMatching(prefix: String? = nil, suffix: String? = nil, from sourceDirectory: URL, to destinationDirectory: URL, overwrite: Bool) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: [.isRegularFileKey])
        for sourceURL in contents {
            let name = sourceURL.lastPathComponent
            if let prefix, !name.hasPrefix(prefix) {
                continue
            }
            if let suffix, !name.hasSuffix(suffix) {
                continue
            }
            let destinationURL = destinationDirectory.appendingPathComponent(name)
            if !overwrite, FileManager.default.fileExists(atPath: destinationURL.path) {
                continue
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    func copyContents(of sourceDirectory: URL, to destinationDirectory: URL, overwrite: Bool) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        for sourceURL in contents {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if !overwrite, FileManager.default.fileExists(atPath: destinationURL.path) {
                continue
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}
