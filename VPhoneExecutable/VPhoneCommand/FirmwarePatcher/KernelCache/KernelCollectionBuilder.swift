// KernelCollectionBuilder.swift — Link a staged volume into an IMG4 kernelcache.
//
// kmutil only gathers the inputs; the layout comes from the kernel collection
// builder of the macOS the kmutil belongs to. The builder of macOS 26.4 and
// later puts the kernel's `__TEXT_EXEC` after the kexts ("kernel-last"), macOS
// 15 and 26.0–26.3 put it first ("kernel-first"), macOS 27 keeps every kext's
// auth stubs, and a kernel only boots in the layout Apple linked it with.
//
// So the link does not use this Mac's kmutil but the one Apple's build used,
// which every kernelcache names (`KernelCollectionToolchain`): the kmutil of
// that macOS with its own builder, run as the user. The output then depends on
// neither this Mac's macOS nor root.

import Foundation
import VPhonePatchKit

enum KernelCollectionBuilder {
    /// The flags of Apple's boot kernel collections: strip all, IMG4 with split
    /// read-only and executable tags.
    static let createFlags = ["-a", "arm64e", "-n", "boot", "-s", "all", "-z", "-x"]
    static let packageFlags = ["--compress", "--img4-encode", "--split-ro-rx-tags"]

    static func layout(forMacOS version: OperatingSystemVersion) -> KernelCacheBase.BuilderLayout {
        let atLeast264 = version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
        return atLeast264 ? .kernelLast : .kernelFirst
    }

    static func layout(forMacOS version: String) -> KernelCacheBase.BuilderLayout {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return layout(forMacOS: OperatingSystemVersion(
            majorVersion: parts.first ?? 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0,
        ))
    }

    /// kmutil's arguments for the volume at `volume`, writing `<volume>.kc` beside it.
    static func kmutilArguments(volume: String, kernel: String, identifiers: [String]) -> [String] {
        var arguments = ["create"] + createFlags + ["-R", volume, "-k", kernel, "-r", "\(volume)/System/Library/Extensions"]
        for identifier in identifiers {
            arguments += ["-b", identifier]
        }
        // -B is relative to the volume root.
        let name = (volume as NSString).lastPathComponent
        return arguments + packageFlags + ["-B", "/../\(name).kc"]
    }

    /// Links the staged volume `staged` with `toolchain` and returns kmutil's
    /// IMG4 kernelcache. kmutil records the absolute path of every codeless
    /// kext, so the volume is linked from a copy whose path is `pathLength`
    /// characters long (`KernelCacheMixer.buildRootLength`); the copy is a
    /// clone, and removed afterwards.
    static func link(
        staged: URL, kdk: String, identifiers: [String], pathLength: Int,
        toolchain: KernelCollectionToolchain, log: URL,
    ) throws -> Data {
        var template = Array("/private/var/tmp/vphone-kc.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else {
            throw PatcherError.invalidFormat("could not create a directory for the kernelcache link: \(String(cString: strerror(errno)))")
        }
        let root = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nameLength = pathLength - root.path.count - 1
        guard (1 ... 255).contains(nameLength) else {
            throw PatcherError.invalidFormat("a kernelcache volume path of \(pathLength) characters does not fit below \(root.path)")
        }
        let volume = root.appending(path: String(repeating: "b", count: nameLength))
        try FileManager.default.copyItem(at: staged, to: volume)
        let kernel = volume.appending(path: "Library/Developer/KDKs/\(kdk)/System/Library/Kernels/kernel")
        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw PatcherError.fileNotFound("the kernel in the staged kernelcache volume")
        }
        try KernelCacheMixer.run(
            toolchain.kmutil.path, kmutilArguments(volume: volume.path, kernel: kernel.path, identifiers: identifiers),
            environment: toolchain.environment(shim: KernelCollectionToolchain.shim()), log: log,
        )
        return try Data(contentsOf: root.appending(path: "\(volume.lastPathComponent).kc"))
    }
}
