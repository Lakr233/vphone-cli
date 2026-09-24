// DSCLSDEmbeddedRegPatcher.swift — open lsd's embedded-registration gate.
//
// Swift port of `scripts/patchers/cfw_patch_lsd_embedded_reg.py`, driven by
// `cfw.py patch-lsd-embedded-reg <chunks_dir> [--dry-run]`.
//
// iOS 27's lsd gates `-[_LSDModifyClient performPostInstallationRegistration:…]`
// — and its containerized/rebuild siblings — behind
// `-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]`, which
// calls `xpc_connection_copy_entitlement_value` on the XPC *peer* for any of
// three privileged entitlements (`com.apple.private.coreservices.lsaw`,
// `com.apple.private.installcoordinationd.daemon`,
// `com.apple.private.coreservices.can-register-install-results`). A client
// without one gets `NSOSStatusErrorDomain -54` (permErr) out of
// `LSDModifyService.mm`, so `registerApplicationDictionary:` returns NO. That
// blocks JB app registration (uicache/Sileo), vphoned's IPA installer and
// TrollStore alike.
//
// The entitlement route is a dead end on this stack: even a launchd-spawned
// platform daemon (vphoned) carrying all three in its *validated* csblob
// (`csops CS_OPS_ENTITLEMENTS_BLOB` confirms) is still refused, because LS
// registration is proxied — the XPC peer lsd inspects is not the registering
// process.
//
// So the check is forced to succeed. The method ORs three entitlement probes:
//
//     bl  <check ent1> ; cbnz w0, entitled
//     bl  <check ent2> ; cbnz w0, entitled
//     bl  <check ent3> ; cbz  w0, not_entitled   <- the gate; this is NOP'd
//   entitled:
//     mov w20, #1                                 <- the YES result
//     … ; mov x0, x20 ; retab
//   not_entitled:
//     mov w20, #0
//
// NOP'ing that final `cbz w0, <not_entitled>` — the conditional branch whose
// fall-through is the `mov w<reg>, #1` that becomes the return value — makes
// every path reach YES. One instruction, one site.
//
// Nothing is hardcoded. The method is resolved from the cache's own
// `.symbols` local-symbol table, disassembled with Capstone, and the gate is
// found by control-flow shape rather than by address. The replacement is
// `ARM64.nop`. Writing a cache page invalidates its 16 KiB code slot, so the
// page is re-attested (TXM enforces per-page); the CDHash change that follows
// is accepted by the JB's always-true AMFI cdhash-trust patch.

import Capstone
import Foundation

/// Forces `-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]`
/// to return YES, by NOP'ing the branch that skips its YES result.
public enum DSCLSDEmbeddedRegPatcher {
    /// The image the method lives in. Reported only — the symbol is resolved
    /// through the cache-wide local table, exactly as the Python does, because
    /// `ipsw dyld symaddr -a` times out on a cache this size.
    public static let image =
        "/System/Library/Frameworks/CoreServices.framework/CoreServices"

    /// The ObjC method whose entitlement check is opened.
    public static let method =
        "-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]"

    /// Record identity, matching the Python's `records.next_site` label so a
    /// captured reference and this port sort together.
    public static let patchID = "lsd_embedded_reg.entitlement_gate"

    /// How far into the method to look. The gate sits within the first handful
    /// of basic blocks; 96 instructions is the Python's window and is ample.
    static let maxInstructions = 96

    // MARK: - Results

    /// The conditional branch (or the NOP that already replaced it) that guards
    /// the method's YES result.
    public struct Gate: Sendable, Equatable {
        /// Address of the gating instruction.
        public let vma: UInt64
        /// Its mnemonic as Capstone decoded it — `cbz`, `cbnz`, or `nop` when
        /// a previous run already patched this cache.
        public let mnemonic: String
        /// Its operand text, for logging.
        public let operandString: String
        /// The `w` register the fall-through sets to 1 — the YES value that
        /// later becomes the method's return.
        public let resultRegister: String

        /// True when the site already holds this patch's own output.
        public var wasAlreadyNOP: Bool {
            mnemonic == "nop"
        }

        /// How the gate reads in disassembly.
        public var text: String {
            operandString.isEmpty ? mnemonic : "\(mnemonic) \(operandString)"
        }
    }

    /// What a run did.
    public enum Outcome: String, Sendable, Equatable {
        /// The method is not in this cache — a pre-iOS-27 userland, where the
        /// gate does not exist and there is nothing to open.
        case methodAbsent
        /// The gate already held a NOP; the page was re-attested and nothing
        /// else changed.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The branch was replaced with a NOP and its page re-attested.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        /// The gate, when the method was present.
        public let gate: Gate?
        /// The write, in the shape the Python's reference capture records it.
        /// `nil` unless bytes actually changed.
        public let record: PatchRecord?

