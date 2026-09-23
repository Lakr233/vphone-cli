import Foundation

// MARK: - The way back to ldid

/// Running the external `ldid` instead of signing here.
///
/// This exists so that a regression in `VPhoneSign` is recoverable without a
/// rebuild: set `VPHONE_USE_LDID=1` and every call site goes back to the
/// tool it used before. It is deliberately not something the shipped bundle
/// can reach on its own — `ldid` is the Homebrew binary that fails the
/// self-contained admission rule, which is why it was replaced — so it looks
/// for it on `PATH` and in the two Homebrew prefixes and fails loudly when
/// it is not there, rather than quietly doing something else.
///
/// The plan's §10.19 says this comes out once the byte-for-byte gates have
/// been green through a real guest boot. Until then it is one environment
/// variable away.
public enum VPhoneLdid {
    /// Whether a call with no explicit preference should use ldid.
    public static var isPreferred: Bool {
        let value = ProcessInfo.processInfo.environment["VPHONE_USE_LDID"] ?? ""
        return !value.isEmpty && value != "0" && value.lowercased() != "false"
    }

    /// Where the tool is, if it is anywhere.
    public static func resolve() -> URL? {
        var candidates = ["/opt/homebrew/bin/ldid", "/usr/local/bin/ldid"]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(directory)/ldid")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The arguments that make `ldid` do what `options` asks. Kept apart from
    /// running it so the mapping between the two signers can be read, and
    /// tested, in one place.
    ///
    /// These five flags — `-S`, `-S<file>`, `-M`, `-K<p12>`, `-I<name>`, and
    /// `-e` on the reading side — are every flag the repository ever passes.
    /// That was worked out by reading the call sites. Do not quote a total
    /// from memory: the number drops every time an installer is ported, and
    /// two figures written here have already gone stale. Measure it:
    ///
    ///     grep -rnE '(^|[^_[:alnum:]])ldid[[:space:]]+-' scripts/ cfw-kit/ --include='*.sh'
    ///     grep -rnE '(^|[^_[:alnum:]])ldid_sign(_ent)?[[:space:]]' scripts/ cfw-kit/ --include='*.sh'
    ///
    /// (17 and 33 on 2026-09-23.) A count of 175 has been quoted for this;
    /// that is every textual mention of the word, a different and much larger
    /// number. The flag set above is what matters here, and it has not moved.
    ///
    /// `entitlementsPath` is where `options.entitlements` has been written;
    /// ldid takes a file, not bytes.
    public static func arguments(
        for options: VPhoneSignOptions, entitlementsPath: String?, identityPath: String?
    ) -> [String] {
        var arguments: [String] = []
        arguments.append(entitlementsPath.map { "-S\($0)" } ?? "-S")
        if options.mergesExisting {
            arguments.append("-M")
        }
        if let identityPath {
            arguments.append("-K\(identityPath)")
        }
        if let identifier = options.identifier {
            arguments.append("-I\(identifier)")
        }
        return arguments
    }

    /// Signs with the external tool. `identityPath` is the `.p12`, since
    /// ldid reads the container itself rather than taking an opened identity.
    public static func sign(fileAt url: URL, options: VPhoneSignOptions, identityPath: String?) throws {
        guard let tool = resolve() else {
            throw VPhoneSignError.ldidUnavailable(
                "VPHONE_USE_LDID is set but ldid is not installed (brew install ldid-procursus)"
            )
        }
        // ldid opens the container itself, so the escape hatch needs the
        // path and not the identity. Signing ad-hoc because the path was
        // left out would be a silent downgrade from a real signature.
        guard options.identity == nil || identityPath != nil else {
            throw VPhoneSignError.ldidUnavailable(
                "a signing identity was given but not the .p12 it came from, which is what ldid needs"
            )
        }
        var entitlementsPath: String?
        var temporary: URL?
        if let entitlements = options.entitlements {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("vphone-ldid-\(UUID().uuidString).plist")
            try entitlements.write(to: file)
            entitlementsPath = file.path
            temporary = file
        }
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments(
            for: options, entitlementsPath: entitlementsPath, identityPath: identityPath
        ) + [url.path]
        let diagnostics = Pipe()
        process.standardError = diagnostics
        try process.run()
        let message = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPhoneSignError.ldidUnavailable("ldid exited \(process.terminationStatus): \(message)")
        }
    }

    /// `ldid -e`, for the same reason: one switch puts both directions back.
    public static func entitlements(ofFileAt url: URL) throws -> Data {
        guard let tool = resolve() else {
            throw VPhoneSignError.ldidUnavailable(
                "VPHONE_USE_LDID is set but ldid is not installed (brew install ldid-procursus)"
            )
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-e", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPhoneSignError.ldidUnavailable("ldid -e exited \(process.terminationStatus)")
        }
        return data
    }
}
