// PV drops the OpenGL render-pass clip convention. With GLES position.z
// lowered to (z+w)/2 by the compiler, convert the renderer's midpoint near
// endpoint back to 2*mid-far. This patch and the compiler configuration form
// one installer transaction and one selection.
import Foundation
import VPhonePatchKit

public enum DyldSharedCacheGLESDepthClipPatcher {
    public static let imagePath = DyldSharedCacheGLESPrimitiveRestartPatcher.imagePath
    public static let symbolName = "__ZN13GLDContextRec20updateRenderViewportEv"
    static let setterName = "__ZN13GLDContextRec17setRenderViewportEv"
    static let label = "GLES depth clip viewport"
    static let caveSize = 16

    struct Site {
        let address: UInt64
        let near: UInt32
        let source: UInt32
        let far: UInt32
        let existingCave: UInt64?
    }

    public static func patch(
        chunksDirectory: URL, dryRun: Bool = false, captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog
    ) throws {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, captureUndo: captureUndo)
        do {
            let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
            try patch(chunks: chunks, resolver: resolver, dryRun: dryRun, log: log)
            if captureUndo, let undo = chunks.takeUndoLog() { onUndo?(undo) }
        } catch {
            if captureUndo, let failure = error as? DyldSharedCachePatchRollbackError {
                onUndo?(failure.recoveryUndo)
            }
            throw error
        }
    }

    public static func patch(
        chunks: DyldSharedCacheChunkSet, resolver: DyldSharedCacheSymbolResolver,
        dryRun: Bool = false, log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog
    ) throws {
        try resolver.requireLocalSymbols()
        let symbols = try resolver.symbols(inImage: imagePath)
        let update = try resolver.address(of: symbolName, inImage: imagePath)
        let setter = try resolver.address(of: setterName, inImage: imagePath)
        let send = try resolver.address(of: "_objc_msgSend$setViewport:", inImage: imagePath)
        func decode(_ address: UInt64) throws -> [ARM64Instruction] {
            let span = try DyldSharedCacheGLESPointDrawPatcher.functionSpan(at: address, symbolAddresses: symbols.values.map(\.address))
            guard chunks.mappings.contains(where: { $0.isExecutable && $0.address <= address && $0.endAddress >= span.upperBound })
            else { throw PatcherError.patchVerificationFailed("\(label) function is not executable") }
            let code = ARM64Disassembler().disassemble(try chunks.bytesAtVMA(address, length: Int(span.count)), at: address)
            guard code.count * 4 == span.count, code.allSatisfy(\.isDecoded)
            else { throw PatcherError.patchSiteNotFound("\(label) incomplete function decode") }
            return code
        }
        let code = try decode(update)
        let site = try findSite(update: code, setter: decode(setter), updateAddress: update, sendAddress: send)
        let headerAddress = try resolver.headerAddress(ofImage: imagePath)
        let prefix = try chunks.bytesAtVMA(headerAddress, length: 32)
        let size = Int(prefix.loadLE(UInt32.self, at: 20))
        guard size < 1 << 20 else { throw PatcherError.invalidFormat("\(label) invalid load commands") }
        let header = try chunks.bytesAtVMA(headerAddress, length: 32 + size)
        let padding = try DyldSharedCachePatchTransaction.headerPadding(in: header, at: headerAddress, minimumSize: caveSize, label: label)
        guard chunks.mappings.contains(where: { $0.isExecutable && $0.address <= padding.lowerBound && $0.endAddress >= padding.upperBound })
        else { throw PatcherError.patchVerificationFailed("\(label) padding is not executable") }
        let bytes = try chunks.bytesAtVMA(padding.lowerBound, length: Int(padding.count))
        let cave: UInt64
        if let existing = site.existingCave {
            guard existing % 4 == 0, existing >= padding.lowerBound, existing + UInt64(caveSize) <= padding.upperBound
            else { throw PatcherError.patchVerificationFailed("\(label) branch leaves header padding") }
            cave = existing
        } else {
            // An orphaned copy is an interrupted/foreign patch, not free space.
            for offset in stride(from: 0, through: bytes.count - caveSize, by: 4) {
                if try bytes.subdata(in: offset ..< offset + caveSize) == trampoline(site, at: padding.lowerBound + UInt64(offset)) {
                    throw PatcherError.patchVerificationFailed("\(label) orphaned trampoline")
                }
            }
            guard let offset = stride(from: 0, through: bytes.count - caveSize, by: 4).first(where: {
                bytes[$0 ..< $0 + caveSize].allSatisfy { $0 == 0 }
            }) else { throw PatcherError.patchSiteNotFound("\(label) no unused header padding") }
            cave = padding.lowerBound + UInt64(offset)
        }
        let program = try trampoline(site, at: cave)
        guard let branch = ARM64Encoder.encodeB(from: Int(site.address), to: Int(cave))
        else { throw PatcherError.patchVerificationFailed("\(label) branch out of range") }
        if site.existingCave != nil {
            guard try chunks.bytesAtVMA(cave, length: caveSize) == program
            else { throw PatcherError.patchVerificationFailed("\(label) unexpected trampoline") }
        }
        log?("  [\(site.existingCave != nil ? "=" : dryRun ? "~" : "+")] \(label) @ 0x\(String(site.address, radix: 16)) -> 0x\(String(cave, radix: 16)): near = 2 * midpoint - far")
        guard !dryRun, site.existingCave == nil else { return }
        let spans = [DyldSharedCacheWriteSpan(vma: cave, length: caveSize), .init(vma: site.address, length: 4)]
        let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
        chunks.clearRecordedWrites()
        _ = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: label, log: log) {
            try chunks.write(at: cave, program)
            try chunks.write(at: site.address, branch)
            let attested = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
            guard attested.isFullyAttested,
                  try chunks.bytesAtVMA(cave, length: caveSize) == program,
                  try chunks.bytesAtVMA(site.address, length: 4) == branch
            else { throw PatcherError.patchVerificationFailed("\(label) readback or re-attestation failed") }
            return attested
        }
    }

    static func findSite(update: [ARM64Instruction], setter: [ARM64Instruction], updateAddress: UInt64, sendAddress: UInt64) throws -> Site {
        // Derive the viewport's context offset from the setter's contiguous
        // 48-byte load. Offsets 0/16/32 are MTLViewport ABI, not guest fields.
        let calls = setter.indices.filter { branch(setter[$0]) == updateAddress && setter[$0].mnemonic == "bl" }
        guard calls.count == 1, let call = calls.first, call > 0, call + 8 < setter.count,
              let first = memory(setter[call + 2], "ldr"), first.register == .q(0),
              (19 ... 28).contains(where: { first.base == .x($0) }),
              registers(setter[call - 1], "mov", count: 2) == [first.base, .x(0)],
              setter[..<(call - 1)].allSatisfy({
                  !$0.isCall && !$0.isJump && !$0.isReturn && !writes($0, registers: [.x(0), .w(0)])
              }),
              let receiver = memory(setter[call + 1], "ldr"), receiver.register == .x(0), receiver.base == first.base,
              let second = memory(setter[call + 3], "ldr"), second.register == .q(1),
              first.base == second.base, second.offset == first.offset + 16,
              let last = memory(setter[call + 5], "ldr"), last.register == .q(0),
              last.base == first.base, last.offset == first.offset + 32,
              stackPair(setter[call + 4]),
              let stack = memory(setter[call + 6], "str"), stack.register == .q(0), stack.base == .sp, stack.offset == 32,
              registers(setter[call + 7], "mov", count: 2) == [.x(2), .sp],
              setter[call + 8].mnemonic == "bl", branch(setter[call + 8]) == sendAddress
        else { throw PatcherError.patchSiteNotFound("\(label) unsupported viewport setter") }
        let nearStores = update.indices.filter {
            guard let store = memory(update[$0], "str") else { return false }
            return store.base == .x(0) && store.offset == first.offset + 32
        }
        guard nearStores.count == 1, let nearStore = nearStores.first, nearStore + 1 < update.count,
              let nearMemory = memory(update[nearStore], "str"),
              let farMemory = memory(update[nearStore + 1], "str"), farMemory.base == .x(0), farMemory.offset == first.offset + 40,
              let near = number(nearMemory.register, double: true),
              let far = number(farMemory.register, double: true), near != far
        else { throw PatcherError.patchSiteNotFound("\(label) missing adjacent depth stores") }
        var sites: [Site] = []
        for i in update.indices where i >= 2 && i < nearStore {
            guard let addition = registers(update[i - 2], "fadd", count: 3),
                  let conversion = registers(update[i - 1], "fcvt", count: 2),
                  conversion[0] == .d(Int(far)), addition[0] == conversion[1],
                  addition[2] == addition[0], let source = number(addition[1], double: false),
                  addition[1] != addition[0], source != far,
                  update[(i + 1) ..< nearStore].allSatisfy({ instruction in
                      !instruction.isJump && !instruction.isCall &&
                      !writes(instruction, registers: simdAliases(near) + simdAliases(far))
                  })
            else { continue }
            let original = registers(update[i], "fcvt", count: 2)
            let existing = update[i].mnemonic == "b" ? branch(update[i]) : nil
            guard original == [.d(Int(near)), .s(Int(source))] || existing != nil else { continue }
            // Both operands must originate in the same GL state object.
            guard let midIndex = update[..<(i - 2)].lastIndex(where: { memory($0, "ldr")?.register == addition[1] }),
                  let halfIndex = update[..<(i - 2)].lastIndex(where: { memory($0, "ldr")?.register == addition[2] }),
                  let mid = memory(update[midIndex], "ldr"), let half = memory(update[halfIndex], "ldr"),
                  let halfRegister = number(half.register, double: false),
                  mid.base == half.base, mid.offset != half.offset,
                  update[(midIndex + 1) ..< (i - 2)].allSatisfy({ !writes($0, registers: simdAliases(source)) }),
                  update[(halfIndex + 1) ..< (i - 2)].allSatisfy({ !writes($0, registers: simdAliases(halfRegister)) }),
                  let baseNumber = (0 ... 30).first(where: { mid.base == .x($0) }),
                  update[(min(midIndex, halfIndex) + 1) ..< (i - 2)].allSatisfy({
                      !writes($0, registers: [.x(baseNumber), .w(baseNumber)])
                  }),
                  update[...max(midIndex, halfIndex)].allSatisfy({ !$0.isJump && !$0.isCall }),
                  update[..<nearStore].allSatisfy({ !writes($0, registers: [.x(0), .w(0)]) })
            else { continue }
            sites.append(.init(address: update[i].address, near: near, source: source, far: far, existingCave: existing))
        }
        guard sites.count == 1, let site = sites.first
        else { throw PatcherError.patchSiteNotFound("\(label) expected one midpoint conversion, found \(sites.count)") }
        guard update.last?.isReturn == true,
              update.dropLast().allSatisfy({ instruction in
                  if instruction.isCall || instruction.isReturn { return false }
                  if !instruction.isJump || instruction.address == site.address { return true }
                  guard let target = branch(instruction) else { return false }
                  return target >= updateAddress && target < site.address - 8
              })
        else { throw PatcherError.patchVerificationFailed("\(label) control flow bypasses depth conversion") }
        return site
    }

    static func trampoline(_ site: Site, at cave: UInt64) throws -> Data {
        guard let convert = ARM64Encoder.encodeFcvtDFromS(rd: site.near, rn: site.source),
              let twice = ARM64Encoder.encodeFaddSubD(subtract: false, rd: site.near, rn: site.near, rm: site.near),
              let near = ARM64Encoder.encodeFaddSubD(subtract: true, rd: site.near, rn: site.near, rm: site.far),
              let resume = ARM64Encoder.encodeB(from: Int(cave + 12), to: Int(site.address + 4))
        else { throw PatcherError.patchVerificationFailed("\(label) cannot encode conversion") }
        return convert + twice + near + resume
    }

    static func number(_ register: ARM64Register, double: Bool) -> UInt32? {
        (0 ..< 32).first(where: { register == (double ? .d($0) : .s($0)) }).map(UInt32.init)
    }

    static func simdAliases(_ number: UInt32) -> [ARM64Register] {
        let n = Int(number)
        return [.b(n), .h(n), .s(n), .d(n), .q(n)]
    }

    static func writes(_ instruction: ARM64Instruction, registers: [ARM64Register]) -> Bool {
        guard let detail = instruction.detail else { return true }
        return detail.operands.contains {
            ($0.type == .register && $0.writesRegister && registers.contains($0.reg)) ||
                ($0.type == .memory && detail.writeback && registers.contains($0.mem.base))
        }
    }

    static func stackPair(_ instruction: ARM64Instruction) -> Bool {
        guard instruction.mnemonic == "stp", let detail = instruction.detail,
              !detail.writeback, detail.operands.count == 3 else { return false }
        let operands = detail.operands
        return operands[0].type == .register && operands[0].reg == .q(0) &&
            operands[1].type == .register && operands[1].reg == .q(1) &&
            operands[2].type == .memory && operands[2].mem.base == .sp &&
            operands[2].mem.index == .invalid && operands[2].mem.disp == 0
    }

    static func registers(_ instruction: ARM64Instruction, _ mnemonic: String, count: Int) -> [ARM64Register]? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands,
              operands.count == count, operands.allSatisfy({ $0.type == .register }) else { return nil }
        return operands.map(\.reg)
    }

    static func memory(_ instruction: ARM64Instruction, _ mnemonic: String) -> (register: ARM64Register, base: ARM64Register, offset: Int32)? {
        guard let memory = DyldSharedCacheGLESPointDrawPatcher.memory(instruction, mnemonic: mnemonic) else { return nil }
        return (memory.register, memory.base, memory.offset)
    }

    static func branch(_ instruction: ARM64Instruction) -> UInt64? {
        guard let operand = instruction.detail?.operands.last, operand.type == .immediate else { return nil }
        return UInt64(bitPattern: operand.imm)
    }
}
