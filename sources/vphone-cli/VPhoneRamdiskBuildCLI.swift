import ArgumentParser
import FirmwarePatcher
import Foundation
import Img4tool
import SWCompression
import TrustCache

struct BuildRamdiskCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-ramdisk",
        abstract: "Build a signed SSH ramdisk for a patched VM restore tree"
    )

    private static let outputDirectoryName = "Ramdisk"
    private static let tempDirectoryName = "ramdisk_builder_temp"
    private static let inputDirectoryName = "ramdisk_input"
    private static let inputArchiveName = "ramdisk_input.tar.zst"
    private static let restoredExternalPath = "usr/local/bin/restored_external"
    private static let restoredExternalSerialMarker = Data("SSHRD_Script Sep 22 2022 18:56:50".utf8)
    private static let defaultIBECBootArgs = Data("serial=3 -v debug=0x2014e %s".utf8)
    private static let ramdiskBootArgs = Data("serial=3 rd=md0 debug=0x2014e -v wdt=-1 %s".utf8)
    private static let txmFourCC = "trxm"
    private static let kernelFourCC = "rkrn"
    private static let ramdiskKernelSuffix = ".ramdisk"
    private static let ramdiskKernelImageName = "krnl.ramdisk.img4"
    private static let expandedRamdiskSize = "512m"
    private static let ramdiskRemove = [
        "usr/bin/img4tool",
        "usr/bin/img4",
        "usr/sbin/dietappleh13camerad",
        "usr/sbin/dietappleh16camerad",
        "usr/local/bin/wget",
        "usr/local/bin/procexp",
    ]
    private static let signDirectories = [
        "usr/local/bin",
        "usr/local/lib",
        "usr/bin",
        "bin",
        "usr/lib",
        "sbin",
        "usr/sbin",
        "usr/libexec",
    ]

    @Argument(help: "VM directory. Defaults to the current directory.", transform: URL.init(fileURLWithPath:))
    var vmDirectory: URL = VPhoneHost.currentDirectoryURL()

    mutating func run() async throws {
        let vmDirectory = vmDirectory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: vmDirectory.path) else {
            throw ValidationError("Not a directory: \(vmDirectory.path)")
        }

        let shshURL = try findSHSH(in: vmDirectory.appendingPathComponent("shsh", isDirectory: true))
        let restoreDirectory = try findRestoreDirectory(in: vmDirectory)
        try checkPrerequisites()
        let inputDirectory = try await setupInput(in: vmDirectory)

        let tempDirectory = vmDirectory.appendingPathComponent(Self.tempDirectoryName, isDirectory: true)
        let outputDirectory = vmDirectory.appendingPathComponent(Self.outputDirectoryName, isDirectory: true)
        let mountpoint = vmDirectory.appendingPathComponent("SSHRD", isDirectory: true)
        try recreateDirectory(tempDirectory)
        try recreateDirectory(outputDirectory)
        try recreateDirectory(mountpoint)

        print("[*] VM directory:      \(vmDirectory.path)")
        print("[*] Restore directory: \(restoreDirectory.path)")
        print("[*] SHSH blob:         \(shshURL.path)")

        let im4mURL = tempDirectory.appendingPathComponent("vphone.im4m")
        print("\n[*] Extracting IM4M from SHSH...")
        let im4mData = try await extractIM4M(from: shshURL)
        try im4mData.write(to: im4mURL)

        try await buildIBSS(restoreDirectory: restoreDirectory, outputDirectory: outputDirectory, im4mData: im4mData)
        try await buildIBEC(restoreDirectory: restoreDirectory, outputDirectory: outputDirectory, im4mData: im4mData)
        try await signExistingComponent(
            restoreDirectory: restoreDirectory,
            pattern: "Firmware/sptm.vresearch1.release.im4p",
            label: "SPTM",
            outputName: "sptm.vresearch1.release.img4",
            tag: "sptm",
            outputDirectory: outputDirectory,
            im4mData: im4mData
        )
        try await signExistingComponent(
            restoreDirectory: restoreDirectory,
            pattern: "Firmware/all_flash/DeviceTree.vphone600ap.im4p",
            label: "DeviceTree",
            outputName: "DeviceTree.vphone600ap.img4",
            tag: "rdtr",
            outputDirectory: outputDirectory,
            im4mData: im4mData
        )
        try await signExistingComponent(
            restoreDirectory: restoreDirectory,
            pattern: "Firmware/all_flash/sep-firmware.vresearch101.RELEASE.im4p",
            label: "SEP",
            outputName: "sep-firmware.vresearch101.RELEASE.img4",
            tag: "rsep",
            outputDirectory: outputDirectory,
            im4mData: im4mData
        )

        try await buildTXM(restoreDirectory: restoreDirectory, tempDirectory: tempDirectory, outputDirectory: outputDirectory, im4mData: im4mData)
        try await buildKernels(restoreDirectory: restoreDirectory, tempDirectory: tempDirectory, outputDirectory: outputDirectory, im4mData: im4mData)
        try await buildRamdiskImage(
            restoreDirectory: restoreDirectory,
            vmDirectory: vmDirectory,
            inputDirectory: inputDirectory,
            outputDirectory: outputDirectory,
            tempDirectory: tempDirectory,
            mountpoint: mountpoint,
            im4mData: im4mData
        )

        print("\n[*] Cleaning up \(Self.tempDirectoryName)/...")
        try? FileManager.default.removeItem(at: tempDirectory)
        try? FileManager.default.removeItem(at: mountpoint)

        print("\n============================================================")
        print("  Ramdisk build complete!")
        print("  Output: \(outputDirectory.path)/")
        print("============================================================")
        for fileURL in try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: [.fileSizeKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print(String(format: "    %-45s %10d bytes", fileURL.lastPathComponent, size))
        }
    }
}

