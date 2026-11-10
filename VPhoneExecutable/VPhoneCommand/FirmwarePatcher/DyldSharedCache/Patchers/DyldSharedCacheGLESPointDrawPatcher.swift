// The paravirtual Metal device reports no vertex usage flags even when the
// compiled AIR writes point_size. AppleMetalGLRenderer consequently skips
// GL_POINTS before issuing a Metal draw. GLES 2/3 point shaders must write
// gl_PointSize (otherwise its value is undefined); ES 1 supplies it itself.
// Remove only the four reflection-based suppressions, preserving the point
// mode, pipeline-null, raster and transform-feedback gates around them.
//
// Resolve the renderer's own symbols and recover its context fields from the
// actual setRenderPipelineState: argument/store dataflow. No firmware address
// or context layout is built in. The indexed IMP/selector fields are recovered
// from beginRenderPass's methodForSelector: call and the exact draw selector.
// Whole local-symbol spans matter: the direct
// callback has an early return before all three draw paths. All four sites
// must be original, or all four must already be NOP, before any write occurs.

import Foundation
import VPhonePatchKit

public struct DyldSharedCacheGLESPointDrawPatch: Sendable {
    public let functionVMA: UInt64
    public let siteVMAs: [UInt64]
    public let wasAlreadyPatched: Bool
    public let sitesWritten: Int
    public let reattestation: DyldSharedCacheReattestation?
}

public enum DyldSharedCacheGLESPointDrawPatcher {
    public static let imagePath = DyldSharedCacheGLESPrimitiveRestartPatcher.imagePath
    public static let symbolName = DyldSharedCacheGLESPrimitiveRestartPatcher.symbolName
    static let primitiveSymbol = "__ZL21gldEndPrimitiveBufferP13GLDContextRecjji"
    static let pipelineSymbol = "__ZN13GLDContextRec17setRenderPipelineEv"
    static let beginRenderPassSymbol = "__ZN13GLDContextRec15beginRenderPassEv"
    static let pipelineSelector = "_objc_msgSend$setRenderPipelineState:"
    static let methodForSelector = "_objc_msgSend$methodForSelector:"
    static let indexedDrawSelector = "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"
    static let drawSelectors = [
        "_objc_msgSend$drawPrimitives:vertexStart:vertexCount:",
        "_objc_msgSend$drawPrimitives:vertexStart:vertexCount:instanceCount:",
    ]
    static let label = "GLES point draw"

    struct Fields: Equatable {
        let pipeline: Int32
        let usage: Int32
        let encoder: Int32
    }

    struct IndexedDrawFields: Equatable {
        let selector: Int32
        let imp: Int32
    }

    struct Site {
        let address: UInt64
        let modeOffset: Int32
        let skip: UInt64
        let alreadyPatched: Bool
    }

