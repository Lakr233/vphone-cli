// DSCXPCLWCRPatcher.swift — libxpc's Lightweight Code Requirement self-check.
//
// Swift port of `scripts/patchers/cfw_patch_xpc_lwcr.py` (`cfw.py
// patch-xpc-lwcr`). See research/0_binary_patch_comparison.md #15.
//
// What breaks
// -----------
// iOS 27 introduced XPC "lightweight code requirements": a server pins a code
// requirement on its listener — `xpc_connection_set_peer_lightweight_code_
// requirement`, or the Swift `XPCPeerRequirement.hasEntitlement(_:)` wrapper —
// and libxpc evaluates whether a token satisfies it in
// `_xpc_token_satisfies_lwcr`. That function calls an internal matcher which
// returns two things — a `matched` bool in w0 and a `match_result.error_code`
// in memory — and then hard-asserts that the two agree:
//
//     bl      <matcher>            ; w0 = matched
//     ldr     wC, [xR]             ; wC = match_result.error_code
//     cmp     wC, #0               ; AICMR_MATCH == 0
//     cset    wC, ne               ; wC = (error_code != 0)
//     eor     wE, w0, wC           ; wE = matched ^ (error_code != 0)
//     tbz     wE, #0, <abort>      ; _os_crash_msg → brk #1 when they disagree
//
// On stock iOS the two always agree. Under the JB's code-signing environment
// the matcher's query writes `error_code = MATCH(0)` and then returns a failure
// status, producing the forbidden `(matched = 0, error_code = 0)` pair. libxpc
// aborts, so every daemon that pins an entitlement peer-requirement at startup
// — intelligencetasksd, searchpartyd, transparencyd, bluetoothd — crash-loops
// from boot.
//
// The fix
// -------
// Make `matched` consistent with `error_code` by construction and drop the
// abort. The return is derived from `error_code`, which is the matcher's own
// verdict, and the xor plus the conditional branch become NOPs:
//
//     cset  wC, ne   ->  cset w0, eq    ; w0 = matched = (error_code == 0)
//     eor   wE,…     ->  nop
//     tbz   wE,#0,…  ->  nop            ; falls through to the normal return
//
// Real allow/deny survives: `error_code` drives it exactly as stock does when
// the two agree, and only the internally contradictory case is resolved — in
// favour of "satisfied", because that is what `error_code` said.
//
// Nothing here is hardcoded. `_xpc_token_satisfies_lwcr` comes out of the
// cache's own local-symbol table, the function is disassembled with Capstone,
// the check is located by the shape of its control flow, and every replacement
// word comes from `ARM64Encoder` / `ARM64`. The pages the writes dirty are
// re-attested through `DSCCodeSignature`, because TXM validates the shared
// cache per 16 KiB page; the resulting cdHash change is accepted by the JB's
// always-true AMFI cdhash-trust patch.

import Capstone
import Foundation

/// Patches `_xpc_token_satisfies_lwcr` in the shared cache's libxpc.
public enum DSCXPCLWCRPatcher {
    /// The source-level name of the function this patches.
    public static let symbol = "_xpc_token_satisfies_lwcr"

    /// Spellings to try, in order.
    ///
    /// Mach-O prefixes C symbols with an underscore, so a source name that
    /// already starts with one lands in the symbol table with two. Looking up
    /// only the single-underscore spelling is how this patch silently skipped
    /// every iOS 27 build until 2026-08-11, which is why the mangled name is
    /// tried first and both are tried at all.
    public static let symbolCandidates = ["__xpc_token_satisfies_lwcr", symbol]

    /// How far into the function to disassemble before giving up.
    ///
    /// The real function is 48 instructions and ends in `retab`; the walk stops
    /// there. This is the ceiling for a build whose epilogue moved, not a size.
    static let maxInstructions = 160

    /// The record group this patcher writes under, matching `cfw_records`.
    public static let recordGroup = "xpc_lwcr"

    // MARK: - Outcome

    /// What a run did.
    public struct Outcome: Sendable {
        public enum Status: Sendable, Equatable {
            /// The three sites were rewritten (or, on a dry run, would have been).
            case patched
            /// The cache already carries this patch; nothing was written.
            case alreadyPatched
            /// No `_xpc_token_satisfies_lwcr` in this cache — a pre-iOS-27
            /// userland, where there is no LWCR path to break.
            case symbolAbsent
        }