private extension BuildRamdiskCLI {
    func findSHSH(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["shsh", "shsh2", "im4m"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = files.first else {
            throw ValidationError("No SHSH blob found in \(directory.path)/. Place your .shsh file in the shsh/ directory.")
        }
        return first
    }

    func findRestoreDirectory(in vmDirectory: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(at: vmDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        guard let restoreDirectory = try entries.first(where: { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true && url.lastPathComponent.contains("Restore")
        }) else {
            throw ValidationError("No *Restore* directory found in \(vmDirectory.path)")
        }
        return restoreDirectory
    }

    func checkPrerequisites() throws {
        let required = [
            ("ldid", "vendored via make setup_tools"),
        ]
        let missing = required.compactMap { command, package in
            which(command) == nil ? "\(command) — \(package)" : nil
        }
        if !missing.isEmpty {
            throw ValidationError("Missing required tools:\n  \(missing.joined(separator: "\n  "))\nRun: make setup_tools")
        }
    }

    func setupInput(in vmDirectory: URL) async throws -> URL {
        let inputDirectory = vmDirectory.appendingPathComponent(Self.inputDirectoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: inputDirectory.path) {
            return inputDirectory
        }

        let scriptResources = VPhoneHost.currentDirectoryURL().appendingPathComponent("scripts/resources", isDirectory: true)
        let candidates = [
            scriptResources.appendingPathComponent(Self.inputArchiveName),
            VPhoneHost.currentDirectoryURL().appendingPathComponent("scripts", isDirectory: true).appendingPathComponent(Self.inputArchiveName),
            vmDirectory.appendingPathComponent(Self.inputArchiveName),
        ]

        guard let archiveURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ValidationError("Neither \(Self.inputDirectoryName)/ nor \(Self.inputArchiveName) found.")
        }

        print("[*] Setting up \(Self.inputDirectoryName)/...")
        try VPhoneArchive.extractTarZstdArchive(archiveURL, to: vmDirectory)
        return inputDirectory
    }

    func recreateDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func which(_ command: String) -> String? {
        if let full = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map({ URL(fileURLWithPath: $0).appendingPathComponent(command).path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            return full
        }
        return nil
    }

    func extractIM4M(from shshURL: URL) async throws -> Data {
        var data = try Data(contentsOf: shshURL)
        if data.starts(with: [0x1F, 0x8B]) {
            data = try VPhoneArchive.decompressGzipFile(at: shshURL)
        }

        if (try? IM4M(data)) != nil {
            return data
        }

        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let im4mData = findIM4MData(in: plist) else {
            throw ValidationError("Could not locate an IM4M ticket inside \(shshURL.path)")
        }
        _ = try IM4M(im4mData)
        return im4mData
    }

    func findIM4MData(in value: Any) -> Data? {
        if let data = value as? Data, (try? IM4M(data)) != nil {
            return data
        }
        if let dictionary = value as? [String: Any] {
            for candidate in ["ApImg4Ticket", "ApTicket", "IM4M"] {
                if let nested = dictionary[candidate], let data = findIM4MData(in: nested) {
                    return data
                }
            }
            for nested in dictionary.values {
                if let data = findIM4MData(in: nested) {
                    return data
                }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let data = findIM4MData(in: nested) {
                    return data
                }
            }
        }
        return nil
    }

    func findFile(in baseDirectory: URL, patterns: [String], label: String) throws -> URL {
        for pattern in patterns {
            let result = try glob(pattern: baseDirectory.appendingPathComponent(pattern).path).sorted()
            if let first = result.first {
                return URL(fileURLWithPath: first)
            }
        }
        let joined = patterns.map { baseDirectory.appendingPathComponent($0).path }.joined(separator: "\n    ")
        throw ValidationError("\(label) not found. Searched patterns:\n    \(joined)")
    }

    func glob(pattern: String) throws -> [String] {
        let result = try awaitSyncGlob(pattern)
        return result
    }

    func awaitSyncGlob(_ pattern: String) throws -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }
        let flags = GLOB_TILDE
        let code = pattern.withCString { Darwin.glob($0, flags, nil, &gt) }
        if code == GLOB_NOMATCH {
            return []
        }
        guard code == 0 else {
            throw VPhoneHostError.invalidArgument("glob failed for pattern: \(pattern)")
        }
        return (0..<Int(gt.gl_matchc)).compactMap { index in
            guard let path = gt.gl_pathv[index] else { return nil }
            return String(cString: path)
        }
    }

