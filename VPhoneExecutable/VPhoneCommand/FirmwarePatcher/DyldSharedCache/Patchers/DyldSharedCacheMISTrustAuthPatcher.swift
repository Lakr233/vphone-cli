// DyldSharedCacheMISTrustAuthPatcher.swift — force MIS's trust/authorization
// check to succeed.
//
// A guest restored by this project is *hacktivated*: `mobileactivationd`'s
// `-[DeviceType should_hactivate]` is forced to YES (see the
// `mobileactivationd.should_hactivate` declaration), so the device never talks
// to Apple's activation service and never receives an activation record. That
// is what makes the VM boot without an Apple ID, and it is also why a profile
// that wants online authorization can never get it:
//
//     online-auth-agent: Failed to copy activation record.     (MobileActivation -1)
//     online-auth-agent: Couldn't get device identity          (MobileActivation -25)
//     online-auth-agent: Could not perform authorization attempt
//
// Without a device identity there is nothing to sign an authorization request
// with, so `libmis`'s `checkTrustAndAuthorization` returns
// `0xE8008026` — "missing trust and/or authorization" — and every consumer
// treats the profile as unvalidated:
//
//     SpringBoard: validation failed because of missing trust and/or authorization (0xe8008026)
//     SpringBoard: [<bundle id> - signature state: Profile Needs Network Validation,
//                  reason: Requires Network Validation
//
// The practical effect is that an app signed with a *free* personal-team
// Apple Development certificate installs but refuses to launch, and Settings'
// "Verify App" can never clear it. A paid team's profile is not marked as
// needing online authorization and is unaffected either way.
//
// ## What is patched
//
// `checkTrustAndAuthorization` is a static function — it carries no symbol, and
// the cache's local symbol table cannot name it. It does, however, name itself
// in its own log strings, one of which spells the function outright:
//
//     "cdHash (%p) or matchedProfileIDs (%p) NULL in checkTrustAndAuthorization"
//
// Its prologue seeds the return register with the failure code and the body
// then subtracts its way to the other MIS errors in that range, or replaces it
// with 0 on success:
//
//     pacibsp                            <- function start
//     sub  sp, sp, #0xa0
//     stp  x28, x27, [sp, #0x40]
//     …
//     mov  w21, #0x8026                  <- the default: 0xE8008026
//     movk w21, #0xe800, lsl #16
//     …
//     sub  w21, w21, #0x2                <- 0xE8008024, and so on
//     …
//     mov  x0, x21 ; retab               <- w21 is the return value
//
// Both callers inside `MISValidateSignatureAndCopyInfoWithProgress` treat 0 as
// success, and the optional out-parameter is safe to leave untouched: one
// caller passes NULL for it outright, the other pre-zeroes the slot and skips
// the merge when it is still NULL. So the whole function is short-circuited:
//
//     pacibsp                            <- kept
//     mov  x0, #0                        <- was `sub sp, sp, #0xa0`
//     retab                              <- was `stp x28, x27, [sp, #0x40]`
//
// `pacibsp` is deliberately kept rather than overwritten. It signs LR with SP
// as the modifier, and `retab` authenticates with the SP it sees; returning
// before the frame is built means SP is unchanged between the two, so the pair
// is balanced. Replacing `pacibsp` with a plain `ret` would work here too, but
// keeping the PAC discipline intact is the smaller claim.
//
// ## Anchoring
//
// Nothing is hardcoded. Two independent routes must agree, in the manner of
// ``CustomFirmwareMobileActivation``:
//
//   1. The cstring above is located in the cache, its containing image is
//      confirmed to be `libmis.dylib`, and the ADRP+ADD pair that materialises
//      the literal is found by Capstone decode. Walking back from that site to
//      the nearest `pacibsp` gives the function start.
//   2. That prologue is then required to seed `0xE8008026` into the register
//      the function returns, within a short window — *or* to already hold this
//      patch's own output, `pacibsp ; mov x0, #0 ; retab`.
//
// If the string is gone the patch reports itself absent; if the string is there
// but the prologue is neither of those two shapes, MIS has changed and the
// install stops rather than guessing.
//
// The second shape is not decoration. The seed is normally several instructions
// into the prologue and survives the write, so the byte comparison in `patch`
// sees its own output and reports ``Outcome/alreadyPatched``. But where the
// compiler puts the seed in the two words this patch overwrites — reported on a
// 27.0 guest, `checkTrustAndAuthorization @ 0x22406F814` — the first run
// destroys the very anchor the second run looks for, and `cfw install` then
// dies part-way through on every later run. `DyldSharedCacheXPCLWCRPatcher` and
// `DyldSharedCacheLockdownModePatcher` were fixed for the same thing on
// 2026-09-22; this recognises its own shape the way they do.
//
// Writing a cache page invalidates its 16 KiB code slot, so the page is
// re-attested afterwards, exactly as the other shared-cache patchers do.

