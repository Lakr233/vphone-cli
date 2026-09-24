// CustomFirmwareJetsam.swift — Defuse the launchd jetsam panic guard in /sbin/launchd.
//
// WHY
// ---
// `/sbin/launchd` is pid 1. Under the vphone kernel the jetsam property
// category for a Daemon job is never initialized, so the guard that checks it
// takes its failure path, logs "jetsam property category (%s) is not
// initialized" and tears the process down. initproc dying is a panic, and the
// panic is a loop: the guest never reaches userspace. Forcing the guard's
// success return is what lets the boot continue.
//
// The blast radius here is the largest of the six standalone Mach-O patchers:
// a wrong four bytes in pid 1 is a guest that never boots, with no shell to
// debug it from. Everything below is therefore anchored on what the compiler
// had to emit, never on where it happened to land.
//
// REVEAL PROCEDURE (no file offset, virtual address or instruction byte in
// this file is written down — all four steps derive their address):
//
//   1. String anchor — find the jetsam-not-initialized format string in the
//      image, then walk back to the start of the enclosing NUL-terminated C
//      string, because code references a string's start, never a substring.
//   2. Cross-reference — find the ADRP+ADD pair in `__TEXT,__text` that
//      computes that string's VA. That is the guard's failure path: the
//      instruction that loads the message it is about to log.
//   3. Enclosing function — walk back from the xref to the function's
//      `PACIBSP` prologue. This is the one place this port deliberately
//      diverges from `scripts/patchers/cfw_patch_jetsam.py`, which instead
//      scans a blind 0x300-byte window that can start inside the *previous*
//      function. Both pick the same instruction on iOS 27.0 / 24A435 (proven
//      byte for byte in `CustomFirmwareJetsamTests`); the function bound is what keeps
//      that true when the code around it moves. The blind window survives as
//      the fallback for a function with no PAC prologue.
//   4. Gate — inside that function, take the earliest conditional branch whose
//      target is a *return block*: a basic block reaching `ret`/`retab`/`retaa`
//      without leaving through a branch first. Earliest, because that one skips
//      the most of the jetsam path. Rewrite it to an unconditional `b` to the
//      same target, so every path that reaches the gate returns through its
//      success path. Not every path reaches it: on 24A435 a `cbz x1` four
//      instructions earlier branches past the gate, as it did before the patch.
//
// The replacement comes from `ARM64Encoder.encodeB(from:to:)`, and the branch
// classification from Capstone's typed operands — never from operand text.
// Capstone 6 prints a branch target as `0x237ef22bc` where the Capstone 5 the
// Python links prints `#0x237ef22bc`; that string reaches a log line and a
// `PatchRecord` description, never a patched byte.
//
// IDEMPOTENCE
// -----------
// Running twice is a clean no-op. That is not free here, and getting it wrong
// is a live bug in the reference: rewriting the gate drops it out of the
// conditional-branch set, so the Python's backward scan walks past it and
// patches the *next* branch into the same return block — a second, wrong site
// on a binary that was already correct (`Research/Patches/patch_reference_capture.md`,
// "The non-idempotency itself is a separate, pre-existing bug"). The fix has to
// live inside the scan, because on a re-run neither implementation picks the
// site it patched before. So the scan collects unconditional `b`s into a return
// block as well, and an earlier one of those means a previous run already did
// the work. See `Verdict.alreadyPatched`.
//
// SIGNING
// -------
// `reattest` defaults to false, matching the reference: every call site
// (`scripts/cfw_install_{dev,jb,exp}.sh`, `cfw-kit/jb/install.sh`) runs `ldid`
// over the result immediately afterwards, which rebuilds the signature whole.
// Pass `reattest: true` when nothing downstream re-signs — it recomputes the
// slot hash of the one page this patch dirties through
// `CustomFirmwareMachOCodeSignature`, short tail slot included, and the result passes
// `codesign -v`.

import Foundation

public enum CustomFirmwareJetsamPatcher {
    // MARK: - Anchors

