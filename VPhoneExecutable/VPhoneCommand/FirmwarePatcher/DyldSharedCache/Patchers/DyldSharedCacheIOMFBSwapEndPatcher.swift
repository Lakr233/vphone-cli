// DyldSharedCacheIOMFBSwapEndPatcher.swift — Make IOMobileFramebuffer's SwapEnd payload
// size match what the base kernel's userclient will accept.
//
// The SwapEnd input-state size is enforced kernel-side, not negotiated: the PCC
// vphone600 kernel's `IOMobileFramebufferUserClient` external method 5
// (SwapEnd / swap_submit) does an *exact* `checkStructureInputSize` comparison.
// A userland whose `_kern_SwapEnd` sends any other size gets
// `kIOReturnBadArgument` back, so no frame is ever presented and the host VZ
// display stays black — while the guest happily keeps rendering, which is why
// the Apple logo is visible over VNC and not in the vphone-cli window.
//
// The accepted size is a property of the BASE KERNEL, never of the userland:
//
//   * 26.1 base (older): the userclient expects 0x560.
//   * 26.4 base (xnu-12377, current): the userclient expects 0x588. Confirmed
//     twice over — the sole dispatch-shaped entry in
//     `kernelcache.*.vphone600` with `checkStructureInputSize == 0x588`
//     (scalarIn 0, scalarOut 0, structOut 0, preceded by a ptrauth code
//     pointer), and empirically, in that a native 26.5 userland sends 0x588 and
//     displays correctly on this stack.
//
// Sizes userlands are known to send: 18.6.2 → 0x514, 26.0/26.0.1 → 0x548,
// 26.5 → 0x588 (the native match on a 26.4 base), 27.0 (24A5380h) → 0x6e0.
//
// `_kern_SwapEnd` sets up an external-method-5 call:
//
//     ldr w0, [x0, #0x14]
//     add x2, x19, #0x18
//     mov w1, #5          <- external method selector 5
//     mov w3, #<size>     <- input-state size (source; version-specific)
//     mov x4, #0
//     mov x5, #0
//     bl  _io_connect_method
//
// The `mov w3, #<size>` immediate is the one thing this patcher rewrites.
//
// Nothing about the *source* size is written down here: it is discovered, never
// matched, so the patch fires on any userland that has this call shape. The site
// is found by resolving `_kern_SwapEnd` through the cache's own symbol tables,
// disassembling it, and anchoring on the semantic call-setup shape — the
// selector `mov w1, #5`, then the size `mov w3, #imm`, then the zeroed
// `mov x4, #0` / `mov x5, #0`, then the `bl`. The replacement word comes from
// `ARM64Encoder`.
//
// Port of `scripts/patchers/cfw_patch_iomfb_swapend.py`, which stays the
// independent reference — `DyldSharedCacheIOMFBSwapEndTests` runs the Python on one clone of
// the real cache and this on another, and compares the two byte for byte.
//
// One thing is deliberately not ported: the Python resolves `_kern_SwapEnd` by
// shelling out to `ipsw dyld symaddr`. Here that is `DyldSharedCacheSymbolResolver`, which
// reads the cache's export tries and its `.symbols` side file directly — same
// addresses, no Go tool on the patch path.

import Capstone
import Foundation

/// What one run of the SwapEnd size patch did.
public struct DyldSharedCacheIOMFBSwapEndPatch: Sendable {
    /// Address `_kern_SwapEnd` resolved to.
    public let functionVMA: UInt64
    /// Address of the `mov w3, #imm` that carries the payload size.
    public let siteVMA: UInt64
    /// The size the userland was sending before the patch.
    public let originalSize: UInt32
    /// The size the base kernel's userclient accepts.
    public let targetSize: UInt32
    /// True when the userland already sent `targetSize`, so nothing was written.
    public let wasAlreadyCorrect: Bool
    /// Sites written. 1 when the immediate was rewritten, 0 otherwise — the
    /// number the Python's `patched`/`already` distinction implies, made
    /// explicit so a parity run can compare it.
    public let sitesWritten: Int
    /// Re-attestation of the pages the write dirtied; `nil` on a dry run.
    public let reattestation: DyldSharedCacheReattestation?

    /// The Python's return value: one site *considered*, patched or not.
    public var sitesConsidered: Int {
        1
    }
}

public enum DyldSharedCacheIOMFBSwapEndPatcher {
    /// The image that carries `_kern_SwapEnd`.
    public static let imagePath =
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

    /// The function that sets up the external-method call.
    public static let symbolName = "_kern_SwapEnd"

    /// `IOMobileFramebufferUserClient` external method 5 — SwapEnd / swap_submit.
    ///
    /// This is an anchor: it is what identifies the call among the several
    /// `io_connect_method` set-ups in the image.
    public static let selector: Int64 = 5