        public let status: Status
        /// Address of `_xpc_token_satisfies_lwcr`, when it was found.
        public let functionVMA: UInt64?
        /// The symbol spelling that resolved.
        public let resolvedName: String?
        /// One record per site this run changed. Empty for the two no-op statuses.
        public let records: [PatchRecord]

        /// Sites written — the number the Python prints, and the number the
        /// parity test compares.
        public var siteCount: Int {
            records.count
        }
    }

    // MARK: - Entry point

    /// Apply the patch to the cache under `directory`.
    ///
    /// Mirrors `patch_xpc_lwcr(chunks_dir, dry_run=)`: a cache without the
    /// symbol is a no-op rather than a failure, a cache that already carries
    /// the patch is a no-op too, and a cache that has the symbol but not the
    /// idiom is an error.
    @discardableResult
    public static func apply(
        directory: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DSCCodeSignature.stderrLog,
    ) throws -> Outcome {
        let chunks = try DSCChunkSet(directory: directory)
        return try apply(chunks: chunks, dryRun: dryRun, log: log)
    }

    /// Apply the patch to an already-open cache.
    ///
    /// Re-attestation goes through `reattestRecordedWrites(in:)`, so it covers
    /// every page this chunk set has been written through — this patcher's
    /// three words, and anything an earlier patcher wrote and has not yet
    /// re-attested. A caller batching patchers that wants the pages split per
    /// patcher calls `clearRecordedWrites()` between them.
    @discardableResult
    public static func apply(
        chunks: DSCChunkSet,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DSCCodeSignature.stderrLog,
    ) throws -> Outcome {
        log?("  [.] \(chunks.directory.path) — \(chunks.chunkURLs.count) chunk(s), "
            + "\(chunks.mappings.count) mapping(s)")

        // Self-gating: the LWCR path only exists on iOS 27+ libxpc, so on an
        // older userland the symbol is simply absent and there is nothing to
        // patch. A *missing* `.symbols` file is a different answer and throws.
        var functionVMA: UInt64?
        var resolvedName: String?
        for candidate in symbolCandidates {
            if let address = try chunks.resolveLocalSymbol(candidate) {
                functionVMA = address
                resolvedName = candidate
                break
            }
        }
        guard let functionVMA, let resolvedName else {
            log?("      [=] \(symbol) not present (pre-iOS-27 userland); nothing to patch")
            return Outcome(
                status: .symbolAbsent,
                functionVMA: nil,
                resolvedName: nil,
                records: [],
            )
        }
        log?("  [.] \(resolvedName) @ 0x\(hex(functionVMA))")

        let disassembler = ARM64Disassembler()
        let instructions = try disassembleFunction(
            in: chunks,
            at: functionVMA,
            disassembler: disassembler,
        )

        guard let site = findConsistencyCheck(in: instructions, disassembler: disassembler) else {
            if let already = findPatchedShape(in: instructions, disassembler: disassembler) {
                log?("      [=] already patched at 0x\(hex(already.address)) "
                    + "(cset w0,eq; nop; nop); nothing to patch/re-attest")
                log?("  [+] libxpc LWCR self-check patch complete")
                return Outcome(
                    status: .alreadyPatched,
                    functionVMA: functionVMA,
                    resolvedName: resolvedName,
                    records: [],
                )
            }
            throw PatcherError.patchSiteNotFound(
                "\(symbol): LWCR consistency idiom (cset wC,ne; eor wE,w0,wC; tbz wE,#0) "
                    + "not found at 0x\(hex(functionVMA))",
            )
        }

        for (label, insn) in [("cset", site.cset), ("eor ", site.eor), ("tbz ", site.tbz)] {
            log?("      [.] \(label) @ 0x\(hex(insn.address)): \(text(insn))")
        }

        // Every replacement word comes from the encoders, never from a literal.
        guard let csetW0EQ = ARM64Encoder.encodeCsetW(rd: 0, condition: .eq) else {
            throw PatcherError.patchVerificationFailed("could not encode `cset w0, eq`")
        }
        let edits: [Edit] = [
            Edit(address: site.cset.address, bytes: csetW0EQ, label: "cset w0, eq"),
            Edit(address: site.eor.address, bytes: ARM64.nop, label: "nop"),
            Edit(address: site.tbz.address, bytes: ARM64.nop, label: "nop"),
        ]

        var records: [PatchRecord] = []
        var wrote = false
        for edit in edits {
            let current = try chunks.bytesAtVMA(edit.address, length: edit.bytes.count)
            if current == edit.bytes {
                log?("      [=] already patched at 0x\(hex(edit.address)) (\(edit.label))")
                continue
            }
            log?("      [+] \(dryRun ? "would write" : "wrote") \(edit.label) "
                + "at 0x\(hex(edit.address)) (\(current.hex) -> \(edit.bytes.hex))")
            if !dryRun {
                try chunks.write(at: edit.address, edit.bytes)
                wrote = true
            }
            let location = chunks.findChunk(forVMA: edit.address)
            records.append(record(
                for: edit,
                original: current,
                chunkName: location?.chunkURL.lastPathComponent ?? chunks.directory.lastPathComponent,
                fileOffset: location?.fileOffset ?? 0,
                disassembler: disassembler,
            ))
        }

        if wrote {
            log?("  [.] re-attesting modified page(s)...")
            try DSCCodeSignature.reattestRecordedWrites(in: chunks, dryRun: false, log: log)
            for edit in edits {
                let readBack = try chunks.bytesAtVMA(edit.address, length: edit.bytes.count)
                guard readBack == edit.bytes else {
                    throw PatcherError.patchVerificationFailed(
                        "post-write verify failed at 0x\(hex(edit.address))",
                    )
                }
            }
        } else if dryRun, !records.isEmpty {
            log?("  [.] dry-run: would re-attest page for "
                + records.map { "0x\(hex($0.virtualAddress ?? 0))" }.joined(separator: ", "))
        }

        log?("  [+] libxpc LWCR self-check patch complete")
        return Outcome(
            status: records.isEmpty ? .alreadyPatched : .patched,
            functionVMA: functionVMA,
            resolvedName: resolvedName,
            records: records,
        )
    }