    struct Plan {
        let sites: [Site]
        var alreadyPatched: Bool { sites.allSatisfy(\.alreadyPatched) }
    }

    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheGLESPointDrawPatch {
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
    ) throws -> DyldSharedCacheGLESPointDrawPatch {
        try resolver.requireLocalSymbols()
        let symbols = try resolver.symbols(inImage: imagePath)
        let required = [symbolName, primitiveSymbol, pipelineSymbol, beginRenderPassSymbol]
        let addresses = try resolver.addresses(of: required, inImage: imagePath)
        let decoder = ARM64Disassembler()
        func code(_ name: String) throws -> [ARM64Instruction] {
            let start = addresses[name]!
            let span = try functionSpan(at: start, symbolAddresses: symbols.values.map(\.address))
            guard chunks.mappings.contains(where: {
                $0.initProt & 4 != 0 && $0.address <= span.lowerBound && $0.address + $0.size >= span.upperBound
            }) else { throw PatcherError.invalidFormat("\(label) function is not wholly executable") }
            let instructions = decoder.disassemble(try chunks.bytesAtVMA(start, length: Int(span.count)), at: start)
            guard instructions.count * 4 == span.count,
                  instructions.enumerated().allSatisfy({ $0.element.isDecoded && $0.element.size == 4 && $0.element.address == start + UInt64($0.offset * 4) })
            else { throw PatcherError.patchSiteNotFound("\(label) function did not decode completely") }
            return instructions
        }
        let pipeline = try code(pipelineSymbol)
        let beginPass = try code(beginRenderPassSymbol)
        let direct = try code(symbolName)
        let primitive = try code(primitiveSymbol)
        let fields = try pipelineFields(in: pipeline, selector: resolver.objcMessageTarget(
            pipelineSelector, inImage: imagePath, calledBy: pipeline, chunks: chunks))
        let method = try resolver.objcMessageTarget(methodForSelector, inImage: imagePath, calledBy: beginPass, chunks: chunks)
        let indexedDraw = try indexedDrawFields(in: beginPass, fields: fields, methodForSelector: method) {
            try chunks.bytesAtVMA($0, length: $1)
        }
        let draws = try Set(drawSelectors.map {
            try resolver.objcMessageTarget($0, inImage: imagePath, calledBy: direct + primitive, chunks: chunks)
        })
        let plan = try plan(direct: direct, primitive: primitive, fields: fields,
                            indexedDraw: indexedDraw, drawTargets: draws)
        log?("  [.] \(label) pipeline/usage context fields +0x\(String(fields.pipeline, radix: 16))/+0x\(String(fields.usage, radix: 16))")
        log?("  [.] \(label) indexed selector/IMP context fields +0x\(String(indexedDraw.selector, radix: 16))/+0x\(String(indexedDraw.imp, radix: 16))")
        for site in plan.sites {
            log?("  [\(plan.alreadyPatched ? "=" : dryRun ? "~" : "+")] \(label) @ 0x\(String(site.address, radix: 16)): \(site.alreadyPatched ? "NOP (already patched)" : "TBZ usage bit 7 -> NOP"); retained skip gate -> 0x\(String(site.skip, radix: 16))")
        }
        var reattestation: DyldSharedCacheReattestation?
        if !dryRun, !plan.alreadyPatched {
            let spans = plan.sites.map { DyldSharedCacheWriteSpan(vma: $0.address, length: 4) }
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
            chunks.clearRecordedWrites()
            reattestation = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: label, log: log) {
                for site in plan.sites { try chunks.write(at: site.address, ARM64.nop) }
                let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
                guard result.isFullyAttested else { throw PatcherError.patchVerificationFailed("\(label) re-attestation skipped pages") }
                for site in plan.sites {
                    guard try chunks.bytesAtVMA(site.address, length: 4) == ARM64.nop else {
                        throw PatcherError.patchVerificationFailed("\(label) NOP did not read back")
                    }
                }
                return result
            }
        }
        return .init(functionVMA: addresses[symbolName]!, siteVMAs: plan.sites.map(\.address),
                     wasAlreadyPatched: plan.alreadyPatched, sitesWritten: dryRun || plan.alreadyPatched ? 0 : plan.sites.count,
                     reattestation: reattestation)
    }

    // MARK: - Symbol bounds and pipeline argument dataflow

    static func functionSpan(at start: UInt64, symbolAddresses: [UInt64]) throws -> Range<UInt64> {
        guard start % 4 == 0, let end = symbolAddresses.filter({ $0 > start }).min(),
              end % 4 == 0, end - start <= 65536
        else { throw PatcherError.patchSiteNotFound("\(label) has no safe next-symbol function bound") }
        return start ..< end
    }

    static func pipelineFields(in code: [ARM64Instruction], selector: UInt64) throws -> Fields {
        var candidates: [Fields] = []
        for i in code.indices where i >= 5 && i + 1 < code.count && branch(code[i], mnemonic: "bl") == selector {
            // x2 is the pipeline supplied to objc_msgSend. The adjacent wrapper
            // word is copied to the context and reloaded as usage flags after
            // the call. Both fields and the encoder derive from this sequence.
            guard let pipeline = memory(code[i - 5], mnemonic: "ldr"), pipeline.register == .x(2), pipeline.offset == 0,
                  let savedPipeline = memory(code[i - 4], mnemonic: "str"), savedPipeline.register == .x(2),
                  let usage = memory(code[i - 3], mnemonic: "ldr"), usage.base == pipeline.base, usage.offset == 8,
                  isX(usage.register),
                  let savedUsage = memory(code[i - 2], mnemonic: "str"), savedUsage.register == usage.register,
                  savedUsage.base == savedPipeline.base, savedUsage.offset == savedPipeline.offset + 8,
                  let encoder = memory(code[i - 1], mnemonic: "ldr"), encoder.register == .x(0), encoder.base == savedPipeline.base,
                  let reloadedUsage = memory(code[i + 1], mnemonic: "ldr"), reloadedUsage.base == savedPipeline.base,
                  reloadedUsage.offset == savedUsage.offset, isX(reloadedUsage.register),
                  savedPipeline.offset >= 0, encoder.offset >= 0,
                  contextRegister(in: Array(code.prefix(i))) == savedPipeline.base
            else { continue }
            candidates.append(.init(pipeline: savedPipeline.offset, usage: savedUsage.offset, encoder: encoder.offset))
        }
        guard candidates.count == 1, let fields = candidates.first else {
            throw PatcherError.patchSiteNotFound("\(label) expected one verified pipeline/usage store chain, found \(candidates.count)")
        }
        return fields
    }

    static func indexedDrawFields(
        in code: [ARM64Instruction], fields: Fields, methodForSelector: UInt64,
        readBytes: (UInt64, Int) throws -> Data,
    ) throws -> IndexedDrawFields {
        guard let context = contextRegister(in: code) else {
            throw PatcherError.patchSiteNotFound("\(label) render-pass setup has no saved context")
        }
        let literal = Data((indexedDrawSelector + "\0").utf8)
        var candidates: [IndexedDrawFields] = []
        for i in code.indices where i >= 4 && i + 1 < code.count && branch(code[i], mnemonic: "bl") == methodForSelector {
            // methodForSelector: receives the encoder in x0 and the named
            // selector in x2; save that selector and the returned IMP into
            // the same context. Adjacent slots alone cannot identify a draw.
            guard let encoder = memory(code[i - 4], mnemonic: "ldr"), encoder.register == .x(0),
                  encoder.base == context, encoder.offset == fields.encoder,
                  let selectorAddress = materializedAddress(code[i - 3], code[i - 2], destination: .x(2)),
                  let selector = memory(code[i - 1], mnemonic: "str"), selector.register == .x(2),
                  selector.base == context, selector.offset >= 0,
                  let imp = memory(code[i + 1], mnemonic: "str"), imp.register == .x(0),
                  imp.base == context, imp.offset == selector.offset + 8,
                  try readBytes(selectorAddress, literal.count) == literal
            else { continue }
            candidates.append(.init(selector: selector.offset, imp: imp.offset))
        }
        guard let fields = candidates.only else {
            throw PatcherError.patchSiteNotFound("\(label) expected one verified indexed draw selector/IMP store chain, found \(candidates.count)")
        }
        return fields
    }

    // MARK: - Four independently checked draw guards

    static func plan(direct: [ARM64Instruction], primitive: [ARM64Instruction], fields: Fields, indexedDraw: IndexedDrawFields, drawTargets: Set<UInt64>) throws -> Plan {
        let directSites = try sites(in: direct, fields: fields, indexedDraw: indexedDraw, drawTargets: drawTargets, primitive: false)
        let primitiveSites = try sites(in: primitive, fields: fields, indexedDraw: indexedDraw, drawTargets: drawTargets, primitive: true)
        guard directSites.count == 3, primitiveSites.count == 1 else {
            throw PatcherError.patchSiteNotFound("\(label) expected 3 direct and 1 primitive-buffer guards, found \(directSites.count) and \(primitiveSites.count)")
        }
        let sites = (directSites + primitiveSites).sorted { $0.address < $1.address }
        guard Set(sites.map(\.address)).count == 4, Set(sites.map(\.modeOffset)).count == 1 else {
            throw PatcherError.patchVerificationFailed("\(label) guards disagree on point-mode state")
        }
        let patchedCount = sites.filter(\.alreadyPatched).count
        guard patchedCount == 0 || patchedCount == sites.count else {
            throw PatcherError.patchVerificationFailed("\(label) refuses mixed original and patched guards")
        }
        return .init(sites: sites)
    }

    static func sites(in code: [ARM64Instruction], fields: Fields, indexedDraw: IndexedDrawFields, drawTargets: Set<UInt64>, primitive: Bool) throws -> [Site] {
        guard let context = contextRegister(in: code), let end = code.last.map({ $0.address + 4 }) else {
            throw PatcherError.patchSiteNotFound("\(label) draw callback has no saved context")
        }
        var result: [Site] = []
        for i in code.indices where i >= 4 && i + 1 < code.count {
            guard let mode = memory(code[i - 3], mnemonic: "ldrb"), mode.base == context, mode.offset >= 0,
                  bitBranch(code[i - 2], mnemonic: "tbz", register: mode.register, bit: 0) == code[i].address + 4,
                  let usage = memory(code[i - 1], mnemonic: "ldrb"), usage.base == context, usage.offset == fields.usage,
                  isW(mode.register), isW(usage.register)
            else { continue }
            let skip: UInt64?
            if primitive {
                skip = bitBranch(code[i - 4], mnemonic: "tbnz", register: nil, bit: 0)
                // This callback folds the pipeline-null and raster gates into
                // the saved boolean consumed by that retained TBNZ.
                guard code[..<(i - 4)].enumerated().contains(where: { j, instruction in
                    guard let load = memory(instruction, mnemonic: "ldr"), load.base == context,
                          load.offset == fields.pipeline, isX(load.register), j + 1 < i - 4
                    else { return false }
                    return compareBranch(code[j + 1], mnemonic: "cbz", register: load.register) != nil
                }) else { continue }
            } else {
                // One indexed path loads its buffer between CBZ and point
                // mode. Search only that small, straight-line prefix.
                skip = (max(0, i - 7) ..< i - 3).compactMap { j -> UInt64? in
                    guard let load = memory(code[j], mnemonic: "ldr"), load.base == context,
                          load.offset == fields.pipeline, isX(load.register), j + 1 < i - 3,
                          code[j + 2 ..< i - 3].allSatisfy({ !$0.isJump && !$0.isCall && !$0.isReturn })
                    else { return nil }
                    return compareBranch(code[j + 1], mnemonic: "cbz", register: load.register)
                }.only
            }
            guard let skip, skip > code[i].address + 4, skip < end,
                  let skipIndex = code.firstIndex(where: { $0.address == skip }),
                  containsDraw(Array(code[i + 1 ..< skipIndex]), context: context, fields: fields, indexedDraw: indexedDraw, drawTargets: drawTargets)
            else { continue }
            let patched = code[i].mnemonic == "nop" && Data(code[i].bytes) == ARM64.nop
            guard patched || bitBranch(code[i], mnemonic: "tbz", register: usage.register, bit: 7) == skip else { continue }
            result.append(.init(address: code[i].address, modeOffset: mode.offset, skip: skip, alreadyPatched: patched))
        }
        return result
    }

    static func containsDraw(_ code: [ARM64Instruction], context: ARM64Register, fields: Fields, indexedDraw: IndexedDrawFields, drawTargets: Set<UInt64>) -> Bool {
        // Follow in-function branches: the EBO path jumps over the arrays
        // block to its indexed IMP. Seeing an unrelated call in the skipped
        // address range is not proof that this guard controls a Metal draw.
        let indices = Dictionary(uniqueKeysWithValues: code.enumerated().map { ($0.element.address, $0.offset) })
        var pending = [(index: 0, encoderLoaded: false)]
        var visited = Set<Int>()
        while let state = pending.popLast() {
            let i = state.index
            guard code.indices.contains(i), visited.insert(i * 2 + (state.encoderLoaded ? 1 : 0)).inserted else { continue }
            let instruction = code[i]
            if state.encoderLoaded, let target = branch(instruction, mnemonic: "bl"), drawTargets.contains(target) { return true }
            // The indexed draw's authenticated IMP and selector must be the
            // exact fields populated by its verified methodForSelector: call.
            if state.encoderLoaded, i >= 3, instruction.mnemonic == "blraaz", let operand = instruction.detail?.operands.only,
               operand.type == .register,
               let imp = memory(code[i - 3], mnemonic: "ldr"), imp.register == operand.reg, imp.base == context,
               let selector = memory(code[i - 2], mnemonic: "ldr"), selector.register == .x(1), selector.base == context,
               imp.offset == indexedDraw.imp, selector.offset == indexedDraw.selector,
               move(code[i - 1], destination: .x(5)) != nil {
                return true
            }
            if instruction.isReturn { continue }
            var encoderLoaded = state.encoderLoaded
            if let load = memory(instruction, mnemonic: "ldr"), load.register == .x(0),
               load.base == context, load.offset == fields.encoder {
                encoderLoaded = true
            } else if instruction.isCall || instruction.detail?.operands.contains(where: {
                $0.type == .register && $0.writesRegister && ($0.reg == .x(0) || $0.reg == .w(0))
            }) == true {
                encoderLoaded = false
            }
            if instruction.isJump, !instruction.isCall {
                guard let target = instruction.detail?.operands.last, target.type == .immediate else { continue }
                if let index = indices[UInt64(bitPattern: target.imm)] { pending.append((index, encoderLoaded)) }
                if instruction.mnemonic == "b" { continue }
            }
            pending.append((i + 1, encoderLoaded))
        }
        return false
    }

    // MARK: - Typed operand helpers

    static func materializedAddress(_ page: ARM64Instruction, _ add: ARM64Instruction, destination: ARM64Register) -> UInt64? {
        guard page.address + 4 == add.address, page.mnemonic == "adrp", add.mnemonic == "add",
              let p = page.detail?.operands, p.count == 2,
              p[0].type == .register, isX(p[0].reg), p[1].type == .immediate, p[1].imm > 0,
              let a = add.detail?.operands, a.count == 3,
              a[0].type == .register, a[0].reg == destination,
              a[1].type == .register, a[1].reg == p[0].reg,
              a[2].type == .immediate, a[2].imm >= 0, a[2].imm < 4096, a[2].shift.amount == 0
        else { return nil }
        return UInt64(p[1].imm) + UInt64(a[2].imm)
    }

    struct Memory {
        let register: ARM64Register
        let base: ARM64Register
        let offset: Int32
    }

    static func memory(_ instruction: ARM64Instruction, mnemonic: String) -> Memory? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 2,
              operands[0].type == .register, operands[1].type == .memory,
              operands[1].mem.index == .invalid, instruction.detail?.writeback == false
        else { return nil }
        return .init(register: operands[0].reg, base: operands[1].mem.base, offset: operands[1].mem.disp)
    }

    static func move(_ instruction: ARM64Instruction, destination: ARM64Register) -> ARM64Register? {
        guard instruction.mnemonic == "mov", let detail = instruction.detail else { return nil }
        let operands = detail.operands
        guard operands.count == 2,
              operands[0].type == .register, operands[0].reg == destination, operands[1].type == .register
        else { return nil }
        return operands[1].reg
    }

    static func contextRegister(in code: [ARM64Instruction]) -> ARM64Register? {
        let candidates = (19 ... 28).filter { register in
            code.prefix(24).prefix(while: { !$0.isCall }).contains { move($0, destination: .x(register)) == .x(0) }
        }
        return candidates.only.map { .x($0) }
    }

    static func isX(_ register: ARM64Register) -> Bool { (0 ... 30).contains { register == .x($0) } }
    static func isW(_ register: ARM64Register) -> Bool { (0 ... 30).contains { register == .w($0) } }

    static func branch(_ instruction: ARM64Instruction, mnemonic: String) -> UInt64? {
        guard instruction.mnemonic == mnemonic, let operand = instruction.detail?.operands.only,
              operand.type == .immediate, operand.imm > 0 else { return nil }
        return UInt64(operand.imm)
    }

    static func compareBranch(_ instruction: ARM64Instruction, mnemonic: String, register: ARM64Register) -> UInt64? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 2,
              operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .immediate, operands[1].imm > 0 else { return nil }
        return UInt64(operands[1].imm)
    }

    static func bitBranch(_ instruction: ARM64Instruction, mnemonic: String, register: ARM64Register?, bit: Int64) -> UInt64? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 3,
              operands[0].type == .register, register == nil || operands[0].reg == register,
              operands[1].type == .immediate, operands[1].imm == bit,
              operands[2].type == .immediate, operands[2].imm > 0 else { return nil }
        return UInt64(operands[2].imm)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
