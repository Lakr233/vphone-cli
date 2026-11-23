// GLES's internal framebuffer copy bypasses viewport transformation. PV does
// not carry the attachment's private Y inversion, so submit window positions
// in the same origin convention as the renderer's ordinary viewport/scissor.
// Copy the transient six-position array; leave caller storage and UVs intact.
import Foundation
import VPhonePatchKit

public enum DyldSharedCacheGLESBlitPatcher {
    public static let imagePath = DyldSharedCacheGLESPrimitiveRestartPatcher.imagePath
    public static let symbolName = "_gldBlitFramebufferData"
    static let viewportSymbol = "__ZN13GLDContextRec20updateRenderViewportEv"
    static let label = "GLES framebuffer blit orientation"
    typealias Helpers = DyldSharedCacheGLESPointDrawPatcher

    struct Fields: Equatable {
        let origin: UInt32
        let framebuffer: UInt32
        let data: UInt32
        let height: UInt32
    }

    struct Plan {
        let fields: Fields
        let context: UInt32
        let sites: [UInt64]
        let callee: UInt64
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
            if captureUndo, let failure = error as? DyldSharedCachePatchRollbackError { onUndo?(failure.recoveryUndo) }
            throw error
        }
    }

    public static func patch(
        chunks: DyldSharedCacheChunkSet, resolver: DyldSharedCacheSymbolResolver,
        dryRun: Bool = false, log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog
    ) throws {
        try resolver.requireLocalSymbols()
        let symbols = try resolver.symbols(inImage: imagePath)
        func decode(_ name: String) throws -> [ARM64Instruction] {
            let start = try resolver.address(of: name, inImage: imagePath)
            let span = try Helpers.functionSpan(at: start, symbolAddresses: symbols.values.map(\.address))
            guard chunks.mappings.contains(where: { $0.isExecutable && $0.address <= start && $0.endAddress >= span.upperBound })
            else { throw PatcherError.patchSiteNotFound("\(label): non-executable function") }
            let code = ARM64Disassembler().disassemble(try chunks.bytesAtVMA(start, length: Int(span.count)), at: start)
            guard code.count * 4 == span.count, code.allSatisfy({ $0.isDecoded && $0.size == 4 })
            else { throw PatcherError.patchSiteNotFound("\(label): incomplete function decode") }
            return code
        }
        let code = try decode(symbolName)
        func selector(_ name: String) throws -> UInt64 {
            try resolver.objcMessageTarget("_objc_msgSend$" + name, inImage: imagePath, calledBy: code, chunks: chunks)
        }
        let plan = try discover(blit: code, viewport: decode(viewportSymbol),
                                vertex: selector("setVertexBytes:length:atIndex:"),
                                viewportSetter: selector("setViewportTransformEnabled:"),
                                draw: selector("drawPrimitives:vertexStart:vertexCount:"), read: chunks.bytesAtVMA)
        let headerAddress = try resolver.headerAddress(ofImage: imagePath)
        let prefix = try chunks.bytesAtVMA(headerAddress, length: 32)
        let loadSize = Int(prefix.loadLE(UInt32.self, at: 20))
        guard loadSize < 1 << 20 else { throw PatcherError.invalidFormat("\(label): invalid load commands") }
        let size = try program(plan, at: headerAddress).count
        let header = try chunks.bytesAtVMA(headerAddress, length: 32 + loadSize)
        // The renderer's tiny header gap is already used by the restart/depth
        // patches. Its final __TEXT page has separate alignment padding before
        // the next cache image. Bound that gap by both Mach-O headers and the
        // executable cache mapping, never by a search for zeroes in code/data.
        let nextHeader = try resolver.imagePaths.map { try resolver.headerAddress(ofImage: $0) }
            .filter { $0 > headerAddress }.min()
        let padding = try tailPadding(header: header, address: headerAddress, nextHeader: nextHeader)
        guard chunks.mappings.contains(where: { $0.isExecutable && $0.address <= padding.lowerBound && $0.endAddress >= padding.upperBound })
        else { throw PatcherError.patchVerificationFailed("\(label): padding is not executable") }
        let cave = try codeCave(plan, padding: padding, read: chunks.bytesAtVMA)
        let body = try program(plan, at: cave)
        let calls = try plan.sites.map { address in
            guard let call = ARM64Encoder.encodeBL(from: Int(address), to: Int(cave))
            else { throw PatcherError.patchVerificationFailed("\(label): call out of range") }
            return call
        }
        log?("  [.] \(label): origin +0x\(String(plan.fields.origin, radix: 16)), framebuffer height discovered from viewport")
        log?("  [\(plan.existingCave != nil ? "=" : dryRun ? "~" : "+")] trampoline @ 0x\(String(cave, radix: 16)), \(size) bytes: \(plan.existingCave != nil ? "verified existing body" : "unused page tail -> private reflected positions")")
        for site in plan.sites {
            log?("  [\(plan.existingCave != nil ? "=" : dryRun ? "~" : "+")] \(label) @ 0x\(String(site, radix: 16)): BL 0x\(String(plan.callee, radix: 16)) -> BL 0x\(String(cave, radix: 16))")
        }
        guard !dryRun, plan.existingCave == nil else { return }
        let spans = [DyldSharedCacheWriteSpan(vma: cave, length: size)] + plan.sites.map { .init(vma: $0, length: 4) }
        let snapshots = try DyldSharedCachePatchTransaction.snapshots(for: spans, in: chunks)
        chunks.clearRecordedWrites()
        _ = try DyldSharedCachePatchTransaction.run(snapshots: snapshots, label: label, log: log) {
            try chunks.write(at: cave, body)
            for (site, call) in zip(plan.sites, calls) { try chunks.write(at: site, call) }
            let attested = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
            guard attested.isFullyAttested, try chunks.bytesAtVMA(cave, length: size) == body
            else { throw PatcherError.patchVerificationFailed("\(label): trampoline readback or re-attestation failed") }
            for (site, call) in zip(plan.sites, calls) where try chunks.bytesAtVMA(site, length: 4) != call {
                throw PatcherError.patchVerificationFailed("\(label): call did not read back")
            }
            return attested
        }
    }

    static func tailPadding(header: Data, address: UInt64, nextHeader: UInt64?) throws -> Range<UInt64> {
        guard header.count >= 32, header.loadLE(UInt32.self, at: 0) == 0xFEED_FACF,
              Int(header.loadLE(UInt32.self, at: 20)) + 32 == header.count,
              let text = MachOParser.parseSegments(from: header).first(where: { $0.name == "__TEXT" }),
              text.vmAddr == address, text.vmSize == text.fileSize, text.vmSize > header.count,
              address < UInt64.max - 4096,
              text.vmSize < UInt64.max - address - 4096, let nextHeader,
              nextHeader == (address + text.vmSize + 4095) & ~UInt64(4095),
              MachOParser.parseSections(from: header).values.filter({ $0.segmentName == "__TEXT" }).allSatisfy({
                  $0.address >= address && $0.address <= address + text.vmSize &&
                      $0.size <= address + text.vmSize - $0.address
              })
        else { throw PatcherError.patchSiteNotFound("\(label): no bounded __TEXT page tail") }
        let start = (address + text.vmSize + 3) & ~UInt64(3)
        guard start < nextHeader else { throw PatcherError.patchSiteNotFound("\(label): no __TEXT page tail") }
        return start ..< nextHeader
    }

    static func codeCave(_ plan: Plan, padding: Range<UInt64>, read: (UInt64, Int) throws -> Data) throws -> UInt64 {
        let cave = padding.lowerBound
        let body = try program(plan, at: cave)
        guard cave % 4 == 0, body.count <= padding.count
        else { throw PatcherError.patchSiteNotFound("\(label): insufficient __TEXT page tail") }
        let bytes = try read(cave, body.count)
        guard bytes.count == body.count else { throw PatcherError.patchVerificationFailed("\(label): short cave read") }
        if let previous = plan.existingCave {
            guard previous == cave, bytes == body
            else { throw PatcherError.patchVerificationFailed("\(label): unexpected existing trampoline") }
        } else {
            guard bytes.allSatisfy({ $0 == 0 })
            else { throw PatcherError.patchVerificationFailed("\(label): occupied or orphaned trampoline") }
        }
        return cave
    }

    // MARK: - Semantic discovery

    static func discover(
        blit: [ARM64Instruction], viewport: [ARM64Instruction], vertex: UInt64,
        viewportSetter: UInt64, draw: UInt64, read: (UInt64, Int) throws -> Data
    ) throws -> Plan {
        let fields = try viewportFields(viewport)
        guard let contextRegister = Helpers.contextRegister(in: blit),
              let context = (19 ... 28).first(where: { contextRegister == .x($0) }),
              let saved = blit.firstIndex(where: { Helpers.move($0, destination: contextRegister) == .x(0) })
        else { throw PatcherError.patchSiteNotFound("\(label): missing preserved context") }
        let draws = blit.indices.filter { branch(blit[$0]) == draw }
        guard !draws.isEmpty else { throw PatcherError.patchSiteNotFound("\(label): no internal triangle draws") }
        var sites: [UInt64] = [], targets: [UInt64] = [], buffers = Set<Int32>()
        for end in draws {
            // Position slot 0, then UV slot 1, then six triangle vertices.
            let i = end - 10
            guard i >= 7, saved < i - 7,
                  immediate(blit[end - 3], register: 2) == 3,
                  immediate(blit[end - 2], register: 3) == 0,
                  immediate(blit[end - 1], register: 4) == 6,
                  branch(blit[i + 5]) == vertex, immediate(blit[i + 4], register: 4) == 1,
                  let target = branch(blit[i]),
                  immediate(blit[i - 1], register: 4) == 0, immediate(blit[i - 2], register: 3) == 96,
                  let buffer = framePointerOffset(blit[i - 3]),
                  let receiver = Helpers.memory(blit[i - 4], mnemonic: "ldr"),
                  receiver.register == .x(0),
                  let encoder = (19 ... 29).first(where: { receiver.base == .x($0) }),
                  viewportReceiver(blit[i - 7], matches: receiver),
                  [i + 1, i + 6].allSatisfy({
                      guard let next = Helpers.memory(blit[$0], mnemonic: "ldr") else { return false }
                      return next.register == .x(0) && next.base == receiver.base && next.offset == receiver.offset
                  }),
                  blit[(i - 6) ... end].allSatisfy({ !writes($0, registers: [.x(encoder), .w(encoder)]) }),
                  branch(blit[i - 5]) == viewportSetter, immediate(blit[i - 6], register: 2) == 0
            else { throw PatcherError.patchSiteNotFound("\(label): unsupported position/UV submission") }
            sites.append(blit[i].address)
            targets.append(target)
            buffers.insert(buffer)
        }
        guard buffers.count == 1, let buffer = buffers.first, Set(targets).count == 1,
              let last = blit.firstIndex(where: { $0.address == sites.max() }),
              blit[(saved + 1) ... last].allSatisfy({ !writes($0, registers: [.x(context), .w(context)]) })
        else { throw PatcherError.patchVerificationFailed("\(label): inconsistent buffers, calls or context lifetime") }
        try verifyPositions(blit, buffer: buffer, read: read)
        return Plan(fields: fields, context: UInt32(context), sites: sites, callee: vertex,
                    existingCave: targets[0] == vertex ? nil : targets[0])
    }

    static func viewportReceiver(_ instruction: ARM64Instruction, matches receiver: Helpers.Memory) -> Bool {
        guard instruction.mnemonic == "ldr", let detail = instruction.detail, !detail.postIndex else { return false }
        let op = detail.operands
        guard op.count == 2, op[0].type == .register, op[0].reg == .x(0),
              op[1].type == .memory, op[1].mem.base == receiver.base, op[1].mem.index == .invalid
        else { return false }
        // The second native pass uses LDR x0, [x19, #offset]! to advance
        // the saved slot pointer. Its following loads must use [x19, #0].
        // Post-indexed loads access the old pointer and are not equivalent.
        return detail.writeback ? receiver.offset == 0 : op[1].mem.disp == receiver.offset
    }

    static func viewportFields(_ code: [ARM64Instruction]) throws -> Fields {
        var found: [Fields] = []
        for i in code.indices where i >= 2 && i + 6 < code.count {
            guard code[i].mnemonic == "cmp", let cmp = code[i].detail?.operands,
                  cmp.count == 2, cmp[0].type == .register, cmp[1].type == .immediate, cmp[1].imm == 1,
                  code[i + 1].mnemonic == "b.ne", let skip = code[i + 1].detail?.operands.last?.imm,
                  let flag = byteField(code, at: i - 1), flag.register == cmp[0].reg,
                  let framebuffer = Helpers.memory(code[i + 2], mnemonic: "ldr"), framebuffer.base == .x(0),
                  Helpers.isX(framebuffer.register),
                  let data = Helpers.memory(code[i + 3], mnemonic: "ldr"), data.base == framebuffer.register,
                  Helpers.isX(data.register),
                  let height = Helpers.memory(code[i + 4], mnemonic: "ldr"), height.base == data.register,
                  let heightRegister = (0 ..< 32).first(where: { height.register == .h($0) }),
                  let converted = registers(code[i + 5], mnemonic: "ucvtf"), converted.count == 2,
                  converted[1] == .s(heightRegister),
                  let end = code.firstIndex(where: { $0.address == UInt64(bitPattern: skip) }), end > i + 5,
                  code[(i + 6) ..< end].contains(where: {
                      guard let r = registers($0, mnemonic: "fsub") else { return false }
                      return r.count == 3 && r[0] == converted[0] && r[1] == converted[0]
                  }),
                  [framebuffer.offset, data.offset, height.offset].allSatisfy({ $0 >= 0 && $0 < 65536 }),
                  code[..<i].allSatisfy({ !$0.isCall && !$0.isJump && !writes($0, registers: [.x(0), .w(0)]) })
            else { continue }
            found.append(.init(origin: flag.offset, framebuffer: UInt32(framebuffer.offset),
                               data: UInt32(data.offset), height: UInt32(height.offset)))
        }
        guard found.count == 1 else { throw PatcherError.patchSiteNotFound("\(label): expected one viewport origin/height dataflow, found \(found.count)") }
        return found[0]
    }

    static func byteField(_ code: [ARM64Instruction], at i: Int) -> (register: ARM64Register, offset: UInt32)? {
        guard i >= 1, code[i].mnemonic == "ldrb", let op = code[i].detail?.operands, op.count == 2,
              op[0].type == .register, op[1].type == .memory, code[i].detail?.writeback == false else { return nil }
        let memory = op[1].mem
        if memory.base == .x(0), memory.index != .invalid,
           let n = (0 ... 30).first(where: { memory.index == .x($0) }),
           let offset = immediate(code[i - 1], register: n), (0 ... 65535).contains(offset), memory.disp == 0 {
            return (op[0].reg, UInt32(offset))
        }
        // Newer cache builds split the register-indexed byte load into ADD+LDRB.
        if i >= 2, memory.index == .invalid, memory.disp == 0,
           let add = registers(code[i - 1], mnemonic: "add"), add.count == 3,
           add[0] == memory.base, add[1] == .x(0),
           let n = (0 ... 30).first(where: { add[2] == .x($0) }),
           let offset = immediate(code[i - 2], register: n), (0 ... 65535).contains(offset) {
            return (op[0].reg, UInt32(offset))
        }
        return nil
    }

    static func verifyPositions(_ code: [ARM64Instruction], buffer: Int32, read: (UInt64, Int) throws -> Data) throws {
        // Six float4 records: the renderer initializes every Z/W pair from
        // its literal (0.0f, 1.0f). This also proves the stride and buffer type;
        // a length of 96 alone would not distinguish arbitrary vertex data.
        let offsets = Set((0 ..< 6).map { buffer + Int32($0 * 16 + 8) })
        let stores = code.indices.filter {
            guard let m = Helpers.memory(code[$0], mnemonic: "stur") ?? Helpers.memory(code[$0], mnemonic: "str") else { return false }
            return m.base == .x(29) && offsets.contains(m.offset) && (0 ..< 32).contains(where: { m.register == .d($0) })
        }
        guard stores.count == 6, let first = stores.first, let last = stores.last,
              let reg = code[first].detail?.operands.first?.reg,
              Set(stores.map { code[$0].detail!.operands[1].mem.disp }) == offsets,
              stores.allSatisfy({ code[$0].detail?.operands.first?.reg == reg }),
              let load = code[..<first].lastIndex(where: { Helpers.memory($0, mnemonic: "ldr")?.register == reg }), load > 0,
              let literal = Helpers.memory(code[load], mnemonic: "ldr"), literal.offset >= 0,
              code[load - 1].mnemonic == "adrp", let page = code[load - 1].detail?.operands,
              page.count == 2, page[0].reg == literal.base, page[1].type == .immediate,
              try read(UInt64(bitPattern: page[1].imm) + UInt64(literal.offset), 8).loadLE(UInt64.self, at: 0) == 0x3F80_0000_0000_0000,
              let n = (0 ..< 32).first(where: { reg == .d($0) }),
              code[(load + 1) ... last].allSatisfy({
                  !$0.isCall && !$0.isJump && !writes($0, registers: [.b(n), .h(n), .s(n), .d(n), .q(n)])
              })
        else { throw PatcherError.patchSiteNotFound("\(label): unproven six-float4 position layout") }
    }

    // MARK: - ABI-preserving submission wrapper

    static func program(_ plan: Plan, at base: UInt64) throws -> Data {
        var output = Data()
        func emit(_ bytes: Data?) throws {
            guard let bytes else { throw PatcherError.patchVerificationFailed("\(label): unencodable trampoline") }
            output += bytes
        }
        // x16 and s0/s7 are call-clobbered; the native call has no FP arguments.
        // x0/x1/x3/x4 and every callee-saved register keep the native ABI.
        var offset = plan.fields.origin
        var source = plan.context
        while offset >= 4096 {
            try emit(ARM64Encoder.encodeAddImm12(rd: 16, rn: source, imm12: 4095))
            source = 16
            offset -= 4095
        }
        try emit(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 16, rn: source, offset: offset))
        try emit(ARM64Encoder.encodeCmpWImmediate(rn: 16, imm12: 1))
        let conditional = output.count
        try emit(ARM64.nop)
        try emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 16, rn: plan.context, offset: plan.fields.framebuffer))
        try emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 16, rn: 16, offset: plan.fields.data))
        try emit(ARM64Encoder.encodeLdrHUnsignedOffset(rt: 16, rn: 16, offset: plan.fields.height))
        try emit(ARM64Encoder.encodeUcvtfSFromW(rd: 7, rn: 16))
        // 96 bytes of positions plus a standard aligned frame record.
        try emit(ARM64.pacibsp)
        try emit(ARM64Encoder.encodeSubImm12(rd: 31, rn: 31, imm12: 112))
        try emit(ARM64Encoder.encodeStpX(rt1: 29, rt2: 30, rn: 31, offset: 96))
        try emit(ARM64Encoder.encodeAddImm12(rd: 29, rn: 31, imm12: 96))
        for vertex in 0 ..< UInt32(6) {
            let position = vertex * 16, y = position + 4
            try emit(ARM64Encoder.encodeLoadStoreSIMD(load: true, quad: true, rt: 0, rn: 2, offset: position))
            try emit(ARM64Encoder.encodeLoadStoreSIMD(load: false, quad: true, rt: 0, rn: 31, offset: position))
            try emit(ARM64Encoder.encodeLoadStoreSIMD(load: true, quad: false, rt: 0, rn: 2, offset: y))
            try emit(ARM64Encoder.encodeFsubS(rd: 0, rn: 7, rm: 0))
            try emit(ARM64Encoder.encodeLoadStoreSIMD(load: false, quad: false, rt: 0, rn: 31, offset: y))
        }
        try emit(ARM64Encoder.encodeAddImm12(rd: 2, rn: 31, imm12: 0))
        try emit(ARM64Encoder.encodeBL(from: Int(base) + output.count, to: Int(plan.callee)))
        try emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 29, rn: 31, offset: 96))
        try emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 30, rn: 31, offset: 104))
        try emit(ARM64Encoder.encodeAddImm12(rd: 31, rn: 31, imm12: 112))
        try emit(ARM64.retab)
        let tail = output.count
        try emit(ARM64Encoder.encodeB(from: Int(base) + tail, to: Int(plan.callee)))
        guard let gate = ARM64Encoder.encodeBCond(from: Int(base) + conditional, to: Int(base) + tail, condition: .ne)
        else { throw PatcherError.patchVerificationFailed("\(label): invalid origin gate") }
        output.replaceSubrange(conditional ..< conditional + 4, with: gate)
        return output
    }

    static func branch(_ instruction: ARM64Instruction) -> UInt64? { Helpers.branch(instruction, mnemonic: "bl") }

    static func immediate(_ instruction: ARM64Instruction, register: Int) -> Int64? {
        guard instruction.mnemonic == "mov", let op = instruction.detail?.operands, op.count == 2,
              op[0].type == .register, [.w(register), .x(register)].contains(op[0].reg),
              op[1].type == .immediate, op[1].shift.amount == 0 else { return nil }
        return op[1].imm
    }

    static func registers(_ instruction: ARM64Instruction, mnemonic: String) -> [ARM64Register]? {
        guard instruction.mnemonic == mnemonic, let op = instruction.detail?.operands,
              op.allSatisfy({ $0.type == .register && $0.shift.amount == 0 }) else { return nil }
        return op.map(\.reg)
    }

    static func framePointerOffset(_ instruction: ARM64Instruction) -> Int32? {
        guard instruction.mnemonic == "sub", let op = instruction.detail?.operands, op.count == 3,
              op[0].reg == .x(2), op[1].reg == .x(29), op[2].type == .immediate,
              op[2].imm >= 96, op[2].imm <= 4095, op[2].shift.amount == 0 else { return nil }
        return -Int32(op[2].imm)
    }

    static func writes(_ instruction: ARM64Instruction, registers: [ARM64Register]) -> Bool {
        guard let detail = instruction.detail else { return true }
        return detail.operands.contains {
            ($0.type == .register && $0.writesRegister && registers.contains($0.reg)) ||
                ($0.type == .memory && detail.writeback && registers.contains($0.mem.base))
        }
    }
}
