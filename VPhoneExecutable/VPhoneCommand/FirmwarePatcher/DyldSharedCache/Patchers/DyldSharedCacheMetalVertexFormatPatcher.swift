// AppleMetalGLRenderer uses private vertex formats 43 and 44 for the supplied
// vertex/instance IDs in its primitive buffer. The guest compiler consumes
// those formats while adding software vertex fetches to AIR. Sending the same
// formats in the pipeline descriptor to macOS then aborts MTLCompilerService
// in Air::CloneAttributeDescriptor: its supported-format mask excludes both.
//
// Normalize only the serialized attribute's format, after the guest has made
// its shader variants. PipelineLibrarySerializer::serializeVertexDescriptor is
// the wire writer reached by -[_MTLDevice serializeRenderPipelineDescriptor:].
// Neither the original MTLVertexDescriptor nor the generated AIR is changed.
// UInt (36) describes the existing four-byte ID buffer to the host compiler.
//
// The site is the format getter's result saved for wire property 1. Both the
// containing function and the getter stub are resolved from this image's own
// symbols; operand/control-flow checks distinguish the actual value from the
// getter used for the default value. A 32-byte trampoline uses only existing
// ARM64Encoder helpers, with no absolute addresses or runtime hooks. Its space
// must be unused header padding before the first __TEXT section. An unfamiliar
// shape, occupied padding, or altered prior trampoline fails before any write.

import Foundation
import VPhonePatchKit

public struct DyldSharedCacheMetalVertexFormatPatch: Sendable {
    public let functionVMA: UInt64
    public let siteVMA: UInt64
    public let caveVMA: UInt64
    public let wasAlreadyPatched: Bool
    public let sitesWritten: Int
    public let reattestation: DyldSharedCacheReattestation?
}

public enum DyldSharedCacheMetalVertexFormatPatcher {
    public static let imagePath = "/System/Library/Frameworks/Metal.framework/Metal"
    public static let symbolName =
        "__ZN28MTLPipelineLibrarySerializer25PipelineLibrarySerializer25serializeVertexDescriptorEP19MTLVertexDescriptor"
    static let formatSymbol = "_objc_msgSend$format"
    static let caveSize = 32

    struct Site {
        let address: UInt64
        let valueRegister: UInt32
        let existingCave: UInt64?
    }

