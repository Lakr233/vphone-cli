// CFWBuildVersion.swift — rewrite ProductBuildVersion in SystemVersion.plist.
//
// Swift port of scripts/patchers/cfw_patch_build_version.py (EXP-JB-7).
//
// iOS displays the build identifier (e.g. "23B85") in Settings → General →
// About → "Build Version", and most userland frameworks (libMobileGestalt,
// CoreFoundation's `_CFCopyServerVersionDictionary`, App Store telemetry)
// read it from `/System/Library/CoreServices/SystemVersion.plist` — the
// `ProductBuildVersion` key. A copy of the same plist lives at
// `/private/preboot/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist`
// for Cryptex-side OS-version queries, and the install step rewrites both.
//
// The change does NOT affect `sysctl kern.osversion` (a kernel global
// populated at boot from boot args), `ProductVersion` (the marketing
// version, deliberately left alone), or any DSC constant.
//
// The step is opt-in: `cfw_install_exp.sh` runs it only when SPOOF_BUILD is
// set and non-empty. That gate lives at the call site, not here — this type
// is told the target build and rewrites it.

import Foundation

/// Rewrites `ProductBuildVersion` in a `SystemVersion.plist`, preserving the
/// file's original plist format (XML in, XML out; binary in, binary out).
public enum CFWBuildVersion {
    /// The single key this patcher touches.
    public static let key = "ProductBuildVersion"

    /// What a patch attempt did.
    public enum Outcome: Sendable, Equatable {
        /// The plist already held the target build identifier.
        case alreadyTarget(String)
        /// The value would change but `dryRun` suppressed the write.
        case dryRun(from: String, to: String)
        /// The file was rewritten.
        case rewritten(from: String, to: String)

        /// True only when bytes landed on disk — mirrors the Python's
        /// `patch_plist()` return value.
        public var didWrite: Bool {
            if case .rewritten = self {
                return true
            }
            return false
        }
    }

    // MARK: - Patching

    /// Rewrite `ProductBuildVersion` at `url` to `target`.
    ///
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when the file is not a
    ///   plist, its root is not a dictionary, or the key is missing or not a
    ///   string. Every one of those is a reason to stop the install rather
    ///   than write a half-understood file back to a mounted guest volume.
    @discardableResult
    public static func patch(
        at url: URL,
        to target: String,
        dryRun: Bool = false,
        verbose: Bool = true,
    ) throws -> Outcome {
        let data = try readFile(at: url)
        let format = detectFormat(data)

        guard let parsed = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil,
        ) else {
            throw PatcherError.invalidFormat("cannot parse as plist: \(url.path)")
        }

        guard var plist = parsed as? [String: Any] else {
            throw PatcherError.invalidFormat(
                "top-level plist is \(type(of: parsed)), expected dict: \(url.path)",
            )
        }

        guard let current = plist[key] else {
            throw PatcherError.invalidFormat("no '\(key)' key present: \(url.path)")
        }
        guard let currentString = current as? String else {
            throw PatcherError.invalidFormat(
                "'\(key)' is \(type(of: current)), expected str: \(url.path)",
            )
        }

        if currentString == target {
            if verbose {
                print("  [.] \(url.path): \(key) already = '\(target)'")
            }
            return .alreadyTarget(target)
        }

        if verbose {
            print("  [+] \(url.path): \(key) '\(currentString)' -> '\(target)'")
        }
        plist[key] = target

        if dryRun {
            if verbose {
                print("  [.] dry-run — not writing back")
            }
            return .dryRun(from: currentString, to: target)
        }

        let output = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0,
        )
        try output.write(to: url)
        return .rewritten(from: currentString, to: target)
    }

    // MARK: - Format detection

    /// XML plists start with `<?xml` or `<plist`; binary plists start with
    /// `bplist00`. Sniffing the first non-whitespace byte is what the Python
    /// does, and it is enough: `PropertyListSerialization` will not tell us
    /// the input format without also handing back a parsed object, and an
    /// open-coded check keeps the two implementations provably identical.
    static func detectFormat(_ data: Data) -> PropertyListSerialization.PropertyListFormat {
        // bytes.lstrip() with no argument strips exactly these.
        let asciiWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]
        guard let first = data.first(where: { !asciiWhitespace.contains($0) }) else {
            return .binary
        }
        return first == UInt8(ascii: "<") ? .xml : .binary
    }

    private static func readFile(at url: URL) throws -> Data {
        do {
            return try Data(contentsOfFileToRewrite: url)
        } catch {
            throw PatcherError.fileNotFound(url.path)
        }
    }
}