    // MARK: - Site discovery

    /// The three instructions the patch rewrites.
    struct ConsistencyCheck {
        let cset: Instruction
        let eor: Instruction
        let tbz: Instruction
    }

    /// Locate the LWCR self-consistency idiom.
    ///
    ///     cset  wC, ne
    ///     eor   wE, w0, wC
    ///     tbz   wE, #0, <abort>
    ///
    /// Anchored on the `eor`, because that is the only instruction in the
    /// function that xors the matcher's return register with anything: the
    /// `cset` and the `tbz` are common shapes on their own, and the register
    /// dataflow between the three is what makes the match unambiguous.
    static func findConsistencyCheck(
        in instructions: [Instruction],
        disassembler: ARM64Disassembler,
    ) -> ConsistencyCheck? {
        guard instructions.count >= 2 else { return nil }
        for index in 0 ..< (instructions.count - 1) {
            let eor = instructions[index]
            guard eor.mnemonic == "eor",
                  let destination = register(eor, 0, disassembler),
                  let left = register(eor, 1, disassembler),
                  let source = register(eor, 2, disassembler),
                  left == "w0"
            else { continue }

            // `tbz wE, #0` — bit 0 of the xor, i.e. "the two disagree".
            let tbz = instructions[index + 1]
            guard tbz.mnemonic == "tbz",
                  register(tbz, 0, disassembler) == destination,
                  let bit = immediate(tbz, 1), bit == 0
            else { continue }

            // The `cset wC, ne` feeding the xor, within a short window back.
            var cset: Instruction?
            var back = index - 1
            while back >= 0, back >= index - 5 {
                let candidate = instructions[back]
                if candidate.mnemonic == "cset", register(candidate, 0, disassembler) == source {
                    // The condition is read off Capstone's decode, not the
                    // printed operand text.
                    if candidate.aarch64?.conditionCode == AArch64CC_NE {
                        cset = candidate
                    }
                    break
                }
                back -= 1
            }
            guard let cset else { continue }
            return ConsistencyCheck(cset: cset, eor: eor, tbz: tbz)
        }
        return nil
    }

