import ArgumentParser
import FirmwarePatcher
import Foundation

struct VPhoneCustomFirmwareAuditArm64eX1Command: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit-arm64e-x1",
        abstract: "Read-only audit of standalone X1 libraries and plug-ins",
        discussion: """
        Scans a copied or read-only mounted guest System tree, including cryptex
        files installed beneath it. Discovers images by Mach-O contents, without
        a filename whitelist, and runs the production lowering planner in memory.
        Reports remaining instructions, incomplete conversions, errors and matching
        patch declarations. No image, signature, backup or receipt is written.

        Symlinks, backups, kernel extensions and the dyld shared cache are excluded.
        Executables and standalone dyld can be included explicitly. This is a
        static coverage audit, not evidence that every guest workflow has run.
        --strict exits nonzero for remaining X1 instructions or an incomplete scan.
        """,
    )

    @Argument(help: "Guest System directory", transform: URL.init(fileURLWithPath:)) var system: URL
    @Flag(name: .long, help: "Include MH_EXECUTE and MH_DYLINKER images") var includeExecutables = false
    @Flag(name: .long, help: "Emit the full machine-readable report") var json = false
    @Flag(name: .long, help: "Fail if instructions remain or any image could not be audited") var strict = false

    func run() throws {
        let report = try CustomFirmwareArm64eX1Audit.scan(root: system, includeExecutables: includeExecutables)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("Audited \(report.images.count) X1 images in \(report.examinedFiles) files; skipped \(report.skippedBackups) backups.")
            for image in report.images where image.state != .noLoweringNeeded {
                let detail = image.error ?? "\(image.instructions ?? 0) instructions, \(image.unvisitedCandidates ?? 0) unvisited"
                let coverage = image.declarations.isEmpty ? "undeclared" : image.declarations.joined(separator: ", ")
                print("\(image.state.rawValue): \(image.path): \(detail) [\(coverage)]")
            }
            for failure in report.failures { print("unreadable: \(failure.path): \(failure.error)") }
        }
        if strict, report.needsAttention || report.examinedFiles == 0 { throw ExitCode.failure }
    }
}
