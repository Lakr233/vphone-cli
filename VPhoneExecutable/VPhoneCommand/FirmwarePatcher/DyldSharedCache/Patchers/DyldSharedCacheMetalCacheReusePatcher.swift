// FS_CACHE_REUSE_ON_REBOOT=1 currently bypasses both the boot identity and the
// 32-byte client key in libCoreFSCache. A changed Metal compiler identity must
// still reject an old GLES shader cache. Route only that environment branch
// through the existing key check, setting the existing third-party flag so
// its successful comparison continues to bypass the boot identity alone.
//
// Resolve verify_list_file and is_third_party from this image's own symbols.
// Derive the environment branch, key buffers and flag register from decoded
// operands; prove that the flag is otherwise dead until its ABI restoration.
// The two-instruction trampoline occupies verified unused executable header
// padding. Partial or altered prior patches fail before any cache write.

import Foundation
import VPhonePatchKit

public struct DyldSharedCacheMetalCacheReusePatch: Sendable {
    public let functionVMA: UInt64
    public let siteVMA: UInt64
    public let caveVMA: UInt64
    public let wasAlreadyPatched: Bool
    public let sitesWritten: Int
    public let reattestation: DyldSharedCacheReattestation?
}

public enum DyldSharedCacheMetalCacheReusePatcher {
    public static let imagePath = "/System/Library/Frameworks/OpenGLES.framework/libCoreFSCache.dylib"
    public static let symbolName = "_verify_list_file"
    static let thirdPartySymbol = "_is_third_party"
    static let environment = Data("FS_CACHE_REUSE_ON_REBOOT\0".utf8)
    static let label = "Metal cache reuse key"
    static let caveSize = 8