    struct Plan {
        let site: Site
        let cave: UInt64
        let branch: Data
        let program: Data
        var alreadyPatched: Bool { site.existingCave != nil }
    }

    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> DyldSharedCacheMetalVertexFormatPatch {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, captureUndo: captureUndo)
        do {
            let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
            let result = try patch(chunks: chunks, resolver: resolver, dryRun: dryRun, log: log)
            if captureUndo, let undo = chunks.takeUndoLog() { onUndo?(undo) }
            return result
        } catch {
            // A successful rollback needs no persistent undo entry. A failed
            // rollback needs the pre-write snapshot, including a partial write
            // that FileHandle may have thrown before ChunkSet recorded it.
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
    ) throws -> DyldSharedCacheMetalVertexFormatPatch {
        let function = try resolver.address(of: symbolName, inImage: imagePath)
        let format = try resolver.address(of: formatSymbol, inImage: imagePath)
        let headerAddress = try resolver.headerAddress(ofImage: imagePath)
        let prefix = try chunks.bytesAtVMA(headerAddress, length: 32)
        let commandsSize = Int(prefix.loadLE(UInt32.self, at: 20))
        guard commandsSize <= 1 << 20 else {
            throw PatcherError.invalidFormat("Metal Mach-O load commands are too large")
        }
        let header = try chunks.bytesAtVMA(headerAddress, length: 32 + commandsSize)
        let padding = try headerPadding(in: header, at: headerAddress)
        guard chunks.mappings.contains(where: {
            $0.initProt & 4 != 0 && $0.address <= padding.lowerBound
                && $0.address + $0.size >= padding.upperBound
        }) else { throw PatcherError.invalidFormat("Metal header padding is not executable") }
        let instructions = try DyldSharedCacheIOMFBSwapEndPatcher.disassembleFunction(
            in: chunks, at: function, maximumInstructions: 1024, disassembler: ARM64Disassembler(),
        )
        let site = try findFormatSite(in: instructions, formatStub: format)
        let plan = try plan(site: site, padding: padding) {
            try chunks.bytesAtVMA($0, length: $1)
        }

        log?("  [.] Metal vertex descriptor format @ 0x\(hex(site.address)); trampoline @ 0x\(hex(plan.cave))")
        log?("  [\(plan.alreadyPatched ? "=" : dryRun ? "~" : "+")] serialized builtin vertex formats 43/44 -> UInt (36)\(plan.alreadyPatched ? " already patched" : "")")
        var reattestation: DyldSharedCacheReattestation?
        if !dryRun, !plan.alreadyPatched {
            let spans = [
                DyldSharedCacheWriteSpan(vma: plan.cave, length: plan.program.count),
                DyldSharedCacheWriteSpan(vma: site.address, length: plan.branch.count),
            ]
            // Save code AND hash slots before any mutation. Re-attestation can
            // itself partially write before throwing; recomputing hashes on
            // rollback would not guarantee the exact original file bytes.
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
            chunks.clearRecordedWrites()
            reattestation = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: "Metal vertex format patch", log: log) {
                // Install the complete destination before exposing its branch.
                try chunks.write(at: plan.cave, plan.program)
                try chunks.write(at: site.address, plan.branch)
                let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
                guard result.isFullyAttested else {
                    throw PatcherError.patchVerificationFailed("Metal vertex format re-attestation skipped \(result.skipped.count) page(s)")
                }
                guard try chunks.bytesAtVMA(plan.cave, length: caveSize) == plan.program,
                      try chunks.bytesAtVMA(site.address, length: 4) == plan.branch
                else { throw PatcherError.patchVerificationFailed("Metal vertex format patch did not read back") }
                return result
            }
        }
        return DyldSharedCacheMetalVertexFormatPatch(
            functionVMA: function, siteVMA: site.address, caveVMA: plan.cave,
            wasAlreadyPatched: plan.alreadyPatched,
            sitesWritten: dryRun || plan.alreadyPatched ? 0 : 2,
            reattestation: reattestation,
        )
    }

    // MARK: - Semantic site discovery

    static func findFormatSite(in code: [ARM64Instruction], formatStub: UInt64) throws -> Site {
        var candidates: [Site] = []
        guard code.count >= 14 else {
            throw PatcherError.patchSiteNotFound("Metal vertex descriptor serializer is truncated")
        }
        for i in 2 ..< code.count - 11 {
            guard branchTarget(code[i - 1], mnemonic: "bl") == formatStub,
                  move(code[i - 2], destination: .x(0)) != nil,
                  move(code[i + 1], destination: .x(0)) != nil,
                  branchTarget(code[i + 2], mnemonic: "bl") == formatStub,
                  move(code[i + 3], destination: .x(3)) == .x(0),
                  isImmediateMove(code[i + 8], destination: .w(1), value: 1),
                  let valueRegister = move(code[i + 9], destination: .x(2)),
                  let number = (19 ... 28).first(where: { valueRegister == .x($0) }),
                  ["blraa", "blrab", "blr"].contains(code[i + 11].mnemonic)
            else { continue }
            let existingCave = branchTarget(code[i], mnemonic: "b")
            guard existingCave != nil || move(code[i], destination: valueRegister) == .x(0) else { continue }
            candidates.append(Site(address: code[i].address, valueRegister: UInt32(number), existingCave: existingCave))
        }
        guard candidates.count == 1, let site = candidates.first else {
            throw PatcherError.patchSiteNotFound("Metal serialized vertex format: expected one property-1 getter result, found \(candidates.count)")
        }
        return site
    }

    static func move(_ instruction: ARM64Instruction, destination: ARM64Register) -> ARM64Register? {
        guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[0].reg == destination,
              operands[1].type == .register
        else { return nil }
        return operands[1].reg
    }

    static func isImmediateMove(_ instruction: ARM64Instruction, destination: ARM64Register, value: Int64) -> Bool {
        guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[0].reg == destination,
              operands[1].type == .immediate, operands[1].imm == value
        else { return false }
        return true
    }

    static func branchTarget(_ instruction: ARM64Instruction, mnemonic: String) -> UInt64? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands,
              operands.count == 1, operands[0].type == .immediate
        else { return nil }
        return UInt64(bitPattern: operands[0].imm)
    }

    // MARK: - Unused executable space

    static func headerPadding(in header: Data, at address: UInt64) throws -> Range<UInt64> {
        try DyldSharedCachePatchTransaction.headerPadding(in: header, at: address, minimumSize: caveSize, label: "Metal")
    }

    static func plan(
        site: Site,
        padding: Range<UInt64>,
        read: (UInt64, Int) throws -> Data,
    ) throws -> Plan {
        guard padding.count >= caveSize else {
            throw PatcherError.patchSiteNotFound("Metal header padding is too small")
        }
        let cave: UInt64
        if let existing = site.existingCave {
            guard existing % 4 == 0, padding.contains(existing),
                  existing <= padding.upperBound - UInt64(caveSize)
            else { throw PatcherError.patchVerificationFailed("Metal format branch leaves its header padding") }
            cave = existing
        } else {
            let bytes = try read(padding.lowerBound, Int(padding.count))
            guard let offset = stride(from: 0, through: bytes.count - caveSize, by: 4).first(where: {
                bytes[$0 ..< $0 + caveSize].allSatisfy { $0 == 0 }
            }) else { throw PatcherError.patchSiteNotFound("Metal header padding is occupied") }
            cave = padding.lowerBound + UInt64(offset)
        }
        let program = try trampoline(at: cave, returningTo: site.address + 4, valueRegister: site.valueRegister)
        guard let branch = ARM64Encoder.encodeB(from: Int(site.address), to: Int(cave)) else {
            throw PatcherError.patchVerificationFailed("Metal format trampoline is out of branch range")
        }
        if site.existingCave != nil, try read(cave, caveSize) != program {
            throw PatcherError.patchVerificationFailed("Metal format trampoline differs from this patch's output")
        }
        return Plan(site: site, cave: cave, branch: branch, program: program)
    }

    // MARK: - Code generation

    static func trampoline(at cave: UInt64, returningTo resume: UInt64, valueRegister: UInt32) throws -> Data {
        guard (19 ... 28).contains(valueRegister), let base = Int(exactly: cave), let end = Int(exactly: resume),
              let subtract43 = ARM64Encoder.encodeSubImm12(rd: 9, rn: 0, imm12: 43),
              let equal43 = ARM64Encoder.encodeCompareBranch(nonzero: false, register: 9, from: base + 4, to: base + 16, width64: true),
              let subtract1 = ARM64Encoder.encodeSubImm12(rd: 9, rn: 9, imm12: 1),
              let unequal44 = ARM64Encoder.encodeCompareBranch(nonzero: true, register: 9, from: base + 12, to: base + 24, width64: true),
              let uintFormat = ARM64Encoder.encodeMovzX(rd: valueRegister, imm16: 36),
              let normalizedReturn = ARM64Encoder.encodeB(from: base + 20, to: end),
              let originalReturn = ARM64Encoder.encodeB(from: base + 28, to: end)
        else { throw PatcherError.patchVerificationFailed("Cannot encode Metal vertex format trampoline") }
        // x9 is caller-saved and dead immediately after the ObjC getter. x0,
        // LR, stack and NZCV survive unchanged. Full-width comparisons leave
        // every value except exactly 43 and 44 untouched, including high bits.
        return subtract43 + equal43 + subtract1 + unequal44 + uintFormat + normalizedReturn
            + ARM64Encoder.encodeMovX(rd: valueRegister, rm: 0) + originalReturn
    }

    private static func hex(_ value: UInt64) -> String { String(value, radix: 16) }
}