import Foundation
import VPhonePatchKit

/// Forces `checkTrustAndAuthorization` in `libmis.dylib` to return success, so
/// a profile that wants online authorization is accepted on a guest that has no
/// device identity to authorize with.
public enum DyldSharedCacheMISTrustAuthPatcher {
    /// The image the function lives in. Confirmed from the cache, not assumed.
    public static let image = "/usr/lib/libmis.dylib"

    /// The function being short-circuited. Static, so this is a name from its
    /// own log strings rather than from any symbol table.
    public static let function = "checkTrustAndAuthorization"

    /// Record identity. `mis_trust_auth` is the declaration prefix.
    public static let patchID = "mis_trust_auth.force_success"

    /// The literal that names the function. Matched with its NUL so the tail of
    /// a longer string cannot stand in for it.
    static let anchorString =
        "cdHash (%p) or matchedProfileIDs (%p) NULL in checkTrustAndAuthorization"

    /// The MIS error the prologue seeds: "missing trust and/or authorization".
    static let seededError: UInt32 = 0xE800_8026

    /// How far back from the string reference the function start may sit. The
    /// reference is in the last third of the function; 1024 instructions is
    /// several times its length.
    static let maxBacktrackInstructions = 1024

    /// How far into the prologue the seeded error may sit. It lands around the
    /// twentieth instruction; 48 is ample and still far short of the body.
    static let maxPrologueInstructions = 48

    /// Bytes written at `functionVMA + 4`: `mov x0, #0` then `retab`.
    static var replacement: Data { ARM64.movX0_0 + ARM64.retab }

    // MARK: - Results

    /// Which of the two accepted prologues the located function carries.
    public enum Shape: Sendable, Equatable {
        /// The stock prologue, seeding the failure code into the register the
        /// function returns. This is the shape that gets written.
        case seedsFailure(seedVMA: UInt64, resultRegister: String)
        /// The prologue already reads `pacibsp ; mov x0, #0 ; retab` — this
        /// patch's own output, from an earlier run over the same cache.
        case alreadyShortCircuited
    }

    /// The located function and the evidence that it is the right one.
    public struct Site: Sendable, Equatable {
        /// Address of the `pacibsp` that starts the function.
        public let functionVMA: UInt64
        /// Address of the ADRP that materialises the naming literal.
        public let anchorVMA: UInt64
        /// What the prologue looks like right now.
        public let shape: Shape

        /// Address of the `mov w<reg>, #0x8026` that seeds the failure code,
        /// or `nil` once this patch has replaced the prologue.
        public var seedVMA: UInt64? {
            guard case let .seedsFailure(vma, _) = shape else { return nil }
            return vma
        }

        /// The register the prologue seeds, which is the return value, or
        /// `nil` once this patch has replaced the prologue.
        public var resultRegister: String? {
            guard case let .seedsFailure(_, register) = shape else { return nil }
            return register
        }
    }