    struct Site {
        let address: UInt64
        let resume: UInt64
        let flagRegister: UInt32
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
    ) throws -> DyldSharedCacheMetalCacheReusePatch {
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
    ) throws -> DyldSharedCacheMetalCacheReusePatch {
        try resolver.requireLocalSymbols()
        let symbols = try resolver.symbols(inImage: imagePath)
        let addresses = try resolver.addresses(of: [symbolName, thirdPartySymbol], inImage: imagePath)
        let function = addresses[symbolName]!
        let span = try DyldSharedCacheGLESPointDrawPatcher.functionSpan(at: function, symbolAddresses: symbols.values.map(\.address))
        let headerAddress = try resolver.headerAddress(ofImage: imagePath)
        let prefix = try chunks.bytesAtVMA(headerAddress, length: 32)
        let commandsSize = Int(prefix.loadLE(UInt32.self, at: 20))
        guard commandsSize <= 1 << 20 else { throw PatcherError.invalidFormat("\(label) load commands are too large") }
        let header = try chunks.bytesAtVMA(headerAddress, length: 32 + commandsSize)
        let padding = try DyldSharedCachePatchTransaction.headerPadding(in: header, at: headerAddress, minimumSize: caveSize, label: label)
        for range in [span, padding] {
            guard chunks.mappings.contains(where: {
                $0.initProt & 4 != 0 && $0.address <= range.lowerBound && $0.address + $0.size >= range.upperBound
            }) else { throw PatcherError.invalidFormat("\(label) function or padding is not wholly executable") }
        }
        let code = ARM64Disassembler().disassemble(try chunks.bytesAtVMA(function, length: Int(span.count)), at: function)
        guard code.count * 4 == span.count else { throw PatcherError.patchSiteNotFound("\(label) function did not decode completely") }
        let stackFailure = try resolver.address(of: "___stack_chk_fail", inImage: "/usr/lib/system/libsystem_c.dylib")
        let site = try findSite(in: code, thirdParty: addresses[thirdPartySymbol]!, stackFailure: stackFailure) { try chunks.bytesAtVMA($0, length: $1) }
        let plan = try plan(site: site, padding: padding) { try chunks.bytesAtVMA($0, length: $1) }
        log?("  [\(plan.alreadyPatched ? "=" : dryRun ? "~" : "+")] \(label) @ 0x\(String(site.address, radix: 16)) -> trampoline 0x\(String(plan.cave, radix: 16)); preserve 32-byte key validation on reboot reuse\(plan.alreadyPatched ? " (already patched)" : "")")
        var reattestation: DyldSharedCacheReattestation?
        if !dryRun, !plan.alreadyPatched {
            let spans = [DyldSharedCacheWriteSpan(vma: plan.cave, length: caveSize), DyldSharedCacheWriteSpan(vma: site.address, length: 4)]
            let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
            chunks.clearRecordedWrites()
            reattestation = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: label, log: log) {
                try chunks.write(at: plan.cave, plan.program)
                try chunks.write(at: site.address, plan.branch)
                let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
                guard result.isFullyAttested else { throw PatcherError.patchVerificationFailed("\(label) re-attestation skipped pages") }
                guard try chunks.bytesAtVMA(plan.cave, length: caveSize) == plan.program,
                      try chunks.bytesAtVMA(site.address, length: 4) == plan.branch
                else { throw PatcherError.patchVerificationFailed("\(label) did not read back") }
                return result
            }
        }
        return .init(functionVMA: function, siteVMA: site.address, caveVMA: plan.cave,
                     wasAlreadyPatched: plan.alreadyPatched, sitesWritten: dryRun || plan.alreadyPatched ? 0 : 2,
                     reattestation: reattestation)
    }

    // MARK: - Environment branch and both identity checks

    static func findSite(in code: [ARM64Instruction], thirdParty: UInt64, stackFailure: UInt64, read: (UInt64, Int) throws -> Data) throws -> Site {
        guard let start = code.first?.address, code.count >= 30,
              code.enumerated().allSatisfy({ $0.element.isDecoded && $0.element.size == 4 && $0.element.address == start + UInt64($0.offset * 4) })
        else { throw PatcherError.patchSiteNotFound("\(label) function did not decode completely") }
        guard let last = code.last, let failureTarget = branch(last, "bl"),
              try isStackFailure(failureTarget, resolved: stackFailure, read: read)
        else { throw PatcherError.patchVerificationFailed("\(label) terminal call is not the resolved stack-check failure") }
        var candidates: [Site] = []
        for i in code.indices where i >= 8 && i + 9 < code.count {
            // getenv(string), missing-value CBZ, load first character, call
            // is_third_party, compare with '1', B.NE normal, B reuse. The
            // missing-value path calls the same helper then shares normal's
            // saved result. Leave all of those instructions intact.
            guard let literal = DyldSharedCacheGLESPointDrawPatcher.materializedAddress(code[i - 8], code[i - 7], destination: .x(0)),
                  branch(code[i - 6], "bl") != nil,
                  compareBranch(code[i - 5], "cbz", .x(0)) == code[i + 1].address,
                  let character = memory(code[i - 4], "ldrb"), character.base == .x(0), character.offset == 0,
                  (19 ... 28).contains(where: { character.register == .w($0) }),
                  branch(code[i - 3], "bl") == thirdParty,
                  compareImmediate(code[i - 2], register: character.register, value: 49),
                  branch(code[i - 1], "b.ne") == code[i + 2].address,
                  let destination = branch(code[i], "b"),
                  branch(code[i + 1], "bl") == thirdParty,
                  let flag = movedRegister(code[i + 2], source: .x(0)),
                  let flagNumber = (19 ... 28).first(where: { flag == .x($0) }),
                  let stackKey = add(code[i + 3]), stackKey.source == .sp,
                  let clientKey = add(code[i + 4]), clientKey.destination == .x(0), clientKey.offset == 64,
                  let storedKey = add(code[i + 5]), storedKey.destination == .x(1),
                  storedKey.source == stackKey.destination, storedKey.offset == clientKey.offset,
                  immediateMove(code[i + 6], .w(2), 32),
                  let comparison = branch(code[i + 7], "bl"),
                  let bootAddress = compareBranch(code[i + 8], "cbz", .w(0)),
                  immediateMove(code[i + 9], .w(0), 0),
                  let boot = code.firstIndex(where: { $0.address == bootAddress }), boot > i + 9, boot + 6 < code.count,
                  let success = bitBranch(code[boot], register: .w(flagNumber)),
                  let bootBuffer = add(code[boot + 1]), bootBuffer.destination == .x(1),
                  bootBuffer.source == .sp, bootBuffer.offset == stackKey.offset,
                  movedRegister(code[boot + 2], source: clientKey.source) == .x(0),
                  immediateMove(code[boot + 3], .w(2), 64),
                  branch(code[boot + 4], "bl") == comparison,
                  compareBranch(code[boot + 5], "cbnz", .w(0)) == code[i + 9].address,
                  success == code[boot + 6].address,
                  try read(literal, environment.count) == environment
            else { continue }
            // Both client buffers must belong to the saved second argument;
            // otherwise a same-sized unrelated comparison is not this key.
            guard let clientRegister = (19 ... 28).first(where: { clientKey.source == .x($0) }),
                  let save = code[..<(i - 8)].lastIndex(where: { movedRegister($0, source: .x(1)) == clientKey.source }),
                  code[save + 1 ..< i + 4].allSatisfy({ !writes($0, register: clientRegister) }) else { continue }
            try verifyFlagLiveness(in: code, from: i + 3, bitTest: boot, register: flagNumber, failureTarget: failureTarget)
            let existing = destination == success ? nil : destination
            if let existing, start <= existing && existing < code.last!.address + 4 {
                throw PatcherError.patchVerificationFailed("\(label) unexpected in-function reuse branch")
            }
            candidates.append(.init(address: code[i].address, resume: code[i + 3].address,
                                    flagRegister: UInt32(flagNumber), existingCave: existing))
        }
        guard candidates.count == 1, let site = candidates.first else {
            throw PatcherError.patchSiteNotFound("\(label) expected one verified environment/key/boot chain, found \(candidates.count)")
        }
        return site
    }

    // The trampoline changes a callee-saved register, so every return must
    // restore its incoming value. Calls preserve it by ABI. Reject any other
    // use, redefinition, indirect control flow, or path escaping this function.
    static func verifyFlagLiveness(in code: [ARM64Instruction], from start: Int, bitTest: Int, register: Int, failureTarget: UInt64) throws {
        func mentions(_ instruction: ARM64Instruction) -> Bool {
            instruction.detail?.operands.contains(where: {
                ($0.type == .register && ($0.reg == .x(register) || $0.reg == .w(register))) ||
                    ($0.type == .memory && ($0.mem.base == .x(register) || $0.mem.index == .x(register)))
            }) == true
        }
        func stackPair(_ instruction: ARM64Instruction, mnemonic: String) -> [ARM64Operand]? {
            guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands,
                  operands.count == 3, operands[0].type == .register, operands[1].type == .register,
                  operands[2].type == .memory, operands[2].mem.base == .sp,
                  operands[2].mem.index == .invalid, instruction.detail?.writeback == false,
                  [operands[0].reg, operands[1].reg].contains(.x(register)) else { return nil }
            return operands
        }
        let restores = (start ..< code.count).filter { stackPair(code[$0], mnemonic: "ldp") != nil }
        guard restores.count == 1, let restore = restores.first,
              let pair = stackPair(code[restore], mnemonic: "ldp"),
              code[..<start].filter({ instruction in
                  guard let save = stackPair(instruction, mnemonic: "stp") else { return false }
                  return save[0].reg == pair[0].reg && save[1].reg == pair[1].reg && save[2].mem == pair[2].mem
              }).count == 1,
              (start ..< code.count).allSatisfy({ $0 == bitTest || $0 == restore || !mentions(code[$0]) })
        else { throw PatcherError.patchVerificationFailed("\(label) flag register is live outside the boot gate or lacks an exact ABI save/restore") }
        let indices = Dictionary(uniqueKeysWithValues: code.enumerated().map { ($0.element.address, $0.offset) })
        var pending = [(start, false)]
        var visited = Set<Int>()
        var returned = false
        while let (index, restored) = pending.popLast() {
            guard code.indices.contains(index) else { throw PatcherError.patchVerificationFailed("\(label) control flow leaves the function") }
            guard visited.insert(index * 2 + (restored ? 1 : 0)).inserted else { continue }
            let instruction = code[index]
            if instruction.isReturn {
                guard restored else { throw PatcherError.patchVerificationFailed("\(label) returns without restoring its flag register") }
                returned = true
                continue
            }
            let didRestore = restored || index == restore
            if index == bitTest, restored { throw PatcherError.patchVerificationFailed("\(label) boot gate reads an already restored flag") }
            if instruction.isJump && !instruction.isCall {
                guard let operand = instruction.detail?.operands.last, operand.type == .immediate,
                      let target = indices[UInt64(bitPattern: operand.imm)], target >= start
                else { throw PatcherError.patchVerificationFailed("\(label) unsupported flag control flow") }
                pending.append((target, didRestore))
                if instruction.mnemonic == "b" { continue }
            }
            // A terminal stack-check failure call does not return. It is the
            // only tolerated out-of-span fallthrough, and has no flag uses.
            if index == code.count - 1, branch(instruction, "bl") == failureTarget { continue }
            pending.append((index + 1, didRestore))
        }
        guard returned else { throw PatcherError.patchVerificationFailed("\(label) has no verified restored return") }
    }

    // MARK: - Verified padding and code generation

    static func plan(site: Site, padding: Range<UInt64>, read: (UInt64, Int) throws -> Data) throws -> Plan {
        guard padding.lowerBound % 4 == 0, padding.count >= caveSize else { throw PatcherError.patchSiteNotFound("\(label) header padding is too small or unaligned") }
        let cave: UInt64
        if let existing = site.existingCave {
            guard existing % 4 == 0, padding.contains(existing), existing <= padding.upperBound - UInt64(caveSize)
            else { throw PatcherError.patchVerificationFailed("\(label) branch leaves its header padding") }
            cave = existing
        } else {
            let bytes = try read(padding.lowerBound, Int(padding.count))
            guard bytes.count == padding.count else { throw PatcherError.patchSiteNotFound("\(label) header padding read is truncated") }
            for offset in stride(from: 0, through: bytes.count - caveSize, by: 4) {
                let address = padding.lowerBound + UInt64(offset)
                if try Data(bytes[offset ..< offset + caveSize]) == trampoline(at: address, returningTo: site.resume, flagRegister: site.flagRegister) {
                    throw PatcherError.patchVerificationFailed("\(label) orphaned trampoline has no matching site branch")
                }
            }
            guard let offset = stride(from: 0, through: bytes.count - caveSize, by: 4).first(where: {
                      bytes[$0 ..< $0 + caveSize].allSatisfy { $0 == 0 }
                  }) else { throw PatcherError.patchSiteNotFound("\(label) header padding is occupied") }
            cave = padding.lowerBound + UInt64(offset)
        }
        let program = try trampoline(at: cave, returningTo: site.resume, flagRegister: site.flagRegister)
        guard let from = Int(exactly: site.address), let to = Int(exactly: cave),
              let branch = ARM64Encoder.encodeB(from: from, to: to)
        else { throw PatcherError.patchVerificationFailed("\(label) trampoline is out of branch range") }
        if site.existingCave != nil, try read(cave, caveSize) != program {
            throw PatcherError.patchVerificationFailed("\(label) trampoline differs from this patch's output")
        }
        return .init(site: site, cave: cave, branch: branch, program: program)
    }

    static func trampoline(at cave: UInt64, returningTo resume: UInt64, flagRegister: UInt32) throws -> Data {
        guard (19 ... 28).contains(flagRegister), cave % 4 == 0, resume % 4 == 0,
              let base = Int(exactly: cave), let end = Int(exactly: resume),
              let flag = ARM64Encoder.encodeMovzW(rd: flagRegister, imm16: 1),
              let resumeBranch = ARM64Encoder.encodeB(from: base + 4, to: end)
        else { throw PatcherError.patchVerificationFailed("Cannot encode \(label) trampoline") }
        // MOVZ and B leave NZCV, LR and SP unchanged. The forced flag survives
        // the 32-byte comparison and skips only the subsequent boot check.
        return flag + resumeBranch
    }

    // MARK: - Typed operands

    static func writes(_ instruction: ARM64Instruction, register: Int) -> Bool {
        instruction.detail?.operands.contains(where: {
            ($0.type == .register && $0.writesRegister && ($0.reg == .x(register) || $0.reg == .w(register))) ||
                ($0.type == .memory && instruction.detail?.writeback == true && $0.mem.base == .x(register))
        }) == true
    }

    static func isStackFailure(_ target: UInt64, resolved: UInt64, read: (UInt64, Int) throws -> Data) throws -> Bool {
        if target == resolved { return true }
        // Cache-builder branch islands materialize the true destination in a
        // scratch register and BR to it. Resolve that dataflow, not its VMA.
        let stub = ARM64Disassembler().disassemble(try read(target, 12), at: target)
        guard stub.count == 3, stub.allSatisfy({ $0.isDecoded && $0.size == 4 }),
              stub[2].mnemonic == "br", let operands = stub[2].detail?.operands,
              operands.count == 1, operands[0].type == .register,
              DyldSharedCacheGLESPointDrawPatcher.materializedAddress(stub[0], stub[1], destination: operands[0].reg) == resolved
        else { return false }
        return true
    }

    static func branch(_ instruction: ARM64Instruction, _ mnemonic: String) -> UInt64? {
        DyldSharedCacheMetalVertexFormatPatcher.branchTarget(instruction, mnemonic: mnemonic)
    }

    static func movedRegister(_ instruction: ARM64Instruction, source: ARM64Register) -> ARM64Register? {
        guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[1].type == .register, operands[1].reg == source else { return nil }
        return operands[0].reg
    }

    static func immediateMove(_ instruction: ARM64Instruction, _ register: ARM64Register, _ value: Int64) -> Bool {
        DyldSharedCacheMetalVertexFormatPatcher.isImmediateMove(instruction, destination: register, value: value)
    }

    static func compareImmediate(_ instruction: ARM64Instruction, register: ARM64Register, value: Int64) -> Bool {
        guard instruction.mnemonic == "cmp", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .immediate, operands[1].imm == value else { return false }
        return true
    }

    static func add(_ instruction: ARM64Instruction) -> (destination: ARM64Register, source: ARM64Register, offset: Int64)? {
        guard instruction.mnemonic == "add", let operands = instruction.detail?.operands,
              operands.count == 3, operands[0].type == .register, operands[1].type == .register,
              operands[2].type == .immediate, operands[2].shift.amount == 0 else { return nil }
        return (operands[0].reg, operands[1].reg, operands[2].imm)
    }

    static func memory(_ instruction: ARM64Instruction, _ mnemonic: String) -> (register: ARM64Register, base: ARM64Register, offset: Int32)? {
        guard let value = DyldSharedCacheGLESPointDrawPatcher.memory(instruction, mnemonic: mnemonic) else { return nil }
        return (value.register, value.base, value.offset)
    }

    static func compareBranch(_ instruction: ARM64Instruction, _ mnemonic: String, _ register: ARM64Register) -> UInt64? {
        DyldSharedCacheGLESPointDrawPatcher.compareBranch(instruction, mnemonic: mnemonic, register: register)
    }

    static func bitBranch(_ instruction: ARM64Instruction, register: ARM64Register) -> UInt64? {
        DyldSharedCacheGLESPointDrawPatcher.bitBranch(instruction, mnemonic: "tbnz", register: register, bit: 0)
    }
}
