import ArgumentParser
import FirmwarePatcher
import Foundation

struct VPhoneCustomFirmwarePatchQuartzCoreUnrotatedFramebufferCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-quartzcore-unrotated-framebuffer",
        abstract: "Keep QuartzCore's framebuffer panel-native in landscape and re-attest its cache page",
    )
    @Argument(transform: URL.init(fileURLWithPath:)) var chunksDirectory: URL
    @Flag var dryRun = false
    @OptionGroup var undo: DyldSharedCacheUndoOptions

    func run() throws {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, captureUndo: undo.captures)
        let site = try DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.patch(in: chunks, dryRun: dryRun)
        let before = site.before.map { String(format: "%02x", $0) }.joined()
        let after = site.replacement.map { String(format: "%02x", $0) }.joined()
        print("QuartzCore rotated-framebuffer gate: 0x\(String(site.address, radix: 16)) \(before) -> \(after), already patched: \(site.alreadyPatched)")
        if let captured = chunks.takeUndoLog() {
            try undo.persist(captured, dryRun: dryRun)
        }
    }
}
