// Keep the paravirtual command-91 suppression, but restore GLES's disabled
// primitive-restart semantics for indexed strips. Returning zero from the
// renderer's fast-draw callback asks GLEngine to pack the original indexed
// vertices and use its nonindexed primitive-buffer path. Enabled restart and
// all other draws keep the original renderer path. GLEngine packs original
// vertex/instance IDs, including for its instanced and range-draw entry points.
//
// No runtime context offsets are built into the patch. Resolve both routines
// from the image's symbols, recover the state fields from the actual restart
// updater, and install a checked entry trampoline in unused executable header
// padding. The ABI's flags 1/3 mean elements/range-elements; arrays use zero.
// This patch requires the existing paravirtual primitive-restart suppression:
// even the primitive-buffer path still applies the renderer's Metal state.

import Foundation
import VPhonePatchKit

public struct DyldSharedCacheGLESPrimitiveRestartPatch: Sendable {
    public let functionVMA: UInt64
    public let siteVMA: UInt64
    public let caveVMA: UInt64
    public let wasAlreadyPatched: Bool
    public let sitesWritten: Int
    public let reattestation: DyldSharedCacheReattestation?
}

public enum DyldSharedCacheGLESPrimitiveRestartPatcher {
    public static let imagePath = "/System/Library/Extensions/AppleMetalGLRenderer.bundle/AppleMetalGLRenderer"
    public static let symbolName = "__ZL20gldRenderVertexArrayP13GLDContextRecjjiijPKviS2_"
    static let stateSymbol = "__ZN13GLDContextRec28updateRenderPrimitiveRestartEv"
    static let label = "GLES primitive restart"
    static let caveSize = 68

    struct StateFields: Equatable {
        let pointerOffset: UInt32
        let enabledOffset: UInt16
    }

    struct Site {
        let address: UInt64
        let existingCave: UInt64?
    }

