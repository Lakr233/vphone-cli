import Foundation
import VPhonePatchKit

/// iOS 16's libSystem initializes libxpc before inserted libraries can interpose.
/// Keep its public array API, but decode XNU 12377's three inline port rights.
public enum DyldSharedCacheMachPortsPatcher {
    public static let image = "/usr/lib/system/libsystem_kernel.dylib"
    public struct Prepared {
        public let address: UInt64
        public let original: Data
        public let replacement: Data
        public var alreadyPatched: Bool { original == replacement }
    }

    public static func prepare(chunks: DyldSharedCacheChunkSet) throws -> Prepared {
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        let address = try resolver.address(of: "_mach_ports_lookup", inImage: image)
        let message = try resolver.address(of: "_mach_msg2_internal", inImage: image)
        let allocate = try resolver.address(of: "_mach_vm_allocate", inImage: image)
        let selfPort = try resolver.address(of: "_mach_task_self_", inImage: image)
        let deallocateReply = try resolver.address(of: "_mig_dealloc_reply_port", inImage: image)
        let destroy = try resolver.address(of: "_mach_msg_destroy", inImage: image)
        let decoded = ARM64Disassembler().disassemble(try chunks.readAtVMA(address, length: 1024, allowShort: true), at: address)
        guard let end = decoded.firstIndex(where: { $0.isReturn }),
              let send = decoded[..<end].firstIndex(where: {
                  $0.mnemonic == "bl" && $0.detail?.operands.first?.imm == Int64(message)
              }) else { throw PatcherError.patchSiteNotFound("mach_ports_lookup: bounded MIG client not found") }
        let instructions = Array(decoded[...end])
        guard instructions.first?.mnemonic == "pacibsp", instructions.last?.mnemonic == "retab",
              instructions[1].mnemonic == "sub", let frame = instructions[1].detail?.operands.last?.imm,
              [0x70, 0x90].contains(frame), send < 40,
              let fpRestore = instructions.first(where: { isPair($0, "ldp", "x29", "x30", 0x60) }),
              let savedRestore = instructions.first(where: { isPair($0, "ldp", "x20", "x19", 0x50) }),
              let extraRestore = instructions.first(where: { isPair($0, "ldp", "x22", "x21", 0x40) })
        else { throw PatcherError.patchSiteNotFound("mach_ports_lookup: unsupported frame or register preservation") }
        let prefix = Array(instructions[...send])
        guard prefix.count > 9,
              isPair(prefix[2], "stp", "x22", "x21", frame == 0x70 ? 0x40 : 0x60),
              isPair(prefix[3], "stp", "x20", "x19", frame == 0x70 ? 0x50 : 0x70),
              isPair(prefix[4], "stp", "x29", "x30", frame == 0x70 ? 0x60 : 0x80),
              let receive = prefix.firstIndex(where: {
                  $0.mnemonic == "mov" && $0.detail?.operands.first?.reg.name == "w6" &&
                      [64, 80].contains($0.detail?.operands.last?.imm ?? -1)
              })
        else { throw PatcherError.patchSiteNotFound("mach_ports_lookup: unsupported receive buffer") }
        // Grow the reply area while preserving every saved register's
        // FP-relative location and the original compact-unwind description.
        // All PC-relative literals and calls stay at their original addresses.
        var code = Data(prefix.flatMap(\.bytes))
        func replace(_ index: Int, _ bytes: Data?) throws {
            guard let bytes else { throw PatcherError.patchVerificationFailed("mach ports encoding") }
            code.replaceSubrange(index * 4 ..< index * 4 + 4, with: bytes)
        }
        try replace(1, ARM64Encoder.encodeSubImm12(rd: 31, rn: 31, imm12: 0x90))
        try replace(2, ARM64Encoder.encodeStpX(rt1: 22, rt2: 21, rn: 31, offset: 0x60))
        try replace(3, ARM64Encoder.encodeStpX(rt1: 20, rt2: 19, rn: 31, offset: 0x70))
        try replace(4, ARM64Encoder.encodeStpX(rt1: 29, rt2: 30, rn: 31, offset: 0x80))
        try replace(5, ARM64Encoder.encodeAddImm12(rd: 29, rn: 31, imm12: 0x80))
        try replace(receive, ARM64Encoder.encodeMovzW(rd: 6, imm16: 80))

        var labels: [String: Int] = [:]
        var fixups: [(Int, String, (Int, Int) -> Data?)] = []
        func emit(_ bytes: Data?) throws {
            guard let bytes else { throw PatcherError.patchVerificationFailed("mach ports encoding") }
            code.append(bytes)
        }
        func label(_ name: String) { labels[name] = code.count }
        func jump(_ name: String, _ encoder: @escaping (Int, Int) -> Data?) {
            fixups.append((code.count, name, encoder)); code.append(ARM64.nop)
        }
        func b(_ name: String) { jump(name) { ARM64Encoder.encodeB(from: $0, to: $1) } }
        func cb(_ name: String, _ register: UInt32, _ nonzero: Bool = true, _ width64: Bool = false) {
            jump(name) { ARM64Encoder.encodeCompareBranch(nonzero: nonzero, register: register, from: $0, to: $1, width64: width64) }
        }
        func ne(_ name: String) { jump(name) { ARM64Encoder.encodeBCond(from: $0, to: $1, condition: .ne) } }
        func call(_ target: UInt64) throws { try emit(ARM64Encoder.encodeBL(from: Int(address) + code.count, to: Int(target))) }
        func lw(_ rt: UInt32, _ offset: UInt32, _ rn: UInt32 = 31) throws { try emit(ARM64Encoder.encodeLdrWUnsignedOffset(rt: rt, rn: rn, offset: offset)) }
        func sw(_ rt: UInt32, _ offset: UInt32, _ rn: UInt32) throws { try emit(ARM64Encoder.encodeStrWUnsignedOffset(rt: rt, rn: rn, offset: offset)) }
        func mov(_ rd: UInt32, _ imm: UInt16, _ shift: UInt32 = 0) throws { try emit(ARM64Encoder.encodeMovzW(rd: rd, imm16: imm, shift: shift)) }
        func cmp(_ reg: UInt32, _ imm: UInt32) throws { try emit(ARM64Encoder.encodeCmpWImmediate(rn: reg, imm12: imm)) }

        cb("transport", 0)
        try lw(8, 20); try cmp(8, 3504); ne("type")
        try lw(8, 0)
        jump("errorReply") { ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 31, from: $0, to: $1) }
        try lw(8, 4); try cmp(8, 64); ne("type")
        try lw(8, 24); try cmp(8, 3); ne("type")
        // A returned port descriptor has zero padding, disposition PORT_SEND,
        // and type PORT_DESCRIPTOR. All three rights must have this shape.
        try mov(9, 17, 16)
        for offset in [UInt32(36), 48, 60] {
            try lw(8, offset)
            try emit(ARM64Encoder.encodeAddSubXShifted(subtract: true, rd: 8, rn: 8, rm: 9))
            cb("type", 8, true, true)
        }
        // Reply + trailer occupy [sp, sp+80). Allocate the array through a
        // separate slot at sp+0x50, clear of saved registers and the reply.
        try emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 31, rn: 31, offset: 0x50))
        try emit(ARM64Encoder.encodeADRP(rd: 8, pc: address + UInt64(code.count), target: selfPort))
        try lw(0, UInt32(selfPort & 0xFFF), 8)
        try emit(ARM64Encoder.encodeAddImm12(rd: 1, rn: 31, imm12: 0x50))
        try mov(2, 12); try mov(3, 1); try call(allocate)
        cb("allocation", 0)
        try emit(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 9, rn: 31, offset: 0x50))
        for (index, offset) in [UInt32(28), 40, 52].enumerated() {
            try lw(8, offset); try sw(8, UInt32(index * 4), 9)
        }
        try emit(ARM64Encoder.encodeStrXUnsignedOffset(rt: 9, rn: 20, offset: 0))
        try mov(8, 3); try sw(8, 0, 19); try mov(21, 0); b("finish")
        label("errorReply")
        try lw(8, 4); try cmp(8, 36); ne("type")
        try lw(21, 32); cb("finish", 21)
        label("type")
        try mov(21, 300)
        try emit(ARM64Encoder.encodeAddSubXShifted(subtract: true, rd: 21, rn: 31, rm: 21))
        b("destroy")
        label("transport")
        try emit(ARM64Encoder.encodeMovX(rd: 21, rm: 0)); try lw(0, 12)
        try call(deallocateReply); b("finish")
        label("allocation")
        try emit(ARM64Encoder.encodeMovX(rd: 21, rm: 0))
        label("destroy")
        try emit(ARM64Encoder.encodeAddImm12(rd: 0, rn: 31, imm12: 0)); try call(destroy)
        label("finish")
        try emit(ARM64Encoder.encodeMovX(rd: 0, rm: 21))
        try emit(ARM64Encoder.encodeAddImm12(rd: 31, rn: 31, imm12: 0x20))
        try emit(Data(fpRestore.bytes)); try emit(Data(savedRestore.bytes))
        try emit(Data(extraRestore.bytes))
        try emit(ARM64Encoder.encodeAddImm12(rd: 31, rn: 31, imm12: 0x70))
        try emit(Data(instructions.last!.bytes))

        let original = Data(instructions.flatMap(\.bytes))
        guard code.count <= original.count else {
            throw PatcherError.patchVerificationFailed("mach_ports_lookup payload needs \(code.count), has \(original.count)")
        }
        for (offset, name, encoder) in fixups {
            guard let target = labels[name], let bytes = encoder(Int(address) + offset, Int(address) + target) else {
                throw PatcherError.patchVerificationFailed("mach ports branch \(name)")
            }
            code.replaceSubrange(offset ..< offset + 4, with: bytes)
        }
        while code.count < original.count { code.append(ARM64.nop) }
        if frame == 0x90, code != original { throw PatcherError.patchVerificationFailed("unknown previous mach ports implementation") }
        return Prepared(address: address, original: original, replacement: code)
    }

    private static func isPair(_ i: ARM64Instruction, _ mnemonic: String, _ first: String, _ second: String, _ offset: Int64) -> Bool {
        guard i.mnemonic == mnemonic, let ops = i.detail?.operands, ops.count == 3,
              ops[0].reg.name == first, ops[1].reg.name == second,
              ops[2].type == .memory, ops[2].mem.base.name == "sp", Int64(ops[2].mem.disp) == offset else { return false }
        return true
    }

    public static func apply(directory: URL, dryRun: Bool = false, captureUndo: Bool = false,
                             onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
                             log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog) throws {
        let chunks = try DyldSharedCacheChunkSet(directory: directory, captureUndo: captureUndo)
        defer { if captureUndo, let undo = chunks.takeUndoLog() { onUndo?(undo) } }
        let prepared = try prepare(chunks: chunks)
        log?("  [.] mach_ports_lookup @ 0x\(String(prepared.address, radix: 16)); inline-three-port client \(prepared.replacement.count) bytes")
        if prepared.alreadyPatched { log?("  [=] Mach ports lookup already compatible"); return }
        if dryRun { log?("  [.] dry run: no bytes written"); return }
        try chunks.write(at: prepared.address, prepared.replacement)
        try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: log)
        guard try chunks.bytesAtVMA(prepared.address, length: prepared.replacement.count) == prepared.replacement else {
            throw PatcherError.patchVerificationFailed("mach ports readback")
        }
        log?("  [+] Mach ports lookup compatibility installed")
    }
}
