// DSCLockdownModePatcher.swift — Stop libSystem's `os_lockdown_mode_enabled`
// from crashing on the vphone kernel.
//
// iOS 27's `os_lockdown_mode_enabled()` resolves Lockdown Mode once, from a
// block, via `sysctlbyname("security.mac.lockdown_mode_state_public", …)` and
// `os_crash`es when the sysctl returns -1 (`lockdown_mode.c`). The vphone base
// kernel (cloudOS 26.x) does not implement that MAC sysctl, so the call fails
// with ENOENT and every process that queries Lockdown Mode aborts — including
// launchd (pid 1), which panics the system right after "Continuing system
// boot".
//
// The block pre-zeroes its output buffer (`stp x8, xzr, [sp]`), so dropping the
// error branch makes the failure path fall through to the normal path, read 0,
// and record "Lockdown Mode disabled". On a kernel that does implement the
// sysctl the branch is never taken, so the patch is behaviour-neutral there.
//
// Shape (in `___os_lockdown_mode_enabled_block_invoke`):
//
//     bl      <sysctlbyname>
//     cmn     w0, #1            ; w0 == -1 ?
//     b.eq    <os_crash>        ; -> NOP
//
// Anchored on the in-image local symbol; the sysctl-error idiom is located by
// control-flow shape through Capstone; the NOP comes from `ARM64.nop`; the
// modified page is re-attested through `DSCCodeSignature`.
//
// Port of `scripts/patchers/cfw_patch_lockdown_mode.py`, which stays the
// independent reference — `DSCLockdownModePatcherTests` runs the Python on one
// clone of the real cache and this on another, and compares the two byte for
// byte.
//
// One cosmetic divergence, in text only: this links Capstone 6 and the
// reference runs Capstone 5, which prints a branch target as `0x237ef22bc`
// where the older one prints `#0x237ef22bc`. That string reaches the log line
// and the `PatchRecord` description, never a patched byte, and nothing here
// matches on operand text.

import Capstone
import Foundation

public enum DSCLockdownModePatcher {
    // MARK: - Anchors

    /// The block the sysctl lives in, under both manglings seen across
    /// toolchains. The first one that resolves wins, exactly as in the Python.
    public static let symbolCandidates = [
        "___os_lockdown_mode_enabled_block_invoke",
        "__os_lockdown_mode_enabled_block_invoke",
    ]

    /// How far into the block to decode. The idiom sits within a dozen
    /// instructions of the entry on every build seen so far; the decode also
    /// stops at the block's first `ret`/`retab`, so this is only a ceiling.
    static let maxInstructions = 60

    /// One disassembler for the whole patcher — `ARM64Disassembler` is
    /// `Sendable` and stateless across calls.
    private static let disassembler = ARM64Disassembler()

    // MARK: - Outcome

    /// What one run did, in the terms the Python prints.
    public struct Outcome: Sendable {
        public enum Verdict: Sendable, Equatable, CustomStringConvertible {
            /// No `os_lockdown_mode_enabled` block in this cache — a pre-iOS-27
            /// userland. Not an error: the crash it guards against cannot
            /// happen there.
            case symbolAbsent
            /// The gate already holds the NOP this patch writes. Nothing was
            /// written and nothing needed re-attesting.
            case alreadyPatched
            /// A dry run that located a live gate and stopped short of writing.
            case wouldPatch
            /// The NOP was written and the page it dirtied re-attested.
            case patched

            public var description: String {
                switch self {
                case .symbolAbsent: "symbol absent"
                case .alreadyPatched: "already patched"
                case .wouldPatch: "would patch"
                case .patched: "patched"
                }
            }
        }

        public let verdict: Verdict
        /// Which of `symbolCandidates` resolved, when one did.
        public let symbolName: String?
        /// Address of the block the gate was found in.
        public let functionVMA: UInt64?
        /// Address of the branch that was (or would be) NOPed.
        public let gateVMA: UInt64?
        /// The record of the single write, on a run that wrote or would write.
        public let record: PatchRecord?
        /// What re-attestation did, on a run that wrote.
        public let reattestation: DSCReattestation?

        public init(
            verdict: Verdict,
            symbolName: String? = nil,
            functionVMA: UInt64? = nil,
            gateVMA: UInt64? = nil,
            record: PatchRecord? = nil,
            reattestation: DSCReattestation? = nil,
        ) {
            self.verdict = verdict
            self.symbolName = symbolName
            self.functionVMA = functionVMA
            self.gateVMA = gateVMA
            self.record = record
            self.reattestation = reattestation
        }

