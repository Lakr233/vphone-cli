import Foundation
import Testing

/// Running the real `ldid` and holding this signer's output against it.
///
/// The bar for `VPhoneSign` is not "the signature verifies" — ldid's own
/// ad-hoc output does not verify, because it sets no ad-hoc flag and writes
/// no CMS blob, and the guest's AMFI takes it anyway. The bar is that the
/// bytes are the same, which is the only claim that carries over to a
/// patched AMFI nobody here can re-derive. So these tests need ldid, and
/// skip rather than pretend when it is not installed.
enum VPhoneSignLdidHarness {
    /// Where Homebrew's ldid is, or nil. Its absence skips the comparisons;
    /// it must never make them pass.
    static let ldid: URL? = {
        for candidate in ["/opt/homebrew/bin/ldid", "/usr/local/bin/ldid"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return which("ldid")
    }()

    static func which(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !path.isEmpty ? URL(fileURLWithPath: path) : nil
    }

    /// The Mach-O files to compare on. System binaries cover the shapes this
    /// signer has to get right and nothing else on the machine does: fat
    /// files, several architectures, a deployment target old enough that
    /// ldid drops SHA-1, and one new enough that it does not. The built
    /// products are the thin arm64 case.
    static var corpus: [URL] {
        let candidates = [
            "/bin/ls", // fat, and minos 10.14 on x86_64: ldid writes SHA-256 only
            "/bin/cat", // fat, minos 27.0: ldid writes both
            "/bin/echo",
            "/usr/bin/true",
            "/usr/bin/grep",
            "/usr/bin/head",
        ] + carryingEntitlements + toolchainLibraries + built
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Binaries that already carry entitlements, which is what `-M` has to
    /// re-serialise. They are listed apart because a corpus of files with no
    /// entitlements makes every merge test pass without merging anything.
    ///
    /// The `<integer>` spellings are the reason for most of this list: an
    /// earlier reader here took only a positive decimal, so a merge over
    /// `spindump` — whose
    /// `com.apple.trial.status.deployment-environment.allow` is
    /// `<array><integer>0</integer></array>` — failed where ldid completed.
    /// `promotedcontentd` is above `Int32.max`, `runningboardd` carries two
    /// different values, and `sysdiagnose_helper` carries six.
    static var carryingEntitlements: [String] {
        [
            "/usr/libexec/lsd", // carries __TEXT,__info_plist and entitlements
            "/usr/sbin/sshd",
            "/usr/libexec/trustd",
            "/usr/libexec/pkd",
            "/usr/sbin/spindump", // <integer>0</integer>
            "/usr/libexec/sysdiagnose_helper",
            "/usr/libexec/runningboardd",
            "/usr/libexec/promotedcontentd",
            "/usr/libexec/seserviced",
            "/usr/libexec/tailspind",
            "/usr/bin/tailspin",
            "/usr/sbin/cfprefsd",
            "/usr/sbin/securityd",
            "/usr/libexec/opendirectoryd",
            "/usr/bin/shortcuts",
        ]
    }

    /// Dylibs rather than programs, which differ in the executable segment
    /// flags and in whether the main-binary bit is set. The system's own are
    /// in the shared cache and not on disk; the toolchain's are real files.
    static var toolchainLibraries: [String] {
        let toolchain = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
        let names = ["libLTO.dylib", "libswiftDemangle.dylib", "libcodedirectory.dylib"]
        guard let installed = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") else {
            return names.map { "\(toolchain)/\($0)" }
        }
        // whichever Xcode is installed, including a versioned one beside it
        return installed.filter { $0.hasPrefix("Xcode") }.flatMap { application in
            names.map {
                "/Applications/\(application)/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/\($0)"
            }
        }
    }

    /// This project's own binaries, when they have been built. `vphoned` is
    /// the one that matters most: it is iOS arm64, cross-compiled, and the
    /// binary the guest actually loads.
    static var built: [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [root.appendingPathComponent("scripts/vphoned/vphoned").path]
            + ["vphone-letmein", "vphone-archive", "vphone-vm", "vphone-cli"].flatMap { name in
                ["release", "debug"].map { root.appendingPathComponent(".build/\($0)/\(name)").path }
            }
    }

    // MARK: Running things

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, out: Data, error: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe(), error = Pipe()
        process.standardOutput = out
        process.standardError = error
        try process.run()
        // read before waiting: a pipe that fills would deadlock the child
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, String(decoding: diagnostics, as: UTF8.self))
    }

    /// A directory that goes away with the test.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `source` copied in as `name`, since ldid signs under the file's name
    /// and both sides have to be called the same thing.
    static func copy(_ source: URL, into directory: URL, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// Where two files first differ, for a failure message worth reading.
    static func difference(_ left: Data, _ right: Data) -> String {
        guard left != right else { return "identical" }
        let shared = min(left.count, right.count)
        for offset in 0 ..< shared where left[offset] != right[offset] {
            let window = offset ..< min(offset + 16, shared)
            return """
            \(left.count) vs \(right.count) bytes, first difference at \(offset) \
            (0x\(String(offset, radix: 16))): \
            \(left[window].map { String(format: "%02x", $0) }.joined()) vs \
            \(right[window].map { String(format: "%02x", $0) }.joined())
            """
        }
        return "\(left.count) vs \(right.count) bytes, identical up to the shorter one"
    }
}