    func signIMG4(im4pData: Data, im4mData: Data, outputURL: URL, tag: String? = nil) throws {
        let base = try IM4P(im4pData)
        let im4p = try (tag == nil ? base : base.renamed(to: tag!))
        let img4 = try IMG4(im4p: im4p, im4m: IM4M(im4mData))
        try img4.data.write(to: outputURL)
    }

    func loadPayloadAndOriginal(from url: URL) throws -> (payload: Data, original: Data, im4p: IM4P?) {
        let original = try Data(contentsOf: url)
        if let im4p = try? IM4P(original) {
            return (try im4p.payload(), original, im4p)
        }
        if let img4 = try? IMG4(original) {
            let im4p = try img4.im4p()
            return (try im4p.payload(), original, im4p)
        }
        return (original, original, nil)
    }

    func createCompressedIM4P(fourcc: String, description: String, payload: Data, originalRaw: Data?) throws -> Data {
        let rebuilt = try IM4P(fourcc: fourcc, description: description, payload: payload, compression: "lzfse").data
        guard let originalRaw else {
            return rebuilt
        }
        return try appendPAYPIfPresent(from: originalRaw, to: rebuilt)
    }

    func appendPAYPIfPresent(from original: Data, to rebuilt: Data) throws -> Data {
        let marker = Data("PAYP".utf8)
        guard let markerRange = original.range(of: marker, options: .backwards),
              markerRange.lowerBound >= 10
        else {
            return rebuilt
        }
        let payp = original[(markerRange.lowerBound - 10)..<original.endIndex]
        var output = rebuilt
        try updateDERLength(of: &output, adding: payp.count)
        output.append(payp)
        return output
    }

    func updateDERLength(of data: inout Data, adding extraBytes: Int) throws {
        guard data.count >= 2, data[0] == 0x30 else {
            throw Img4Error.invalidFormat("rebuilt IM4P missing top-level DER sequence")
        }
        let lengthByte = data[1]
        let headerRange: Range<Int>
        let currentLength: Int
        if lengthByte & 0x80 == 0 {
            headerRange = 1..<2
            currentLength = Int(lengthByte)
        } else {
            let lengthOfLength = Int(lengthByte & 0x7F)
            let start = 2
            let end = start + lengthOfLength
            guard end <= data.count else {
                throw Img4Error.invalidFormat("invalid DER length field")
            }
            headerRange = 1..<end
            currentLength = data[start..<end].reduce(0) { ($0 << 8) | Int($1) }
        }
        let replacement = derLengthBytes(currentLength + extraBytes)
        data.replaceSubrange(headerRange, with: replacement)
    }