    struct Plan {
        let cave: UInt64
        let branch: Data
        let program: Data
        let alreadyPatched: Bool
    }

    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheGLESPrimitiveRestartPatch {
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
    ) throws -> DyldSharedCacheGLESPrimitiveRestartPatch {
        let function = try resolver.address(of: symbolName, inImage: imagePath)
        let updater = try resolver.address(of: stateSymbol, inImage: imagePath)
        let decoder = ARM64Disassembler()
        let entry = decoder.disassemble(try chunks.bytesAtVMA(function, length: 128), at: function)
        let site = try findEntry(in: entry)
        let state = try stateFields(in: DyldSharedCacheIOMFBSwapEndPatcher.disassembleFunction(
            in: chunks, at: updater, maximumInstructions: 32, disassembler: decoder,
        ))
        let headerAddress = try resolver.headerAddress(ofImage: imagePath)
        let prefix = try chunks.bytesAtVMA(headerAddress, length: 32)
        let commandsSize = Int(prefix.loadLE(UInt32.self, at: 20))
        guard commandsSize <= 1 << 20 else { throw PatcherError.invalidFormat("\(label) image load commands are too large") }
        let header = try chunks.bytesAtVMA(headerAddress, length: 32 + commandsSize)
        let padding = try DyldSharedCachePatchTransaction.headerPadding(
            in: header, at: headerAddress, minimumSize: caveSize, label: label,
        )
        guard chunks.mappings.contains(where: {
            $0.initProt & 4 != 0 && $0.address <= padding.lowerBound && $0.address + $0.size >= padding.upperBound
        }) else { throw PatcherError.invalidFormat("\(label) header padding is not executable") }
        let plan = try plan(site: site, fields: state, padding: padding) { try chunks.bytesAtVMA($0, length: $1) }
        log?("  [.] \(label) callback @ 0x\(String(function, radix: 16)); trampoline @ 0x\(String(plan.cave, radix: 16))")
        log?("  [\(plan.alreadyPatched ? "=" : dryRun ? "~" : "+")] disabled indexed strips use GLEngine primitive buffers\(plan.alreadyPatched ? " (already patched)" : "")")
        var reattestation: DyldSharedCacheReattestation?
        if !dryRun, !plan.alreadyPatched {
            let spans = [
                DyldSharedCacheWriteSpan(vma: plan.cave, length: plan.program.count),
                DyldSharedCacheWriteSpan(vma: site.address, length: plan.branch.count),
            ]
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
            chunks.clearRecordedWrites()
            reattestation = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: label, log: log) {
                try chunks.write(at: plan.cave, plan.program)
                try chunks.write(at: site.address, plan.branch)
                let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
                guard result.isFullyAttested else { throw PatcherError.patchVerificationFailed("\(label) re-attestation skipped pages") }
                guard try chunks.bytesAtVMA(plan.cave, length: caveSize) == plan.program,
                      try chunks.bytesAtVMA(site.address, length: 4) == plan.branch
                else { throw PatcherError.patchVerificationFailed("\(label) bytes did not read back") }
                return result
            }
        }
        return .init(functionVMA: function, siteVMA: site.address, caveVMA: plan.cave,
                     wasAlreadyPatched: plan.alreadyPatched, sitesWritten: dryRun || plan.alreadyPatched ? 0 : 2,
                     reattestation: reattestation)
    }

    // MARK: - Source-derived ABI and state fields

    static func findEntry(in code: [ARM64Instruction]) throws -> Site {
        guard code.count >= 24, let first = code.first,
              first.mnemonic == "pacibsp" || target(first) != nil,
              code[1].mnemonic == "sub", let stack = code[1].detail?.operands,
              stack.count == 3, stack[0].reg == .sp, stack[1].reg == .sp,
              stack[2].type == .immediate, stack[2].imm > 0,
              code[2 ..< 8].allSatisfy({ $0.mnemonic == "stp" }),
              code[12 ..< 24].contains(where: { move($0, source: .x(2)) }),
              code[12 ..< 24].contains(where: { move($0, source: .x(5)) }),
              code[12 ..< 24].contains(where: { move($0, source: .x(7)) })
        else { throw PatcherError.patchSiteNotFound("\(label) fast-draw entry has an unfamiliar ABI/prologue") }
        return Site(address: first.address, existingCave: target(first))
    }

    static func move(_ instruction: ARM64Instruction, source: ARM64Register) -> Bool {
        guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[1].type == .register
        else { return false }
        return operands[1].reg == source
    }

    static func target(_ instruction: ARM64Instruction) -> UInt64? {
        guard instruction.mnemonic == "b", let operand = instruction.detail?.operands.first,
              operand.type == .immediate, operand.imm > 0 else { return nil }
        return UInt64(operand.imm)
    }

    static func stateFields(in code: [ARM64Instruction]) throws -> StateFields {
        guard code.count >= 7, code[0].mnemonic == "ldr", code[1].mnemonic == "mov",
              let load = code[0].detail?.operands, load.count == 2,
              load[0].type == .register, load[1].type == .memory,
              load[1].mem.base == .x(0), load[1].mem.index == .invalid,
              load[1].mem.disp >= 0, load[1].mem.disp % 8 == 0,
              code[0].detail?.writeback == false,
              let pointer = (1 ... 17).first(where: { load[0].reg == .x($0) }),
              let offset = code[1].detail?.operands, offset.count == 2,
              let index = (1 ... 17).first(where: { offset[0].reg == .w($0) }),
              pointer != index, offset[1].type == .immediate,
              let byteOffset = UInt16(exactly: offset[1].imm)
        else { throw PatcherError.patchSiteNotFound("\(label) updater does not expose a verified state pointer") }

        // Both compiler forms compute the same byte address: an indexed
        // LDRB/STRB or ADD followed by a zero-offset byte access. Derive and
        // verify each register; the context and state offsets remain inputs.
        func adds(_ instruction: ARM64Instruction, destination: Int, base: ARM64Register, index: Int) -> Bool {
            guard instruction.mnemonic == "add", let operands = instruction.detail?.operands,
                  operands.count == 3, operands.allSatisfy({ $0.type == .register }),
                  operands[0].reg == .x(destination), operands[1].reg == base,
                  operands[2].reg == .x(index), operands[2].shift.amount == 0
            else { return false }
            return true
        }
        let expandedLoad = adds(code[2], destination: pointer, base: .x(pointer), index: index)
        let byteIndex = expandedLoad ? 3 : 2
        let compareIndex = byteIndex + 1
        let setIndex = byteIndex + 2
        let offsetIndex = byteIndex + 3
        guard offsetIndex + 1 < code.count,
              code[byteIndex].mnemonic == "ldrb",
              let byte = code[byteIndex].detail?.operands, byte.count == 2,
              byte[0].reg == .w(pointer), byte[1].type == .memory,
              byte[1].mem.base == .x(pointer), byte[1].mem.index == (expandedLoad ? .invalid : .x(index)),
              byte[1].mem.disp == 0, byte[1].shift.amount == 0,
              code[byteIndex].detail?.writeback == false,
              code[compareIndex].mnemonic == "cmp",
              let compare = code[compareIndex].detail?.operands, compare.count == 2,
              compare[0].reg == .w(pointer), compare[1].type == .immediate, compare[1].imm == 0,
              code[setIndex].mnemonic == "cset", code[setIndex].detail?.conditionCode == .ne,
              code[setIndex].detail?.operands.first?.reg == .w(pointer),
              code[offsetIndex].mnemonic == "mov", let output = code[offsetIndex].detail?.operands,
              output.count == 2, output[0].type == .register,
              let outputIndex = (1 ... 17).first(where: { output[0].reg == .w($0) }),
              outputIndex != pointer, output[1].type == .immediate, UInt16(exactly: output[1].imm) != nil
        else { throw PatcherError.patchSiteNotFound("\(label) updater does not expose a verified current-state byte") }
        let expandedStore = adds(code[offsetIndex + 1], destination: outputIndex, base: .x(0), index: outputIndex)
        let storeIndex = offsetIndex + (expandedStore ? 2 : 1)
        guard storeIndex < code.count, code[storeIndex].mnemonic == "strb",
              let store = code[storeIndex].detail?.operands, store.count == 2,
              store[0].reg == .w(pointer), store[1].type == .memory,
              store[1].mem.base == (expandedStore ? .x(outputIndex) : .x(0)),
              store[1].mem.index == (expandedStore ? .invalid : .x(outputIndex)),
              store[1].mem.disp == 0, store[1].shift.amount == 0,
              code[storeIndex].detail?.writeback == false
        else { throw PatcherError.patchSiteNotFound("\(label) updater does not store the normalized state byte") }
        return StateFields(pointerOffset: UInt32(load[1].mem.disp), enabledOffset: byteOffset)
    }

    // MARK: - Checked header trampoline

    static func plan(site: Site, fields: StateFields, padding: Range<UInt64>, read: (UInt64, Int) throws -> Data) throws -> Plan {
        guard padding.count >= caveSize else { throw PatcherError.patchSiteNotFound("\(label) padding is too small") }
        let cave: UInt64
        if let existing = site.existingCave {
            guard existing % 4 == 0, padding.contains(existing), existing <= padding.upperBound - UInt64(caveSize)
            else { throw PatcherError.patchVerificationFailed("\(label) entry branch leaves header padding") }
            cave = existing
        } else {
            let bytes = try read(padding.lowerBound, Int(padding.count))
            guard let offset = stride(from: 0, through: bytes.count - caveSize, by: 4).first(where: {
                bytes[$0 ..< $0 + caveSize].allSatisfy { $0 == 0 }
            }) else { throw PatcherError.patchSiteNotFound("\(label) header padding is occupied") }
            cave = padding.lowerBound + UInt64(offset)
        }
        let program = try trampoline(at: cave, returningTo: site.address + 4, fields: fields)
        guard let branch = ARM64Encoder.encodeB(from: Int(site.address), to: Int(cave)) else {
            throw PatcherError.patchVerificationFailed("\(label) trampoline is out of branch range")
        }
        if site.existingCave != nil, try read(cave, caveSize) != program {
            throw PatcherError.patchVerificationFailed("\(label) trampoline differs from this patch's complete output")
        }
        return Plan(cave: cave, branch: branch, program: program, alreadyPatched: site.existingCave != nil)
    }

    static func trampoline(at cave: UInt64, returningTo resume: UInt64, fields: StateFields) throws -> Data {
        guard let base = Int(exactly: cave), let end = Int(exactly: resume),
              let elements = ARM64Encoder.encodeCmpWImmediate(rn: 1, imm12: 1),
              let isElements = ARM64Encoder.encodeBCond(from: base + 8, to: base + 20, condition: .eq),
              let rangeElements = ARM64Encoder.encodeCmpWImmediate(rn: 1, imm12: 3),
              let notElements = ARM64Encoder.encodeBCond(from: base + 16, to: base + 64, condition: .ne),
              let line = ARM64Encoder.encodeCmpWImmediate(rn: 2, imm12: 3),
              let isLine = ARM64Encoder.encodeBCond(from: base + 24, to: base + 36, condition: .eq),
              let triangle = ARM64Encoder.encodeCmpWImmediate(rn: 2, imm12: 5),
              let notStrip = ARM64Encoder.encodeBCond(from: base + 32, to: base + 64, condition: .ne),
              let state = ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 0, offset: fields.pointerOffset),
              let byteOffset = ARM64Encoder.encodeMovzX(rd: 9, imm16: fields.enabledOffset),
              let byteAddress = ARM64Encoder.encodeAddSubXShifted(subtract: false, rd: 8, rn: 8, rm: 9),
              let enabled = ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 8, offset: 0),
              let restartOn = ARM64Encoder.encodeCompareBranch(nonzero: true, register: 8, from: base + 52, to: base + 64, width64: false),
              let original = ARM64Encoder.encodeB(from: base + 64, to: end)
        else { throw PatcherError.patchVerificationFailed("Cannot encode \(label) trampoline") }
        // Only caller-saved x8/x9 and NZCV change. Arguments x0...x7, stack and
        // LR survive the forwarding path. PACIBSP is the displaced first
        // instruction; the early return therefore uses matching RETAB.
        let instructions = [ARM64.pacibsp, elements, isElements, rangeElements, notElements,
                            line, isLine, triangle, notStrip, state, byteOffset, byteAddress,
                            enabled, restartOn, ARM64.movW0_0, ARM64.retab, original]
        return instructions.reduce(into: Data()) { $0 += $1 }
    }
}
