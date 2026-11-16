import ArgumentParser
import Foundation
import VPhoneCommandKit
import VPhoneCoreKit

// MARK: - rebase

/// `vm rebase`: re-share a stopped machine's disk image with another's.
struct VPhoneVirtualMachineRebaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebase",
        abstract: "Share a stopped VM's identical disk blocks with another VM or a template",
        discussion: """
        Compares the disk images of a stopped VM and a base and rebuilds the VM's from an \
        APFS clone of the base's, writing only the blocks that differ. Wherever both images \
        hold the same bytes at the same offset (for VMs restored from the same IPSW, most of \
        the system volume), the blocks are then stored once for both. Every byte is checked \
        against the original before it is replaced, so the guest sees exactly the same disk; \
        SEPStorage, nvram.bin, config.plist and the device identity are not touched.

        The base is another stopped VM or a template from `vm template list`, by identifier \
        or unique prefix; a VM wins when a name matches both. A template is never booted, so \
        it makes the best base: its image does not drift. The rebase only reads it, and the \
        rebased VM does not become one of its clones (it keeps its own SEP storage and \
        identity, and `vm template show` does not list it).

        Identical bytes that are already the same blocks on disk, as in two VMs cloned from \
        one template, are reported as already shared: rebasing them frees nothing. The \
        saving is the newly shared bytes.

        Both must be on one APFS volume. The rebase needs free space for the blocks it \
        writes until the old image is released. The space comes back only if nothing else \
        holds the old image's blocks: snapshots of the VM, and clones made from it, keep \
        them. du and Finder still report the full size of each image; free space on the \
        volume is the honest measure. The two images drift apart again as either side writes.

        --dry-run only compares the images and reports what a rebase would share and write.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM whose disk image is rebased") var name: String?
    @Option(name: .long, help: "VM or template identifier whose disk blocks it shares") var onto: String
    @Flag(help: "only report what would be shared and written") var dryRun = false

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let target = try lib.library.bundle(named: name)
        let base = try VPhoneDiskRebaseBase.resolve(onto, in: lib.library)
        if let template = base.commonTemplate(with: target, in: lib.library) {
            let both = base.template == nil
                ? "\(target.name) and \(base.label) were both cloned from template \(template) and already share"
                : "\(target.name) was cloned from template \(template) and already shares"
            print("note: \(both) its blocks; expect little to be newly shared")
        }

        let clock = ContinuousClock()
        let start = clock.now
        var bar: VPhoneProgressBar?
        var phase: VPhoneDiskRebase.Phase?
        let progress: VPhoneDiskRebase.Progress = { current, done, total in
            if current != phase {
                bar?.finish()
                phase = current
                bar = VPhoneProgressBar(label: current == .comparing ? "comparing" : "verifying")
            }
            bar?.update(done: done, total: total)
        }
        let report = dryRun
            ? try VPhoneDiskRebase.plan(target, onto: base.bundle, progress: progress)
            : try VPhoneDiskRebase.rebase(target, onto: base.bundle, progress: progress)
        bar?.finish()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let elapsedText = VPhoneProgressBar.clock(seconds)
        let saving = Self.gigabytes(report.newlySharedBytes)
        if dryRun {
            print("dry run: \(saving) would be newly shared with \(base.label); compared \(target.name) in \(elapsedText), nothing was changed")
        } else {
            print("rebased \(target.name) onto \(base.label) in \(elapsedText); \(saving) newly shared")
        }
        for line in Self.describe(report, base: base.label, dryRun: dryRun) {
            print("  " + line)
        }
        if let note = Self.savingNote(report, target: target.name, base: base.label, dryRun: dryRun) {
            print("note: " + note)
        }
        if !dryRun, let snapshots = try? VPhoneMachineSnapshots.list(of: target), !snapshots.isEmpty {
            print("note: \(target.name) has \(snapshots.count) snapshot(s), which keep the old image's blocks until deleted")
        }
    }

    /// The report as aligned lines, in decimal gigabytes like disk sizes.
    static func describe(_ report: VPhoneDiskRebaseReport, base: String, dryRun: Bool) -> [String] {
        let rows: [(String, Int64, String)] = [
            ("disk image", report.logicalSize, "logical size; \(gigabytes(report.comparedBytes)) holds data in either image"),
            ("newly shared", report.newlySharedBytes, dryRun
                ? "identical to \(base) at the same offset, would be shared"
                : "identical to \(base) at the same offset, now shared"),
            ("already shared", report.alreadySharedBytes, "identical, and already the same blocks on disk (or a hole): frees nothing"),
            ("written", report.writtenBytes, dryRun ? "differs from \(base), would be written" : "differs from \(base), written"),
            ("punched", report.punchedBytes, dryRun ? "zeros where \(base) has data, would become holes" : "zeros where \(base) has data, now holes"),
        ]
        let sizes = rows.map { gigabytes($0.1) }
        let width = sizes.map(\.count).max() ?? 0
        return zip(rows, sizes).map { row, size in
            row.0.padding(toLength: 16, withPad: " ", startingAt: 0)
                + String(repeating: " ", count: width - size.count) + size + "  " + row.2
        }
    }

    /// Below this, the rebase is reported as freeing almost nothing.
    static let negligibleSaving: Int64 = 100_000_000

    /// Why a rebase that newly shares almost nothing is not worth it.
    static func savingNote(_ report: VPhoneDiskRebaseReport, target: String, base: String, dryRun: Bool) -> String? {
        guard report.newlySharedBytes < negligibleSaving else { return nil }
        let frees = dryRun ? "the rebase would free almost nothing" : "the rebase freed almost nothing"
        if report.alreadySharedBytes > report.newlySharedBytes {
            return "\(frees): \(target) already shares its identical blocks with \(base) on disk"
        }
        return "\(frees): \(target) has few blocks identical to \(base)"
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1e9)
    }
}