    /// Locate the shape this patch itself leaves behind, so a second run over
    /// an installed cache reports a no-op instead of failing.
    ///
    ///     cmp   wX, #0     ; error_code == AICMR_MATCH
    ///     cset  w0, eq     ; the replacement for `cset wC, ne`
    ///     nop              ; was eor wE, w0, wC
    ///     nop              ; was tbz wE, #0, <abort>
    ///
    /// The per-edit byte comparison in `apply` cannot stand in for this: it
    /// needs addresses that `findConsistencyCheck` has to supply first, and
    /// that search looks for the very instructions this patch replaced. On an
    /// already-patched cache the idiom is gone by construction.
    static func findPatchedShape(
        in instructions: [Instruction],
        disassembler: ARM64Disassembler,
    ) -> Instruction? {
        guard instructions.count >= 3 else { return nil }
        for index in 0 ..< (instructions.count - 2) {
            let cset = instructions[index]
            guard cset.mnemonic == "cset",
                  register(cset, 0, disassembler) == "w0",
                  cset.aarch64?.conditionCode == AArch64CC_EQ,
                  instructions[index + 1].mnemonic == "nop",
                  instructions[index + 2].mnemonic == "nop"
            else { continue }

            // The `cmp wX, #0` feeding it keeps this from matching an unrelated
            // `cset w0, eq` that happens to sit in front of padding.
            var back = index - 1
            while back >= 0, back >= index - 4 {
                let candidate = instructions[back]
                guard candidate.mnemonic == "cmp" else {
                    back -= 1
                    continue
                }
                let operands = candidate.aarch64?.operands ?? []
                if operands.count == 2, let value = immediate(candidate, 1), value == 0 {
                    return cset
                }
                break
            }
        }
        return nil
    }

    // MARK: - Disassembly

    /// Disassemble from `vma` up to the function's `ret`/`retab`, or
    /// `maxInstructions`, whichever comes first.
    ///
    /// The read is allowed to come up short so a function that sits near the
    /// end of its mapping still disassembles as far as the mapping goes,
    /// instead of failing the whole patch on a window that overshoots.
    static func disassembleFunction(
        in chunks: DSCChunkSet,
        at vma: UInt64,
        disassembler: ARM64Disassembler,
    ) throws -> [Instruction] {
        let window = try chunks.readAtVMA(vma, length: maxInstructions * 4, allowShort: true)
        var result: [Instruction] = []
        for insn in disassembler.disassemble(window, at: vma) {
            result.append(insn)
            if insn.mnemonic == "ret" || insn.mnemonic == "retab" {
                break
            }
        }
        return result
    }

    // MARK: - Operand helpers

    /// Canonical name of operand `index` when it is a register, else `nil`.
    static func register(
        _ insn: Instruction,
        _ index: Int,
        _ disassembler: ARM64Disassembler,
    ) -> String? {
        guard let operands = insn.aarch64?.operands, index < operands.count else { return nil }
        let operand = operands[index]
        guard operand.type == AARCH64_OP_REG else { return nil }
        return disassembler.registerName(UInt32(operand.reg.rawValue))
    }

    /// Value of operand `index` when it is an immediate, else `nil`.
    static func immediate(_ insn: Instruction, _ index: Int) -> Int64? {
        guard let operands = insn.aarch64?.operands, index < operands.count else { return nil }
        let operand = operands[index]
        guard operand.type == AARCH64_OP_IMM else { return nil }
        return operand.imm
    }

    // MARK: - Records and formatting

    struct Edit {
        let address: UInt64
        let bytes: Data
        let label: String
    }

    private static func record(
        for edit: Edit,
        original: Data,
        chunkName: String,
        fileOffset: Int,
        disassembler: ARM64Disassembler,
    ) -> PatchRecord {
        PatchRecord(
            patchID: "\(recordGroup).\(edit.label.split(separator: " ").first ?? "")"
                + "@0x\(hex(edit.address))",
            component: chunkName,
            fileOffset: fileOffset,
            virtualAddress: edit.address,
            originalBytes: original,
            patchedBytes: edit.bytes,
            beforeDisasm: disassembler.disassembleOne(original, at: edit.address).map(text) ?? "",
            afterDisasm: disassembler.disassembleOne(edit.bytes, at: edit.address).map(text) ?? "",
            description: "\(symbol): `\(edit.label)` — derive matched from error_code "
                + "and drop the abort",
        )
    }

    private static func text(_ insn: Instruction) -> String {
        insn.operandString.isEmpty ? insn.mnemonic : "\(insn.mnemonic) \(insn.operandString)"
    }

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