    /// The jetsam guard's failure message, most specific first, exactly as the
    /// reference orders them. The first anchor that resolves all the way to a
    /// patch site wins; one that resolves partway is abandoned for the next.
    ///
    /// The middle entry is the substring that actually matches on iOS 27.0 —
    /// the full sentence is a format string (`(%s)`) in the image, not the
    /// rendered text.
    public static let panicStringAnchors = [
        "jetsam property category (Daemon) is not initialized",
        "jetsam property category",
        "initproc exited -- exit reason namespace 7 subcode 0x1",
    ]

    /// Conditional branches that can gate the jetsam failure path. Matched
    /// against Capstone's mnemonic, which is the instruction's identity; the
    /// target comes from its typed immediate operand.
    static let conditionalBranchMnemonics: Set<String> = [
        "b.eq", "b.ne", "b.cs", "b.hs", "b.cc", "b.lo", "b.mi", "b.pl",
        "b.vs", "b.vc", "b.hi", "b.ls", "b.ge", "b.lt", "b.gt", "b.le",
        "cbz", "cbnz", "tbz", "tbnz",
    ]

    /// How far back to look for the enclosing function's `PACIBSP` prologue.
    /// A quarter of a page of instructions is well past any launchd function
    /// that references a log string.
    static let maxFunctionPrologueScan = 0x400

    /// The reference's blind backward window, kept as the fallback for a
    /// function whose prologue does not sign the link register.
    static let fallbackScanWindow = 0x300

    /// Instructions to decode from a branch target while deciding whether it is
    /// a return block.
    static let returnBlockProbeInstructions = 8

    // MARK: - Outcome

    /// What one run did.
    public struct Outcome: Sendable {
        public enum Verdict: Sendable, Equatable, CustomStringConvertible {
            /// The gate was live and has been rewritten.
            case patched
            /// An unconditional branch into the function's return block already
            /// sits ahead of every conditional one. A previous run wrote it;
            /// nothing was written and nothing needed re-attesting.
            case alreadyPatched
            /// A dry run that located a live gate and stopped short of writing.
            case wouldPatch

            public var description: String {
                switch self {
                case .patched: "patched"
                case .alreadyPatched: "already patched"
                case .wouldPatch: "would patch"
                }
            }
        }

        public let verdict: Verdict
        /// Which of `panicStringAnchors` resolved.
        public let anchor: String
        /// File offset of the branch that was (or would be) rewritten.
        public let gateOffset: Int
        /// Virtual address of the same.
        public let gateVMA: UInt64
        /// File offset the gate branches to — the function's return block.
        public let returnBlockOffset: Int
        /// File offset of the enclosing function's first instruction.
        public let functionOffset: Int
        /// The record of the single write, on a run that wrote or would write.
        public let record: PatchRecord?
        /// Slot hashes re-attestation replaced, on a run that wrote with
        /// `reattest: true`.
        public let rehashes: [CustomFirmwareSlotRehash]

        public init(
            verdict: Verdict,
            anchor: String,
            gateOffset: Int,
            gateVMA: UInt64,
            returnBlockOffset: Int,
            functionOffset: Int,
            record: PatchRecord? = nil,
            rehashes: [CustomFirmwareSlotRehash] = [],
        ) {
            self.verdict = verdict
            self.anchor = anchor
            self.gateOffset = gateOffset
            self.gateVMA = gateVMA
            self.returnBlockOffset = returnBlockOffset
            self.functionOffset = functionOffset
            self.record = record
            self.rehashes = rehashes
        }

        /// Sites this run put on disk — 1 on a live patch, 0 otherwise.
        public var sitesWritten: Int {
            verdict == .patched ? 1 : 0
        }
    }

    // MARK: - Entry points