    func derLengthBytes(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        }
        bytes.reverse()
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    func buildIBSS(restoreDirectory: URL, outputDirectory: URL, im4mData: Data) async throws {
        print("\n============================================================")
        print("  1. iBSS (already patched — extract & sign)")
        print("============================================================")
        let sourceURL = try findFile(in: restoreDirectory, patterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"], label: "iBSS")
        let sourceData = try Data(contentsOf: sourceURL)
        let im4p = try IM4P(sourceData)
        let rebuilt = try IM4P(fourcc: im4p.fourcc, description: im4p.description, payload: try im4p.payload())
        try signIMG4(
            im4pData: rebuilt.data,
            im4mData: im4mData,
            outputURL: outputDirectory.appendingPathComponent("iBSS.vresearch101.RELEASE.img4")
        )
        print("  [+] iBSS.vresearch101.RELEASE.img4")
    }

    func buildIBEC(restoreDirectory: URL, outputDirectory: URL, im4mData: Data) async throws {
        print("\n============================================================")
        print("  2. iBEC (patch boot-args for ramdisk)")
        print("============================================================")
        let sourceURL = try findFile(in: restoreDirectory, patterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"], label: "iBEC")
        let sourceData = try Data(contentsOf: sourceURL)
        let im4p = try IM4P(sourceData)
        var payload = try im4p.payload()
        _ = patchIBECBootArgs(&payload)
        let rebuilt = try IM4P(fourcc: im4p.fourcc, description: im4p.description, payload: payload)
        try signIMG4(
            im4pData: rebuilt.data,
            im4mData: im4mData,
            outputURL: outputDirectory.appendingPathComponent("iBEC.vresearch101.RELEASE.img4")
        )
        print("  [+] iBEC.vresearch101.RELEASE.img4")
    }

    func patchIBECBootArgs(_ payload: inout Data) -> Bool {
        guard let range = payload.range(of: Self.defaultIBECBootArgs) else {
            print("  [-] boot-args: existing string not found")
            return false
        }
        let args = Self.ramdiskBootArgs + Data([0])
        payload.replaceSubrange(range.lowerBound..<(range.lowerBound + args.count), with: args)
        var end = range.lowerBound + args.count
        while end < payload.count, payload[end] != 0 {
            payload[end] = 0
            end += 1
        }
        print("  boot-args -> \"\(String(decoding: Self.ramdiskBootArgs, as: UTF8.self))\" at 0x\(String(range.lowerBound, radix: 16).uppercased())")
        return true
    }

    func signExistingComponent(
        restoreDirectory: URL,
        pattern: String,
        label: String,
        outputName: String,
        tag: String,
        outputDirectory: URL,
        im4mData: Data
    ) async throws {
        let step: String
        switch label {
        case "SPTM": step = "3. SPTM (sign only)"
        case "DeviceTree": step = "4. DeviceTree (sign only)"
        default: step = "5. SEP (sign only)"
        }
        print("\n============================================================")
        print("  \(step)")
        print("============================================================")
        let sourceURL = try findFile(in: restoreDirectory, patterns: [pattern], label: label)
        try signIMG4(
            im4pData: try Data(contentsOf: sourceURL),
            im4mData: im4mData,
            outputURL: outputDirectory.appendingPathComponent(outputName),
            tag: tag
        )
        print("  [+] \(outputName)")
    }

    func buildTXM(restoreDirectory: URL, tempDirectory: URL, outputDirectory: URL, im4mData: Data) async throws {
        print("\n============================================================")
        print("  6. TXM (patch release variant)")
        print("============================================================")
        let sourceURL = try findFile(in: restoreDirectory, patterns: ["Firmware/txm.iphoneos.release.im4p"], label: "TXM")
        let (payload, originalRaw, _) = try loadPayloadAndOriginal(from: sourceURL)
        let patcher = TXMPatcher(data: payload, verbose: false)
        _ = try patcher.apply()
        let rebuilt = try createCompressedIM4P(
            fourcc: Self.txmFourCC,
            description: Self.txmFourCC,
            payload: patcher.patchedData,
            originalRaw: originalRaw
        )
        try signIMG4(
            im4pData: rebuilt,
            im4mData: im4mData,
            outputURL: outputDirectory.appendingPathComponent("txm.img4")
        )
        print("  [+] txm.img4")
    }

    func buildKernels(restoreDirectory: URL, tempDirectory: URL, outputDirectory: URL, im4mData: Data) async throws {
        print("\n============================================================")
        print("  7. Kernelcache (already patched — repack as rkrn)")
        print("============================================================")
        let restoreKernelURL = try findFile(in: restoreDirectory, patterns: ["kernelcache.research.vphone600"], label: "kernelcache")
        if let ramdiskKernelURL = try deriveRamdiskKernelSource(restoreKernelURL: restoreKernelURL, tempDirectory: tempDirectory) {
            print("  building \(Self.ramdiskKernelImageName) from ramdisk kernel source")
            try buildKernelImage(
                sourceURL: ramdiskKernelURL,
                outputURL: outputDirectory.appendingPathComponent(Self.ramdiskKernelImageName),
                im4mData: im4mData
            )
            print("  building krnl.img4 from restore kernel")
        }
        try buildKernelImage(
            sourceURL: restoreKernelURL,
            outputURL: outputDirectory.appendingPathComponent("krnl.img4"),
            im4mData: im4mData
        )
    }

    func deriveRamdiskKernelSource(restoreKernelURL: URL, tempDirectory: URL) throws -> URL? {
        let legacy = URL(fileURLWithPath: restoreKernelURL.path + Self.ramdiskKernelSuffix)
        if FileManager.default.fileExists(atPath: legacy.path) {
            print("  found legacy ramdisk kernel snapshot: \(legacy.path)")
            return legacy
        }
        guard let pristine = findPristineCloudOSKernel() else {
            print("  [!] pristine CloudOS kernel not found; skipping ramdisk-specific kernel image")
            return nil
        }
        print("  deriving ramdisk kernel from pristine source: \(pristine.path)")
        let outURL = tempDirectory.appendingPathComponent("kernelcache.research.vphone600\(Self.ramdiskKernelSuffix)")
        let (payload, _, _) = try loadPayloadAndOriginal(from: pristine)
        let patcher = KernelPatcher(data: payload, verbose: false)
        _ = try patcher.apply()
        try patcher.buffer.data.write(to: outURL)
        print("  [+] base kernel patches applied for ramdisk variant")
        return outURL
    }

    func findPristineCloudOSKernel() -> URL? {
        if let override = ProcessInfo.processInfo.environment["RAMDISK_BASE_KERNEL"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let projectRoot = VPhoneHost.currentDirectoryURL()
        let patterns = [
            projectRoot.appendingPathComponent("ipsws/PCC-CloudOS*/kernelcache.research.vphone600").path,
            projectRoot.appendingPathComponent("ipsws/*CloudOS*/kernelcache.research.vphone600").path,
        ]
        for pattern in patterns {
            if let path = try? awaitSyncGlob(pattern).sorted().first {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func buildKernelImage(sourceURL: URL, outputURL: URL, im4mData: Data) throws {
        let (payload, originalRaw, _) = try loadPayloadAndOriginal(from: sourceURL)
        let rebuilt = try createCompressedIM4P(
            fourcc: Self.kernelFourCC,
            description: Self.kernelFourCC,
            payload: payload,
            originalRaw: originalRaw
        )
        try signIMG4(im4pData: rebuilt, im4mData: im4mData, outputURL: outputURL)
        print("  [+] \(outputURL.lastPathComponent)")
    }

    func buildRamdiskImage(
        restoreDirectory: URL,
        vmDirectory: URL,
        inputDirectory: URL,
        outputDirectory: URL,
        tempDirectory: URL,
        mountpoint: URL,
        im4mData: Data
    ) async throws {
        print("\n============================================================")
        print("  8. Ramdisk + Trustcache")
        print("============================================================")
        let buildManifestURL = restoreDirectory.appendingPathComponent("BuildManifest.plist")
        let buildManifest = try PropertyListSerialization.propertyList(from: Data(contentsOf: buildManifestURL), options: [], format: nil) as? [String: Any]
        guard
            let identities = buildManifest?["BuildIdentities"] as? [[String: Any]],
            let manifest = identities.first?["Manifest"] as? [String: Any],
            let restoreRamDisk = manifest["RestoreRamDisk"] as? [String: Any],
            let info = restoreRamDisk["Info"] as? [String: Any],
            let relativePath = info["Path"] as? String
        else {
            throw ValidationError("Failed to locate RestoreRamDisk path in BuildManifest.plist")
        }

        let ramdiskSourceURL = restoreDirectory.appendingPathComponent(relativePath)
        let ramdiskRawURL = tempDirectory.appendingPathComponent("ramdisk.raw.dmg")
        let ramdiskCustomURL = tempDirectory.appendingPathComponent("ramdisk1.dmg")
        let trustcacheRawURL = tempDirectory.appendingPathComponent("sshrd.raw.tc")
        let trustcacheIM4PURL = tempDirectory.appendingPathComponent("trustcache.im4p")
        let ramdiskIM4PURL = tempDirectory.appendingPathComponent("ramdisk.im4p")

        let ramdiskPayload = try IM4PHandler.load(contentsOf: ramdiskSourceURL).payload
        try ramdiskPayload.write(to: ramdiskRawURL)

        print("  Mounting base ramdisk...")
        try await attachDiskImage(ramdiskRawURL, at: mountpoint)

        print("  Creating expanded ramdisk (\(Self.expandedRamdiskSize))...")
        _ = try await VPhoneHost.runPrivileged(
            "hdiutil",
            arguments: [
                "create", "-size", Self.expandedRamdiskSize,
                "-imagekey", "diskimage-class=CRawDiskImage",
                "-format", "UDZO",
                "-fs", "APFS",
                "-layout", "NONE",
                "-srcfolder", mountpoint.path,
                "-copyuid", "root",
                ramdiskCustomURL.path,
            ],
            requireSuccess: true
        )
        try? await detachDiskImage(at: mountpoint)

        do {
            print("  Mounting expanded ramdisk...")
            try await attachDiskImage(ramdiskCustomURL, at: mountpoint)

            print("  Injecting SSH tools...")
            try VPhoneArchive.extractTarGzipArchive(
                inputDirectory.appendingPathComponent("ssh.tar.gz"),
                to: mountpoint
            )
            try patchRestoredExternalUSBMuxLabel(mountpoint: mountpoint)
            try removeUnneededFiles(from: mountpoint)
            try await resignMachOBinaries(in: mountpoint, inputDirectory: inputDirectory)

            print("  Building trustcache...")
            var trustCacheBuilder = TrustCacheBuilder()
            _ = try trustCacheBuilder.scan(mountpoint)
            let trustcachePayload = trustCacheBuilder.serialize()
            try trustcachePayload.write(to: trustcacheRawURL)
            let trustcacheIM4P = try IM4P(fourcc: "rtsc", description: "rtsc", payload: trustcachePayload)
            try trustcacheIM4P.data.write(to: trustcacheIM4PURL)
            try signIMG4(
                im4pData: trustcacheIM4P.data,
                im4mData: im4mData,
                outputURL: outputDirectory.appendingPathComponent("trustcache.img4")
            )
            print("  [+] trustcache.img4")
        } catch {
            try? await detachDiskImage(at: mountpoint)
            throw error
        }
        try? await detachDiskImage(at: mountpoint)

        _ = try await VPhoneHost.runPrivileged(
            "hdiutil",
            arguments: ["resize", "-sectors", "min", ramdiskCustomURL.path],
            requireSuccess: true
        )

        print("  Signing ramdisk...")
        let customRamdiskPayload = try Data(contentsOf: ramdiskCustomURL)
        let ramdiskIM4P = try IM4P(fourcc: "rdsk", description: "rdsk", payload: customRamdiskPayload)
        try ramdiskIM4P.data.write(to: ramdiskIM4PURL)
        try signIMG4(
            im4pData: ramdiskIM4P.data,
            im4mData: im4mData,
            outputURL: outputDirectory.appendingPathComponent("ramdisk.img4")
        )
        print("  [+] ramdisk.img4")
    }

    func attachDiskImage(_ imageURL: URL, at mountpoint: URL) async throws {
        _ = try await VPhoneHost.runPrivileged(
            "hdiutil",
            arguments: [
                "attach",
                "-mountpoint", mountpoint.path,
                imageURL.path,
                "-nobrowse",
                "-owners", "off",
            ],
            requireSuccess: true
        )
    }

    func detachDiskImage(at mountpoint: URL) async throws {
        _ = try await VPhoneHost.runPrivileged(
            "hdiutil",
            arguments: ["detach", "-force", mountpoint.path],
            requireSuccess: true
        )
    }

    func patchRestoredExternalUSBMuxLabel(mountpoint: URL) throws {
        guard let targetUDID = ProcessInfo.processInfo.environment["RAMDISK_UDID"], !targetUDID.isEmpty else {
            print("  [*] RAMDISK_UDID not set; keeping default restored_external USBMux label")
            return
        }
        let targetBytes = Data(targetUDID.utf8)
        guard targetBytes.count <= Self.restoredExternalSerialMarker.count else {
            throw ValidationError("RAMDISK_UDID too long for restored_external label (\(targetBytes.count) > \(Self.restoredExternalSerialMarker.count))")
        }
        let restoredExternalURL = mountpoint.appendingPathComponent(Self.restoredExternalPath)
        try VPhoneHost.requireFile(restoredExternalURL)
        var data = try Data(contentsOf: restoredExternalURL)
        guard let range = data.range(of: Self.restoredExternalSerialMarker) else {
            throw ValidationError("Could not find default USBMux serial marker in restored_external")
        }
        let replacement = targetBytes + Data(repeating: 0, count: Self.restoredExternalSerialMarker.count - targetBytes.count)
        data.replaceSubrange(range, with: replacement)
        try data.write(to: restoredExternalURL)
        print("  [+] Patched restored_external USBMux label to: \(targetUDID)")
    }

    func removeUnneededFiles(from mountpoint: URL) throws {
        for relativePath in Self.ramdiskRemove {
            let url = mountpoint.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func resignMachOBinaries(in mountpoint: URL, inputDirectory: URL) async throws {
        print("  Re-signing Mach-O binaries...")
        let signcertURL = inputDirectory.appendingPathComponent("signcert.p12")
        let ldid = which("ldid") ?? "ldid"

        for directory in Self.signDirectories {
            let baseURL = mountpoint.appendingPathComponent(directory, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                continue
            }
            for fileURL in entries {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard try isMachOFile(fileURL) else { continue }
                _ = try await VPhoneHost.runCommand(
                    ldid,
                    arguments: ["-S", "-M", "-K\(signcertURL.path)", fileURL.path],
                    requireSuccess: true
                )
            }
        }

        let sftpServerURL = mountpoint.appendingPathComponent("usr/libexec/sftp-server")
        if FileManager.default.fileExists(atPath: sftpServerURL.path) {
            _ = try await VPhoneHost.runCommand(
                ldid,
                arguments: ["-S\(inputDirectory.appendingPathComponent("sftp_server_ents.plist").path)", "-M", "-K\(signcertURL.path)", sftpServerURL.path],
                requireSuccess: true
            )
        }
    }

    func isMachOFile(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 4 else { return false }
        let magic = data.prefix(4)
        let knownMagics: [Data] = [
            Data([0xFE, 0xED, 0xFA, 0xCE]),
            Data([0xCE, 0xFA, 0xED, 0xFE]),
            Data([0xFE, 0xED, 0xFA, 0xCF]),
            Data([0xCF, 0xFA, 0xED, 0xFE]),
            Data([0xCA, 0xFE, 0xBA, 0xBE]),
            Data([0xBE, 0xBA, 0xFE, 0xCA]),
            Data([0xCA, 0xFE, 0xBA, 0xBF]),
            Data([0xBF, 0xBA, 0xFE, 0xCA]),
        ]
        return knownMagics.contains(magic)
    }
}