    /// What a run did.
    public enum Outcome: String, Sendable, Equatable {
        /// `libmis` in this cache does not carry the naming literal — a userland
        /// whose MIS predates or postdates this shape. Nothing was changed.
        case functionAbsent
        /// The site already held `mov x0, #0 ; retab`; the page was re-attested
        /// and nothing else changed.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The prologue was short-circuited and its page re-attested.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        /// The site, when the function was found.
        public let site: Site?
        /// The write. `nil` unless bytes actually changed.
        public let record: PatchRecord?

        /// Sites whose bytes this run changed. Exactly one, or none.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }

        /// Whether the function exists in this cache at all.
        public var functionIsPresent: Bool {
            outcome != .functionAbsent
        }
    }

    /// Where progress goes when the caller does not say.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Patching

    /// Short-circuit the check in the cache under `chunksDirectory`.
    ///
    /// Self-gating: a cache whose `libmis` does not carry the naming literal
    /// reports ``Outcome/functionAbsent`` and changes nothing.
    ///
    /// Idempotent: a cache this patch has already been run over reports
    /// ``Outcome/alreadyPatched``, re-attests its page and changes nothing.
    ///
    /// - Throws: ``PatcherError/patchSiteNotFound(_:)`` when the literal is
    ///   present but the function around it carries neither the seeding
    ///   prologue nor this patch's own output. That is a MIS rewrite, and it
    ///   has to stop the install rather than be guessed at.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory)
        log?("  [.] \(chunksDirectory.path): \(chunks.chunkURLs.count) chunk(s), "
            + "\(chunks.mappings.count) mapping(s)")

        guard let site = try locateSite(in: chunks, log: log) else {
            log?("      [=] \(function) not present in this cache; nothing to patch")
            return Report(outcome: .functionAbsent, site: nil, record: nil)
        }
        log?("  [.] \(function) @ 0x\(hex(site.functionVMA)) in \(image)")
        log?("      [.] named by literal referenced at 0x\(hex(site.anchorVMA))")
        switch site.shape {
        case let .seedsFailure(seedVMA, register):
            log?("      [.] seeds \(register)=0x\(hex(UInt64(seededError))) "
                + "at 0x\(hex(seedVMA))")
        case .alreadyShortCircuited:
            log?("      [.] prologue already reads `pacibsp ; mov x0, #0 ; retab`")
        }

        let target = site.functionVMA + 4
        let patched = replacement
        let original = try chunks.bytesAtVMA(target, length: patched.count)
        let alreadyPatched = original == patched

        if alreadyPatched {
            log?("      [=] already `mov x0, #0 ; retab` at 0x\(hex(target)); "
                + "re-attesting page only")
        } else {
            log?("      [+] \(dryRun ? "would short-circuit" : "short-circuited") "
                + "\(function) at 0x\(hex(target)) "
                + "(\(disassemblyText(of: original, at: target)) -> "
                + "\(disassemblyText(of: patched, at: target)))")
        }

        guard !dryRun else {
            guard !alreadyPatched else {
                return Report(outcome: .alreadyPatched, site: site, record: nil)
            }
            log?("  [.] dry-run: would re-attest page for 0x\(hex(target))")
            return Report(outcome: .wouldPatch, site: site, record: nil)
        }

        // Written unconditionally, including when the bytes already match, so
        // the idempotent case goes through the same re-attestation door as a
        // fresh write. `DyldSharedCacheCodeSignature` leaves a page whose stored
        // slot already matches alone.
        try chunks.write(at: target, patched)