    /// Patch `/sbin/launchd` in place.
    ///
    /// `reattest: true` recomputes the slot hash of the page the patch dirties
    /// so the binary still verifies on its own; leave it false when the caller
    /// re-signs (every current one does).
    @discardableResult
    public static func patch(
        fileAt url: URL,
        dryRun: Bool = false,
        reattest: Bool = false,
        log: ((String) -> Void)? = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    ) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let outcome = try patch(&data, dryRun: dryRun, reattest: reattest, log: log)
        if !dryRun, outcome.verdict == .patched {
            try data.write(to: url)
        }
        return outcome
    }

    /// Patch a `/sbin/launchd` image held in memory.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        dryRun: Bool = false,
        reattest: Bool = false,
        log: ((String) -> Void)? = nil,
    ) throws -> Outcome {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let image = try Image(data: data)
        guard let site = try locate(in: image, log: log) else {
            throw PatcherError.patchSiteNotFound(
                "launchd jetsam: no anchor string resolved to a conditional branch "
                    + "into its function's return block",
            )
        }

        let gateVMA = image.virtualAddress(ofTextOffset: site.gateOffset)
        log?("  Found jetsam anchor '\(site.anchor)'")
        log?(String(format: "    string start: va:0x%llX", site.stringVMA))
        log?(String(format: "    xref at foff:0x%X", site.xrefOffset))
        log?(String(format: "    function at foff:0x%X", site.functionOffset))

        if site.isAlreadyPatched {
            log?(String(
                format: "  [=] already patched at 0x%X: b 0x%X (jetsam panic guard bypass)",
                site.gateOffset,
                site.returnBlockOffset,
            ))
            return Outcome(
                verdict: .alreadyPatched,
                anchor: site.anchor,
                gateOffset: site.gateOffset,
                gateVMA: gateVMA,
                returnBlockOffset: site.returnBlockOffset,
                functionOffset: site.functionOffset,
            )
        }

        guard let branch = ARM64Encoder.encodeB(from: site.gateOffset, to: site.returnBlockOffset) else {
            throw PatcherError.invalidFormat(
                String(
                    format: "launchd jetsam: b 0x%X is out of range from 0x%X",
                    site.returnBlockOffset,
                    site.gateOffset,
                ),
            )
        }

        let original = Data(data[site.gateOffset ..< site.gateOffset + 4])
        let record = PatchRecord(
            patchID: "launchd_jetsam.panic_guard_bypass",
            component: "launchd_jetsam",
            fileOffset: site.gateOffset,
            virtualAddress: gateVMA,
            originalBytes: original,
            patchedBytes: branch,
            beforeDisasm: describe(original, at: site.gateOffset),
            afterDisasm: describe(branch, at: site.gateOffset),
            description: String(
                format: "conditional branch -> unconditional b 0x%X (jetsam panic guard bypass)",
                site.returnBlockOffset,
            ),
        )

        log?(String(
            format: "  %@ at 0x%X: %@ -> %@",
            dryRun ? "[.] would patch" : "[+] patching",
            site.gateOffset,
            record.beforeDisasm,
            record.afterDisasm,
        ))

        guard !dryRun else {
            return Outcome(
                verdict: .wouldPatch,
                anchor: site.anchor,
                gateOffset: site.gateOffset,
                gateVMA: gateVMA,
                returnBlockOffset: site.returnBlockOffset,
                functionOffset: site.functionOffset,
                record: record,
            )
        }

        data.replaceSubrange(site.gateOffset ..< site.gateOffset + 4, with: branch)
        guard Data(data[site.gateOffset ..< site.gateOffset + 4]) == branch else {
            throw PatcherError.patchVerificationFailed(
                String(format: "launchd jetsam: post-write verify failed at 0x%X", site.gateOffset),
            )
        }

        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [site.gateOffset])
            for rehash in rehashes {
                log?("  [.] re-attest \(rehash)")
            }
        }

        log?(String(format: "  [+] Patched at 0x%X: jetsam panic guard bypass", site.gateOffset))
        return Outcome(
            verdict: .patched,
            anchor: site.anchor,
            gateOffset: site.gateOffset,
            gateVMA: gateVMA,
            returnBlockOffset: site.returnBlockOffset,
            functionOffset: site.functionOffset,
            record: record,
            rehashes: rehashes,
        )
    }
}
