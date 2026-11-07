// TextRecognition picks its text detector, its Latin, Arabic and Devanagari
// recognizers and its orientation model by `deviceHasModernNeuralEngine`: E5
// models on a modern Neural Engine, Espresso CPU models otherwise. That
// predicate requires `deviceHasAppleNeuralEngine`, which answers false as soon
// as MobileGestalt reports `IsVirtualDevice`, before it asks Espresso for a
// Neural Engine context. A guest with the paravirtual Neural Engine therefore
// gets the CPU detector, whose weights the iPhone firmware does not ship (a
// physical iPhone never loads it), and accurate recognition fails with
// CRImageReaderError 9.
//
// Only the modern predicate's dependency on the existence predicate is
// removed. Its block then caches `MGGetSInt64Answer("AppleNeuralEngineSubtype",
// 1) > 31` alone. The existence predicate keeps its VM answer: it also routes
// the Espresso Chinese, Japanese and Korean recognizers to the Neural Engine,
// whose H18-only binaries cannot run on the paravirtual device. The E5 models
// compile from MIL, which `cfw install` adds beside the firmware's hardware
// binaries from the host's own TextRecognition (see
// `CustomFirmwareTextRecognitionModels`).
//
// The site is the `tbz` on the cached existence answer in the block's fast
// path. The block is resolved from the cache's local symbols, its call is
// resolved to MobileGestalt's answer function, directly or through a stub, and
// the comparison, its store and the branch target must all match before the
// single `tbz` becomes a `nop`. A `nop` in the same shape is this patch's own
// output.

import Foundation
import VPhonePatchKit

public struct DyldSharedCacheTextRecognitionANEPatch: Sendable {
    public let siteVMA: UInt64?
    public let wasAlreadyPatched: Bool
    public let sitesWritten: Int
    public let reattestation: DyldSharedCacheReattestation?
}

public enum DyldSharedCacheTextRecognitionANEPatcher {
    public static let imagePath = "/System/Library/PrivateFrameworks/TextRecognition.framework/TextRecognition"
    public static let blockSymbol = "___deviceHasModernNeuralEngine_block_invoke"
    static let gestaltImage = "/usr/lib/libMobileGestalt.dylib"
    static let gestaltSymbol = "_MGGetSInt64Answer"
    /// The predicate calls a Neural Engine subtype above this modern.
    static let modernSubtype: Int64 = 0x1F