        log?("  [.] re-attesting modified page...")
        try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: log)

        let written = try chunks.bytesAtVMA(target, length: patched.count)
        guard written == patched else {
            throw PatcherError.patchVerificationFailed(
                "\(function): site at 0x\(hex(target)) reads \(written.hex) after write",
            )
        }

        log?("  [+] MIS trust/authorization patch complete")

        guard !alreadyPatched else {
            return Report(outcome: .alreadyPatched, site: site, record: nil)
        }
        return try Report(
            outcome: .patched,
            site: site,
            record: record(for: site, in: chunks, original: original, patched: patched),
        )
    }

    // MARK: - Locating the function

    /// Find the function without touching the cache.
    ///
    /// Returns `nil` when the naming literal is absent, which is the
    /// nothing-to-do case rather than an error.
    public static func locateSite(
        in chunks: DyldSharedCacheChunkSet,
        log: ((String) -> Void)? = nil,
    ) throws -> Site? {
        var needle = Data(anchorString.utf8)
        needle.append(0)
        let stringVMAs = try chunks.findStringVMAs(needle)
        guard let stringVMA = stringVMAs.first else { return nil }
        if stringVMAs.count > 1 {
            log?("      [!] naming literal found \(stringVMAs.count) times; using the first")
        }

        guard let headerVMA = try chunks.findMachOHeaderBefore(stringVMA) else {
            throw PatcherError.invalidFormat(
                "\(function): the naming literal at 0x\(hex(stringVMA)) belongs to no image",
            )
        }
        let installName = chunks.readInstallName(atHeaderVMA: headerVMA)
        guard installName == image else {
            throw PatcherError.invalidFormat(
                "\(function): the naming literal is in \(installName ?? "an unnamed image"), "
                    + "not \(image) — refusing to patch an image this patch does not know",
            )
        }

        guard let anchorVMA = try findLiteralReference(to: stringVMA, in: chunks, from: headerVMA)
        else {
            throw PatcherError.patchSiteNotFound(
                "\(function): nothing in \(image) materialises the naming literal at "
                    + "0x\(hex(stringVMA)) — the string is present but unreferenced",
            )
        }

        guard let functionVMA = try findFunctionStart(before: anchorVMA, in: chunks) else {
            throw PatcherError.patchSiteNotFound(
                "\(function): no `pacibsp` within \(maxBacktrackInstructions) instructions "
                    + "before the literal reference at 0x\(hex(anchorVMA))",
            )
        }

        // This patch's own output first. On a cache where the seed survives the
        // write both tests pass, and answering "already short-circuited" there
        // keeps a second run's log saying the same thing as a second run's
        // outcome. On a cache where the seed *was* the two words this patch
        // overwrites, this is the only test that can still recognise the site.
        let prologue = try decodePrologue(at: functionVMA, in: chunks)
        if isShortCircuited(prologue) {
            return Site(functionVMA: functionVMA, anchorVMA: anchorVMA, shape: .alreadyShortCircuited)
        }

        guard let seed = try findSeededError(at: functionVMA, in: chunks) else {
            throw PatcherError.patchSiteNotFound(
                "\(function): the prologue at 0x\(hex(functionVMA)) neither seeds "
                    + "0x\(hex(UInt64(seededError))) nor already reads "
                    + "`pacibsp ; mov x0, #0 ; retab` — MIS has been rewritten",
            )
        }

        return Site(
            functionVMA: functionVMA,
            anchorVMA: anchorVMA,
            shape: .seedsFailure(seedVMA: seed.vma, resultRegister: seed.register),
        )
    }

    /// Decode the first few instructions at `functionVMA`.
    ///
    /// Three words is all ``isShortCircuited(_:)`` looks at; a fourth is read
    /// so a truncated stream is visibly truncated rather than silently short.
    static func decodePrologue(
        at functionVMA: UInt64,
        in chunks: DyldSharedCacheChunkSet,
    ) throws -> [ARM64Instruction] {
        let buffer = try chunks.readAtVMA(functionVMA, length: 16, allowShort: true)
        return ARM64Disassembler().disassemble(buffer, at: functionVMA)
    }

    /// Whether `decoded` is the shape this patch leaves behind:
    ///
    ///     pacibsp
    ///     mov  x0, #0
    ///     retab
    ///
    /// Read off the decode, never off operand text: the `#0` is the `mov`'s
    /// decoded immediate and `x0` its decoded destination register.
    ///
    /// A stock function cannot be mistaken for this. `pacibsp` signs LR before
    /// the frame is built, so a function that then returns 0 without building
    /// one has no body at all — and if some future `checkTrustAndAuthorization`
    /// really did return 0 unconditionally, patching it would be a no-op
    /// anyway, which is exactly what this reports.
    static func isShortCircuited(_ decoded: [ARM64Instruction]) -> Bool {
        guard decoded.count >= 3,
              decoded[0].isDecoded, decoded[1].isDecoded, decoded[2].isDecoded,
              decoded[0].mnemonic == "pacibsp",
              decoded[2].mnemonic == "retab",
              decoded[1].mnemonic == "mov",
              let operands = decoded[1].detail?.operands,
              operands.count == 2,
              operands[0].type == .register,
              operands[0].reg.name == "x0",
              operands[1].type == .immediate,
              operands[1].imm == 0
        else { return false }
        return true
    }

    /// The address of the `add` of the first ADRP+ADD pair in this image that
    /// resolves to `literalVMA`.
    ///
    /// Decoded with Capstone rather than by masking raw words: the `adrp`
    /// operand is already the absolute page and the `add` operand is already the
    /// offset, so the pair is matched on operand semantics.
    ///
    /// Only *adjacent* pairs are considered, which is what this compiler emits
    /// for a literal-pool address and what the other patchers in this project
    /// already assume. A split pair would be missed, and missing it reports a
    /// site-not-found rather than patching the wrong place.
    static func findLiteralReference(
        to literalVMA: UInt64,
        in chunks: DyldSharedCacheChunkSet,
        from headerVMA: UInt64,
    ) throws -> UInt64? {
        let disassembler = ARM64Disassembler()
        // The literal lives past the code, so the text to scan is bounded by the
        // two: everything between the image header and the string itself.
        guard literalVMA > headerVMA else { return nil }

        // Walked one contiguous run at a time. `readAtVMA(allowShort:)` stops at
        // a chunk boundary, and an image that straddles one would otherwise have
        // its tail silently dropped — reported as "unreferenced", which is an
        // error this patch raises. Consecutive windows overlap by one
        // instruction so a pair split across the seam is still seen.
        var cursor = headerVMA
        while cursor < literalVMA {
            let remaining = Int(literalVMA - cursor)
            let buffer = try chunks.readAtVMA(cursor, length: remaining, allowShort: true)
            guard buffer.count >= 8 else { break }
            let decoded = disassembler.disassemble(buffer, at: cursor)

            for index in 0 ..< max(decoded.count - 1, 0) {
                let adrp = decoded[index]
                let add = decoded[index + 1]
                guard adrp.isDecoded, add.isDecoded,
                      adrp.mnemonic == "adrp", add.mnemonic == "add",
                      let adrpOperands = adrp.detail?.operands,
                      let addOperands = add.detail?.operands,
                      adrpOperands.count == 2,
                      adrpOperands[1].type == .immediate,
                      addOperands.count == 3,
                      addOperands[1].type == .register,
                      addOperands[2].type == .immediate,
                      // The add must build on the page the adrp just produced.
                      let page = disassembler.firstRegisterName(adrp),
                      addOperands[1].reg.name == page,
                      UInt64(bitPattern: adrpOperands[1].imm)
                      &+ UInt64(bitPattern: addOperands[2].imm) == literalVMA
                else { continue }
                return add.address
            }

            guard buffer.count < remaining else { break }
            cursor &+= UInt64(buffer.count - 4)
        }
        return nil
    }

    /// The nearest `pacibsp` at or before `vma`, which for this compiler's
    /// output is the start of the function containing `vma`.
    ///
    /// The backward window is shrunk until it lies wholly inside `vma`'s own
    /// chunk. A window that began in an earlier chunk comes back truncated from
    /// `readAtVMA(allowShort:)`, and the last `pacibsp` in a truncated window is
    /// some earlier function's — picking it would patch the wrong prologue, so
    /// the window is only trusted once the decode actually reaches `vma`.
    static func findFunctionStart(
        before vma: UInt64,
        in chunks: DyldSharedCacheChunkSet,
    ) throws -> UInt64? {
        let disassembler = ARM64Disassembler()
        var windowInstructions = maxBacktrackInstructions

        while windowInstructions > 0 {
            let windowBytes = UInt64(windowInstructions * 4)
            let start = vma > windowBytes ? vma - windowBytes : 0
            let buffer = try chunks.readAtVMA(
                start,
                length: Int(vma - start) + 4,
                allowShort: true,
            )
            let decoded = disassembler.disassemble(buffer, at: start)

            guard let last = decoded.last, last.address >= vma else {
                windowInstructions /= 2
                continue
            }
            var candidate: UInt64?
            for instruction in decoded
                where instruction.address <= vma
                && instruction.isDecoded
                && instruction.mnemonic == "pacibsp"
            {
                candidate = instruction.address
            }
            return candidate
        }
        return nil
    }

    /// The `mov w<reg>, #0x8026` / `movk w<reg>, #0xe800, lsl #16` pair that
    /// seeds the failure code, searched from the function start.
    ///
    /// Matched on decoded operands: the `mov`'s immediate is the low half, the
    /// `movk`'s is the high half, and both must name the same register.
    static func findSeededError(
        at functionVMA: UInt64,
        in chunks: DyldSharedCacheChunkSet,
    ) throws -> (vma: UInt64, register: String)? {
        let disassembler = ARM64Disassembler()
        let buffer = try chunks.readAtVMA(
            functionVMA,
            length: maxPrologueInstructions * 4,
            allowShort: true,
        )
        let decoded = disassembler.disassemble(buffer, at: functionVMA)
        let low = Int64(seededError & 0xFFFF)
        let high = Int64((seededError >> 16) & 0xFFFF)

        for index in 0 ..< max(decoded.count - 1, 0) {
            let first = decoded[index]
            let second = decoded[index + 1]
            guard first.isDecoded, second.isDecoded,
                  first.mnemonic == "mov", second.mnemonic == "movk",
                  let firstOperands = first.detail?.operands,
                  let secondOperands = second.detail?.operands,
                  firstOperands.count == 2,
                  firstOperands[0].type == .register,
                  firstOperands[1].type == .immediate,
                  firstOperands[1].imm == low,
                  secondOperands.count >= 2,
                  secondOperands[1].type == .immediate,
                  secondOperands[1].imm == high,
                  let register = disassembler.firstRegisterName(first),
                  disassembler.firstRegisterName(second) == register,
                  register.hasPrefix("w")
            else { continue }
            return (first.address, register)
        }
        return nil
    }

    // MARK: - Recording

    /// Describe the write the way the other shared-cache patchers do: component
    /// is the chunk file's basename, the offset is into that chunk, and the
    /// virtual address rides along.
    private static func record(
        for site: Site,
        in chunks: DyldSharedCacheChunkSet,
        original: Data,
        patched: Data,
    ) throws -> PatchRecord {
        let target = site.functionVMA + 4
        let span = DyldSharedCacheWriteSpan(vma: target, length: patched.count)
        let (chunkURL, range) = try chunks.fileRange(of: span)
        return PatchRecord(
            patchID: patchID,
            component: chunkURL.lastPathComponent,
            fileOffset: range.lowerBound,
            virtualAddress: target,
            originalBytes: original,
            patchedBytes: patched,
            beforeDisasm: disassemblyText(of: original, at: target),
            afterDisasm: disassemblyText(of: patched, at: target),
            description: "Return 0 from \(function) in \(image) instead of seeding "
                + "\(site.resultRegister ?? "the result register")"
                + "=0x\(hex(UInt64(seededError))), so a profile "
                + "needing online authorization is accepted without a device identity",
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