        /// Sites whose bytes this run changed. The parity number: the Python
        /// writes exactly one, and so must this.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }

        /// Whether the gate method exists in this cache at all. Mirrors the
        /// Python's return value, which is 0 when absent and 1 otherwise.
        public var methodIsPresent: Bool {
            outcome != .methodAbsent
        }
    }

    /// Where progress goes when the caller does not say. The Python prints to
    /// stdout and `cfw_install*.sh` captures that, so this does too.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Patching

    /// Open the gate in the cache under `chunksDirectory`.
    ///
    /// Self-gating, like the Python: the method exists only on iOS 27+
    /// LaunchServices, so a cache without it reports `.methodAbsent` and
    /// changes nothing. A cache whose `.symbols` side file is *missing*, by
    /// contrast, throws — "there is nowhere to look" must not be reported as
    /// "this userland predates the gate", or an install against a stripped
    /// cache would silently skip the patch and boot into a guest where no app
    /// can register.
    ///
    /// - Throws: ``PatcherError/patchSiteNotFound(_:)`` when the method is
    ///   present but its control-flow shape no longer matches — a LaunchServices
    ///   rewrite, which has to stop the install rather than be guessed at.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        let chunks = try DSCChunkSet(directory: chunksDirectory)
        log?("  [.] \(chunksDirectory.path): \(chunks.chunkURLs.count) chunk(s), "
            + "\(chunks.mappings.count) mapping(s)")

        guard let located = try locateGate(in: chunks) else {
            log?("      [=] \(method) not present (pre-iOS-27 userland); nothing to patch")
            return Report(outcome: .methodAbsent, gate: nil, record: nil)
        }
        log?("  [.] \(method) @ 0x\(hex(located.functionVMA))")

        let gate = located.gate
        log?("      [.] gate: \(gate.text) @ 0x\(hex(gate.vma)) "
            + "(fall-through sets \(gate.resultRegister)=1)")

        let nop = ARM64.nop
        let original = try chunks.bytesAtVMA(gate.vma, length: nop.count)
        let alreadyNOP = original == nop

        if alreadyNOP {
            log?("      [=] already NOP at 0x\(hex(gate.vma)); re-attesting page only")
        } else {
            log?("      [+] \(dryRun ? "would NOP" : "NOP'd") gate \(gate.mnemonic) -> nop "
                + "at 0x\(hex(gate.vma)) (bytes \(original.hex) -> \(nop.hex))")
        }

        guard !dryRun else {
            // The Python signs off with "patch complete" here too. This does
            // not: a dry run patched nothing, and a log line that says
            // otherwise is the one an operator would quote back later.
            log?("  [.] dry-run: would re-attest page for 0x\(hex(gate.vma))")
            return Report(outcome: .wouldPatch, gate: gate, record: nil)
        }

        // Written unconditionally, including when the bytes already match. The
        // Python re-attests the gate's page on every non-dry run, patched or
        // not, and re-attestation here consumes the chunk set's own write log
        // rather than an address a caller hands it — so the idempotent case has
        // to go through the same door. The bytes on disk are identical either
        // way, and `DSCCodeSignature` leaves a page whose stored slot already
        // matches alone.
        try chunks.write(at: gate.vma, nop)