    struct Site {
        let address: UInt64
        let alreadyPatched: Bool
    }

    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheTextRecognitionANEPatch {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, captureUndo: captureUndo)
        do {
            let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
            let result = try patch(chunks: chunks, resolver: resolver, dryRun: dryRun, log: log)
            if captureUndo, let undo = chunks.takeUndoLog() { onUndo?(undo) }
            return result
        } catch {
            if captureUndo, let failure = error as? DyldSharedCachePatchRollbackError {
                onUndo?(failure.recoveryUndo)
            }
            throw error
        }
    }

    @discardableResult
    public static func patch(
        chunks: DyldSharedCacheChunkSet,
        resolver: DyldSharedCacheSymbolResolver,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheTextRecognitionANEPatch {
        guard resolver.imagePaths.contains(imagePath) else {
            log?("  [-] TextRecognition is not in this cache; nothing to patch")
            return DyldSharedCacheTextRecognitionANEPatch(
                siteVMA: nil, wasAlreadyPatched: false, sitesWritten: 0, reattestation: nil,
            )
        }
        try resolver.requireLocalSymbols()
        let block = try resolver.address(of: blockSymbol, inImage: imagePath)
        let answer = try resolver.address(of: gestaltSymbol, inImage: gestaltImage)
        let disassembler = ARM64Disassembler()
        let instructions = try DyldSharedCacheIOMFBSwapEndPatcher.disassembleFunction(
            in: chunks, at: block, maximumInstructions: 64, disassembler: disassembler,
        )
        let site = try findSite(in: instructions, answer: answer) { address in
            disassembler.disassemble(try chunks.readAtVMA(address, length: 12), at: address)
        }

        log?("  [.] \(blockSymbol) @ 0x\(hex(block)); existence gate @ 0x\(hex(site.address))")
        log?("  [\(site.alreadyPatched ? "=" : dryRun ? "~" : "+")] modern Neural Engine from its subtype alone\(site.alreadyPatched ? " already patched" : "")")
        var reattestation: DyldSharedCacheReattestation?
        if !dryRun, !site.alreadyPatched {
            let span = DyldSharedCacheWriteSpan(vma: site.address, length: ARM64.nop.count)
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: [span], in: chunks)
            chunks.clearRecordedWrites()
            reattestation = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: "TextRecognition Neural Engine patch", log: log) {
                try chunks.write(at: site.address, ARM64.nop)
                let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: [span], log: log)
                guard result.isFullyAttested else {
                    throw PatcherError.patchVerificationFailed("TextRecognition re-attestation skipped \(result.skipped.count) page(s)")
                }
                guard try chunks.bytesAtVMA(site.address, length: ARM64.nop.count) == ARM64.nop else {
                    throw PatcherError.patchVerificationFailed("TextRecognition Neural Engine patch did not read back")
                }
                return result
            }
        }
        return DyldSharedCacheTextRecognitionANEPatch(
            siteVMA: site.address,
            wasAlreadyPatched: site.alreadyPatched,
            sitesWritten: dryRun || site.alreadyPatched ? 0 : 1,
            reattestation: reattestation,
        )
    }

    // MARK: - Semantic site discovery

    /// The fast path of the block, from the load of the cached existence
    /// answer to the store of the modern one:
    ///
    ///     ldrb  wN, [xM, #existence]
    ///     tbz   wN, #0, done             ; or this patch's nop
    ///     adrp  x0, CFSTR page
    ///     add   x0, x0, #CFSTR           ; "AppleNeuralEngineSubtype"
    ///     mov   w1, #1
    ///     bl    MGGetSInt64Answer        ; directly or through a stub
    ///     cmp   x0, #0x1f
    ///     cset  wK, gt
    ///     adrp  xP, cache page
    ///     strb  wK, [xP, #modern]
    ///   done:
    static func findSite(
        in code: [ARM64Instruction],
        answer: UInt64,
        readStub: (UInt64) throws -> [ARM64Instruction],
    ) throws -> Site {
        var sites: [Site] = []
        if code.count >= 11 {
            for i in 0 ... code.count - 11 {
                guard code[i].mnemonic == "ldrb", let load = code[i].detail?.operands, load.count == 2,
                      load[0].type == .register, load[1].type == .memory,
                      let flag = (0 ..< 31).first(where: { load[0].reg == .w($0) })
                else { continue }
                let gate = code[i + 1]
                let patched = gate.mnemonic == "nop"
                if !patched {
                    guard gate.mnemonic == "tbz", let test = gate.detail?.operands, test.count == 3,
                          test[0].type == .register, test[0].reg == .w(flag),
                          test[1].type == .immediate, test[1].imm == 0,
                          test[2].type == .immediate, UInt64(bitPattern: test[2].imm) == code[i + 10].address
                    else { continue }
                }
                guard isMaterialized(code[i + 2], code[i + 3], into: 0),
                      isImmediateMove(code[i + 4], destination: .w(1), value: 1),
                      code[i + 5].mnemonic == "bl", let call = code[i + 5].detail?.operands,
                      call.count == 1, call[0].type == .immediate,
                      callsAnswer(UInt64(bitPattern: call[0].imm), answer: answer, readStub: readStub),
                      isCompare(code[i + 6], register: .x(0), value: modernSubtype),
                      code[i + 7].mnemonic == "cset", code[i + 7].detail?.conditionCode == .gt,
                      let set = code[i + 7].detail?.operands, set.count == 1, set[0].type == .register,
                      let result = (0 ..< 31).first(where: { set[0].reg == .w($0) }),
                      code[i + 8].mnemonic == "adrp", let page = code[i + 8].detail?.operands, page.count == 2,
                      page[0].type == .register,
                      code[i + 9].mnemonic == "strb", let store = code[i + 9].detail?.operands, store.count == 2,
                      store[0].type == .register, store[0].reg == .w(result),
                      store[1].type == .memory, store[1].mem.base == page[0].reg,
                      zip(code[i ..< i + 10], code[i + 1 ... i + 10]).allSatisfy({ $0.address + 4 == $1.address })
                else { continue }
                sites.append(Site(address: gate.address, alreadyPatched: patched))
            }
        }
        guard sites.count == 1, let site = sites.first else {
            throw PatcherError.patchSiteNotFound("\(blockSymbol): expected one Neural Engine existence gate, found \(sites.count)")
        }
        return site
    }

    static func callsAnswer(_ target: UInt64, answer: UInt64, readStub: (UInt64) throws -> [ARM64Instruction]) -> Bool {
        target == answer
            || (try? readStub(target)).flatMap(DyldSharedCacheHomeViewEnvironmentPatcher.stubDestination) == answer
    }

    static func isMaterialized(_ page: ARM64Instruction, _ add: ARM64Instruction, into register: Int) -> Bool {
        guard DyldSharedCacheHomeViewEnvironmentPatcher.materializedAddress(page, add) != nil,
              let operands = add.detail?.operands, operands[0].reg == .x(register)
        else { return false }
        return true
    }

    static func isImmediateMove(_ instruction: ARM64Instruction, destination: ARM64Register, value: Int64) -> Bool {
        guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[0].reg == destination,
              operands[1].type == .immediate, operands[1].imm == value
        else { return false }
        return true
    }

    static func isCompare(_ instruction: ARM64Instruction, register: ARM64Register, value: Int64) -> Bool {
        guard instruction.mnemonic == "cmp", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .immediate, operands[1].imm == value
        else { return false }
        return true
    }

    private static func hex(_ value: UInt64) -> String { String(value, radix: 16) }
}