    /// The input-state size the 26.4 vphone600 userclient accepts.
    ///
    /// A goal, not an anchor. The source immediate (0x6e0 on a 27.0 userland,
    /// 0x548 on 26.0) is discovered by disassembly and never compared against
    /// anything written down here. Pass `targetSize:` to build against a
    /// different base kernel — a 26.1 base wants 0x560.
    public static let defaultTargetSize: UInt32 = 0x588

    /// Argument register 4 of `io_connect_method(port, selector, input,
    /// inputCount, inputState, inputStateCount, …)` — the input-state size.
    static let sizeRegister = "w3"
    /// Argument registers 5 and 6, both zeroed in this call.
    static let zeroedRegisters = ["x4", "x5"]
    /// How far into `_kern_SwapEnd` to look. The call set-up is in the first
    /// dozen instructions on every userland seen so far; the Python uses the
    /// same bound.
    static let maximumInstructions = 64

    // MARK: - Entry points

    /// Patch the cache under `chunksDirectory`.
    ///
    /// - Parameters:
    ///   - chunksDirectory: the directory of `dyld_shared_cache_arm64e*` chunks.
    ///   - targetSize: the size the base kernel's userclient accepts.
    ///   - dryRun: report the site and the rewrite without touching the cache.
    ///   - log: where the per-site lines go. `nil` for silence.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        targetSize: UInt32 = defaultTargetSize,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheIOMFBSwapEndPatch {
        // Before opening a 6.7 GB cache and its 1.2 GB symbol table: a target
        // size that cannot be encoded is an argument error, and it should read
        // as one rather than as whatever the cache happens to say first.
        _ = try replacement(forTargetSize: targetSize)

        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory)
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        return try patch(
            chunks: chunks,
            resolver: resolver,
            targetSize: targetSize,
            dryRun: dryRun,
            log: log,
        )
    }

    /// Patch a cache that is already open.
    ///
    /// The re-attestation at the end covers only the writes this call made:
    /// `recordedWrites` is cleared first, so a caller that runs several DSC
    /// patchers over one `DyldSharedCacheChunkSet` does not re-hash the previous one's
    /// pages on every subsequent patch.
    @discardableResult
    public static func patch(
        chunks: DyldSharedCacheChunkSet,
        resolver: DyldSharedCacheSymbolResolver,
        targetSize: UInt32 = defaultTargetSize,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheIOMFBSwapEndPatch {
        let replacement = try replacement(forTargetSize: targetSize)

        log?("  [.] \(chunks.chunkURLs.count) chunk(s), \(chunks.mappings.count) mapping(s)")

        let functionVMA = try resolver.address(of: symbolName, inImage: imagePath)
        log?("  [.] \(symbolName) @ 0x\(hex(functionVMA))")

        let disassembler = ARM64Disassembler()
        let instructions = try disassembleFunction(
            in: chunks,
            at: functionVMA,
            maximumInstructions: maximumInstructions,
            disassembler: disassembler,
        )
        guard let site = findSizeInstruction(in: instructions, disassembler: disassembler),
              let current = movRegisterImmediate(site.instruction, disassembler: disassembler)
        else {
            throw PatcherError.patchSiteNotFound(
                "\(symbolName) SwapEnd size site (mov w1, #\(selector) -> "
                    + "mov \(sizeRegister), #imm -> mov x4, #0 -> mov x5, #0 -> bl) not found",
            )
        }

        let siteVMA = site.instruction.address
        let originalSize = UInt32(truncatingIfNeeded: current.immediate)
        let wasAlreadyCorrect = originalSize == targetSize

        if wasAlreadyCorrect {
            log?(
                "      [=] already 0x\(hex(targetSize)) at 0x\(hex(siteVMA)); "
                    + "re-attesting page only",
            )
        } else {
            log?(
                "      [\(dryRun ? "~" : "+")] \(dryRun ? "would patch" : "patched") "
                    + "\(imagePath) \(symbolName) size 0x\(hex(originalSize)) -> "
                    + "0x\(hex(targetSize)) at 0x\(hex(siteVMA))",
            )
        }

        var reattestation: DyldSharedCacheReattestation?
        if dryRun {
            log?("  [.] dry-run: would re-attest the page holding 0x\(hex(siteVMA))")
        } else {
            chunks.clearRecordedWrites()
            if !wasAlreadyCorrect {
                try chunks.write(at: siteVMA, replacement)
            }
            log?("  [.] re-attesting modified page(s)...")
            reattestation = try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: log)

            let readBack = try chunks.bytesAtVMA(siteVMA, length: replacement.count)
            guard readBack == replacement else {
                throw PatcherError.patchVerificationFailed(
                    "\(symbolName) size site at 0x\(hex(siteVMA)) reads back "
                        + "\(readBack.hex), expected \(replacement.hex)",
                )
            }
        }

        log?("  [+] IOMFB SwapEnd patch complete")
        return DyldSharedCacheIOMFBSwapEndPatch(
            functionVMA: functionVMA,
            siteVMA: siteVMA,
            originalSize: originalSize,
            targetSize: targetSize,
            wasAlreadyCorrect: wasAlreadyCorrect,
            sitesWritten: (dryRun || wasAlreadyCorrect) ? 0 : 1,
            reattestation: reattestation,
        )
    }

    // MARK: - The replacement instruction

    /// The `mov w3, #targetSize` that replaces the userland's own size move.
    ///
    /// Assembled by `ARM64Encoder`, whose MOVZ encoding is asserted against
    /// keystone's `asm("mov w3, #0x588")` in `ARM64EncoderTests`. No byte
    /// sequence is written down anywhere on this path.
    static func replacement(forTargetSize targetSize: UInt32) throws -> Data {
        guard let immediate = UInt16(exactly: targetSize) else {
            throw PatcherError.invalidFormat(
                "SwapEnd target size 0x\(hex(targetSize)) does not fit a MOVZ immediate",
            )
        }
        guard let encoded = ARM64Encoder.encodeMovzW(rd: 3, imm16: immediate),
              encoded.count == 4
        else {
            throw PatcherError.invalidFormat(
                "could not encode mov \(sizeRegister), #0x\(hex(targetSize))",
            )
        }
        return encoded
    }

    // MARK: - Finding the site

    /// The `mov w3, #imm` found inside the external-method call set-up, with the
    /// index it sits at — the index is what the tests assert the shape on.
    struct SizeSite {
        let instruction: Instruction
        let index: Int
    }

    /// Locate the `mov w3, #imm` that carries the SwapEnd input-state size.
    ///
    /// Anchored entirely on the call set-up's semantics: the selector
    /// `mov w1, #5`, then a `mov w3, #imm` whose immediate is whatever this
    /// userland happens to send, then the two zeroed argument registers, then
    /// the `bl` into `io_connect_method`. Every comparison here is on a decoded
    /// operand — register identity and immediate value — never on the rendered
    /// operand string.
    static func findSizeInstruction(
        in instructions: [Instruction],
        disassembler: ARM64Disassembler,
    ) -> SizeSite? {
        // selector, size, the zeroed argument registers, then the call.
        let shapeLength = 3 + zeroedRegisters.count
        guard instructions.count >= shapeLength else { return nil }

        for index in 0 ... (instructions.count - shapeLength) {
            guard let selectorMove = movRegisterImmediate(
                instructions[index],
                disassembler: disassembler,
            ), selectorMove.register == "w1", selectorMove.immediate == selector
            else { continue }

            guard let sizeMove = movRegisterImmediate(
                instructions[index + 1],
                disassembler: disassembler,
            ), sizeMove.register == sizeRegister
            else { continue }

            let zeroed = zeroedRegisters.enumerated().allSatisfy { offset, name in
                guard let move = movRegisterImmediate(
                    instructions[index + 2 + offset],
                    disassembler: disassembler,
                ) else { return false }
                return move.register == name && move.immediate == 0
            }
            guard zeroed else { continue }
            guard instructions[index + shapeLength - 1].mnemonic == "bl" else { continue }

            return SizeSite(instruction: instructions[index + 1], index: index + 1)
        }
        return nil
    }

    /// `(register, immediate)` when `instruction` is `mov <reg>, #<imm>`, else
    /// `nil`.
    ///
    /// The register name comes from Capstone's own register table rather than
    /// from splitting `operandString`, so `w3` and `w13` cannot be confused and
    /// a change in how Capstone renders an operand cannot move the site.
    static func movRegisterImmediate(
        _ instruction: Instruction,
        disassembler: ARM64Disassembler,
    ) -> (register: String, immediate: Int64)? {
        guard instruction.mnemonic == "mov" else { return nil }
        guard let operands = instruction.aarch64?.operands, operands.count == 2,
              operands[0].type == AARCH64_OP_REG,
              operands[1].type == AARCH64_OP_IMM,
              let name = disassembler.registerName(UInt32(operands[0].reg.rawValue))
        else { return nil }
        return (name, operands[1].imm)
    }

    /// Disassemble from `vma` up to the first `ret`/`retab` or
    /// `maximumInstructions`, whichever comes first.
    ///
    /// `allowShort` so a function that sits near the end of its contiguous run
    /// still disassembles as far as it goes, rather than throwing because the
    /// full instruction budget would overrun the mapping.
    static func disassembleFunction(
        in chunks: DyldSharedCacheChunkSet,
        at vma: UInt64,
        maximumInstructions: Int,
        disassembler: ARM64Disassembler,
    ) throws -> [Instruction] {
        let code = try chunks.readAtVMA(
            vma,
            length: maximumInstructions * 4,
            allowShort: true,
        )
        var result: [Instruction] = []
        for instruction in disassembler.disassemble(code, at: vma, count: maximumInstructions) {
            result.append(instruction)
            if instruction.mnemonic == "ret" || instruction.mnemonic == "retab" {
                break
            }
        }
        return result
    }

    // MARK: - Formatting

    private static func hex(_ value: some FixedWidthInteger) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