        log?("  [.] re-attesting modified page...")
        try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: log)

        let written = try chunks.bytesAtVMA(gate.vma, length: nop.count)
        guard written == nop else {
            throw PatcherError.patchVerificationFailed(
                "\(method): gate at 0x\(hex(gate.vma)) reads \(written.hex) after write",
            )
        }

        log?("  [+] lsd embedded-registration gate patch complete")

        guard !alreadyNOP else {
            return Report(outcome: .alreadyPatched, gate: gate, record: nil)
        }
        return try Report(
            outcome: .patched,
            gate: gate,
            record: record(for: gate, in: chunks, original: original, patched: nop),
        )
    }

    // MARK: - Locating the gate

    /// Find the entitlement gate without touching the cache.
    ///
    /// Returns `nil` when the method is absent, which is the pre-iOS-27 no-op
    /// case rather than an error.
    public static func locateGate(
        in chunks: DSCChunkSet,
    ) throws -> (functionVMA: UInt64, gate: Gate)? {
        guard let functionVMA = try chunks.resolveLocalSymbol(method) else { return nil }

        let instructions = try disassembleFunction(in: chunks, at: functionVMA)
        guard let gate = findGate(in: instructions) else {
            throw PatcherError.patchSiteNotFound(
                "\(method): entitled-result gate (cbz/cbnz w0 -> mov w<reg>,#1) not found",
            )
        }
        return (functionVMA, gate)
    }

    /// Disassemble from `vma` up to the first `ret`/`retab`, or
    /// ``maxInstructions``, whichever comes first.
    ///
    /// `allowShort` because the window is a fixed instruction count, not a
    /// claim about what is mapped: a method that ends near the tail of its
    /// mapping must not turn into an unmapped-span error.
    static func disassembleFunction(
        in chunks: DSCChunkSet,
        at vma: UInt64,
    ) throws -> [Instruction] {
        let buffer = try chunks.readAtVMA(
            vma,
            length: maxInstructions * 4,
            allowShort: true,
        )
        let decoded = ARM64Disassembler().disassemble(buffer, at: vma)
        var result: [Instruction] = []
        for instruction in decoded {
            // The shared disassembler has `skipData` on, so a word Capstone
            // cannot decode arrives as a data pseudo-instruction (id 0) rather
            // than ending the stream. The Python's `cs.disasm` stops there, and
            // so does this: past an undecodable word the window is no longer
            // this function's instructions, and matching a "gate" in it would
            // be matching noise.
            guard instruction.id != 0 else { break }
            result.append(instruction)
            if instruction.mnemonic == "ret" || instruction.mnemonic == "retab" {
                break
            }
        }
        return result
    }

    /// The conditional branch that gates the entitled result: the `cbz`/`cbnz`
    /// on `w0` whose fall-through is `mov w<reg>, #1`.
    ///
    /// A bare `nop` in that position matches too. That is this patch's own
    /// output, so a second run over an already-patched cache recognises the
    /// idempotent state instead of failing to find a branch that is no longer
    /// there — which is exactly how a re-run of `cfw install` used to die.
    static func findGate(in instructions: [Instruction]) -> Gate? {
        let disassembler = ARM64Disassembler()
        guard instructions.count >= 2 else { return nil }

        for index in 0 ..< (instructions.count - 1) {
            let candidate = instructions[index]
            switch candidate.mnemonic {
            case "cbz", "cbnz":
                guard disassembler.firstRegisterName(candidate) == "w0" else { continue }
            case "nop":
                break
            default:
                continue
            }
            guard let next = movRegisterImmediate(instructions[index + 1], disassembler),
                  next.immediate == 1,
                  next.register.hasPrefix("w")
            else { continue }
            return Gate(
                vma: candidate.address,
                mnemonic: candidate.mnemonic,
                operandString: candidate.operandString,
                resultRegister: next.register,
            )
        }
        return nil
    }

    /// `mov <reg>, #<imm>` decomposed, or `nil` when the instruction is
    /// something else.
    ///
    /// Matched on decoded operand types — register destination, immediate
    /// source — rather than on operand text.
    static func movRegisterImmediate(
        _ instruction: Instruction,
        _ disassembler: ARM64Disassembler,
    ) -> (register: String, immediate: Int64)? {
        guard instruction.mnemonic == "mov",
              let operands = instruction.aarch64?.operands,
              operands.count == 2,
              operands[0].type == AARCH64_OP_REG,
              operands[1].type == AARCH64_OP_IMM,
              let register = disassembler.firstRegisterName(instruction)
        else { return nil }
        return (register, operands[1].imm)
    }

    // MARK: - Recording

    /// Describe the write the way `cfw_records.record_span` does: component is
    /// the chunk file's basename, the offset is into that chunk, and the
    /// virtual address rides along.
    private static func record(
        for gate: Gate,
        in chunks: DSCChunkSet,
        original: Data,
        patched: Data,
    ) throws -> PatchRecord {
        let span = DSCWriteSpan(vma: gate.vma, length: patched.count)
        let (chunkURL, range) = try chunks.fileRange(of: span)
        return PatchRecord(
            patchID: patchID,
            component: chunkURL.lastPathComponent,
            fileOffset: range.lowerBound,
            virtualAddress: gate.vma,
            originalBytes: original,
            patchedBytes: patched,
            beforeDisasm: disassemblyText(of: original, at: gate.vma),
            afterDisasm: disassemblyText(of: patched, at: gate.vma),
            description: "NOP `\(gate.text)` in \(method) so the fall-through "
                + "sets \(gate.resultRegister)=1 (entitled)",
        )
    }

    private static func disassemblyText(of bytes: Data, at vma: UInt64) -> String {
        ARM64Disassembler()
            .disassemble(bytes, at: vma)
            .map { $0.operandString.isEmpty ? $0.mnemonic : "\($0.mnemonic) \($0.operandString)" }
            .joined(separator: "; ")
    }

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