        /// Sites this run put on disk — 1 on a live patch, 0 otherwise.
        public var sitesWritten: Int {
            verdict == .patched ? 1 : 0
        }

        /// Sites this run found, patched or already patched. This is the number
        /// `patch_lockdown_mode` returns: 0 when the symbol is absent, 1
        /// otherwise.
        public var sitesFound: Int {
            verdict == .symbolAbsent ? 0 : 1
        }
    }

    // MARK: - Entry points

    /// Patch the cache under `chunksDirectory`.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DSCCodeSignature.stderrLog,
    ) throws -> Outcome {
        try patch(in: DSCChunkSet(directory: chunksDirectory), dryRun: dryRun, log: log)
    }

    /// Patch an already-open cache.
    ///
    /// Writes go through `DSCChunkSet.write(at:_:)`, so the span is recorded
    /// and `reattestRecordedWrites` cannot be handed the wrong address. A
    /// caller sharing one chunk set across patchers therefore also gets any
    /// earlier patcher's pages re-attested here, which is a no-op for pages
    /// that are already correct.
    @discardableResult
    public static func patch(
        in chunks: DSCChunkSet,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DSCCodeSignature.stderrLog,
    ) throws -> Outcome {
        log?(
            "  [.] \(chunks.directory.path) "
                + "(\(chunks.chunkURLs.count) chunk(s), \(chunks.mappings.count) mapping(s))",
        )

        guard let block = try resolveBlockInvoke(in: chunks) else {
            log?(
                "      [=] os_lockdown_mode_enabled not present "
                    + "(pre-iOS-27 userland); nothing to patch",
            )
            return Outcome(verdict: .symbolAbsent)
        }
        log?("  [.] \(block.name) @ 0x\(hex(block.vma))")

        let instructions = try disassembleBlock(in: chunks, at: block.vma)
        guard let gate = findErrorGate(instructions) else {
            throw PatcherError.patchSiteNotFound(
                "lockdown_mode: `cmn wR,#1; b.eq <crash>` sysctl-error gate not found "
                    + "(nor an already-NOPed one)",
            )
        }
        log?("      [.] gate @ 0x\(hex(gate.address)): \(gate.mnemonic) \(gate.operandString)")

        let nop = ARM64.nop
        let current = try chunks.bytesAtVMA(gate.address, length: nop.count)
        guard current != nop else {
            log?(
                "      [=] already patched at 0x\(hex(gate.address)); "
                    + "nothing to patch/re-attest",
            )
            return Outcome(
                verdict: .alreadyPatched,
                symbolName: block.name,
                functionVMA: block.vma,
                gateVMA: gate.address,
            )
        }

        let record = try record(for: gate, original: current, replacement: nop, in: chunks)
        log?(
            "      [+] \(dryRun ? "would write" : "wrote") nop at 0x\(hex(gate.address)) "
                + "(\(current.hex) -> \(nop.hex))",
        )
        guard !dryRun else {
            return Outcome(
                verdict: .wouldPatch,
                symbolName: block.name,
                functionVMA: block.vma,
                gateVMA: gate.address,
                record: record,
            )
        }

        try chunks.write(at: gate.address, nop)
        let reattestation = try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: log)
        guard try chunks.bytesAtVMA(gate.address, length: nop.count) == nop else {
            throw PatcherError.patchVerificationFailed(
                "lockdown_mode: post-write verify failed at 0x\(hex(gate.address))",
            )
        }
        log?("  [+] lockdown-mode crash patch complete")

        return Outcome(
            verdict: .patched,
            symbolName: block.name,
            functionVMA: block.vma,
            gateVMA: gate.address,
            record: record,
            reattestation: reattestation,
        )
    }

    // MARK: - Reveal

    /// The first of `symbolCandidates` the cache's own `.symbols` table knows.
    ///
    /// A missing symbol is `nil` — the pre-iOS-27 case. A missing or
    /// unparseable symbol table throws, because "there is nothing to look in"
    /// must not be reported as "this userland does not have the block".
    static func resolveBlockInvoke(in chunks: DSCChunkSet) throws -> (name: String, vma: UInt64)? {
        for name in symbolCandidates {
            if let vma = try chunks.resolveLocalSymbol(name) {
                return (name, vma)
            }
        }
        return nil
    }

    /// Decode the block from `vma` up to its first `ret`/`retab`, or
    /// `maxInstructions`, whichever comes first.
    ///
    /// The window is truncated at the end of what is addressable rather than
    /// padded with whatever follows in the chunk file, which is where this
    /// differs from `_disasm_function` in the reference: a block sitting at the
    /// very end of a mapping decodes as far as it really extends here, instead
    /// of running on into the next region's bytes. On this cache the block is
    /// nowhere near a boundary, so both read the same instructions.
    /// Stops at an undecodable word as well. `ARM64Disassembler` sets
    /// `cs.skipData = true` and the reference's `_cs` (`cfw_asm.py:14`) does
    /// not, so where Capstone cannot decode a word the Python's `cs.disasm`
    /// ends the stream and this one hands back a data pseudo-instruction
    /// (`id == 0`) and carries on. Left alone that inverts the failure mode on
    /// a userland whose block carries an inline literal before the gate: the
    /// Python truncates, `findErrorGate` finds nothing and the install stops
    /// loudly, while this would decode on past the data into whatever follows
    /// the block and — if a `bl` / `cmn wR,#1` / `b.eq` triple happened to
    /// appear there — NOP a branch in unrelated code and re-attest that page.
    /// A wrong patch that passes its own signature check is worse than a
    /// failed install. `DSCLSDEmbeddedRegPatcher.disassembleFunction` breaks on
    /// the same condition for the same reason.
    static func disassembleBlock(in chunks: DSCChunkSet, at vma: UInt64) throws -> [Instruction] {
        let window = try chunks.readAtVMA(vma, length: maxInstructions * 4, allowShort: true)
        var decoded: [Instruction] = []
        for insn in disassembler.disassemble(window, at: vma, count: maxInstructions) {
            guard insn.id != 0 else { break }
            decoded.append(insn)
            if insn.mnemonic == "ret" || insn.mnemonic == "retab" {
                break
            }
        }
        return decoded
    }

    /// The `cmn wR, #1; b.eq` sysctl-error idiom, preceded by a call.
    ///
    /// The branch slot also matches once it holds the NOP this patch writes.
    /// Without that, a second pass over an already-installed cache never
    /// reaches the byte comparison in `patch(in:dryRun:log:)` — the idiom it
    /// searches for is the one the patch has already replaced — and the run
    /// fails instead of reporting a no-op. The `bl` + `cmn wR, #1` anchor is
    /// unchanged, so widening the slot does not weaken where a match can land,
    /// and re-writing a NOP over a NOP is inert.
    static func findErrorGate(_ instructions: [Instruction]) -> Instruction? {
        guard instructions.count >= 2 else { return nil }
        var sawCall = false
        for index in 0 ..< (instructions.count - 1) {
            let insn = instructions[index]
            if insn.mnemonic == "bl" {
                sawCall = true
            }
            guard sawCall else { continue }
            guard insn.mnemonic == "cmn", immediate(of: insn, at: 1) == 1 else { continue }
            let gate = instructions[index + 1]
            if gate.mnemonic == "b.eq" || gate.mnemonic == "nop" {
                return gate
            }
        }
        return nil
    }

    /// The instruction's operand at `index`, when that operand is an immediate.
    ///
    /// Semantic, not textual: the `#1` of `cmn w0, #1` is read off the decode,
    /// so a build that prints it as `#0x1` matches just the same.
    static func immediate(of insn: Instruction, at index: Int) -> Int64? {
        guard let operands = insn.aarch64?.operands,
              index < operands.count,
              operands[index].type == AARCH64_OP_IMM
        else { return nil }
        return operands[index].imm
    }

    // MARK: - Reporting

    private static func record(
        for gate: Instruction,
        original: Data,
        replacement: Data,
        in chunks: DSCChunkSet,
    ) throws -> PatchRecord {
        let span = DSCWriteSpan(vma: gate.address, length: replacement.count)
        let (chunkURL, range) = try chunks.fileRange(of: span)
        return PatchRecord(
            patchID: "lockdown_mode.sysctl_error_gate",
            component: chunkURL.lastPathComponent,
            fileOffset: range.lowerBound,
            virtualAddress: gate.address,
            originalBytes: original,
            patchedBytes: replacement,
            beforeDisasm: "\(gate.mnemonic) \(gate.operandString)",
            afterDisasm: "nop",
            description: "NOP `\(gate.mnemonic) \(gate.operandString)` so a missing "
                + "security.mac.lockdown_mode_state_public sysctl reads 0 instead of aborting",
        )
    }

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
