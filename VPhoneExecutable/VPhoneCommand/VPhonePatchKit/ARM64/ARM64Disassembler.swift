// ARM64Disassembler.swift — Capstone-backed ARM64 disassembly.
//
// Capstone is an implementation detail of VPhonePatchKit. It is imported
// `internal`, so no Capstone type reaches the module interface: patch sets see
// only ``ARM64Instruction`` and never link a second copy of the disassembler.

internal import Capstone
import Foundation

public final class ARM64Disassembler: @unchecked Sendable {
    private var handle: csh = 0

    public init() {
        let status = cs_open(CS_ARCH_AARCH64, CS_MODE_LITTLE_ENDIAN, &handle)
        precondition(status == CS_ERR_OK, "Capstone could not open an AArch64 handle: \(status)")
        cs_option(handle, CS_OPT_DETAIL, numericCast(CS_OPT_ON.rawValue))
        cs_option(handle, CS_OPT_SKIPDATA, numericCast(CS_OPT_ON.rawValue))
    }

    deinit {
        cs_close(&handle)
    }

    /// Disassemble instructions from data starting at the given virtual address.
    ///
    /// - Parameters:
    ///   - data: Raw instruction bytes.
    ///   - address: Virtual address of the first byte.
    ///   - count: Maximum number of instructions to disassemble (0 = all).
    /// - Returns: Array of disassembled instructions.
    public func disassemble(_ data: Data, at address: UInt64 = 0, count: Int = 0) -> [ARM64Instruction] {
        let bytes = [UInt8](data)
        return bytes.withUnsafeBufferPointer { buffer in
            var raw: UnsafeMutablePointer<cs_insn>?
            let decoded = cs_disasm(handle, buffer.baseAddress, buffer.count, address, count, &raw)
            guard decoded > 0, let raw else { return [] }
            defer { cs_free(raw, decoded) }
            return (0 ..< decoded).map { ARM64Instruction(raw[$0]) }
        }
    }

    /// Disassemble a single 4-byte instruction at the given address.
    public func disassembleOne(_ data: Data, at address: UInt64 = 0) -> ARM64Instruction? {
        disassemble(data, at: address, count: 1).first
    }

    /// Disassemble a single instruction from a buffer at a file offset.
    public func disassembleOne(in buffer: Data, at offset: Int, address: UInt64? = nil) -> ARM64Instruction? {
        guard offset >= 0, offset + 4 <= buffer.count else { return nil }
        let slice = buffer[offset ..< offset + 4]
        let addr = address ?? UInt64(offset)
        return disassembleOne(Data(slice), at: addr)
    }

    /// Disassemble `count` instructions starting at file offset.
    public func disassemble(in buffer: Data, at offset: Int, count: Int, address: UInt64? = nil) -> [ARM64Instruction] {
        let byteCount = count * 4
        guard offset >= 0, offset + byteCount <= buffer.count else { return [] }
        let slice = buffer[offset ..< offset + byteCount]
        let addr = address ?? UInt64(offset)
        return disassemble(Data(slice), at: addr, count: count)
    }

    /// Canonical name of the instruction's first operand when it is a register
    /// (the write target for the moves/loads/branches the patchers match), else nil.
    ///
    /// Replaces the brittle `operandString.components(separatedBy: ",")` parsing that
    /// was duplicated across the CFW patch files to recover a destination register's
    /// width ("w…" vs "x…") and identity.
    public func firstRegisterName(_ insn: ARM64Instruction) -> String? {
        guard let first = insn.detail?.operands.first, first.type == .register else { return nil }
        return first.reg.name
    }

    /// True iff the instruction's first (destination) operand is the named register.
    public func writesRegister(_ insn: ARM64Instruction, named regName: String) -> Bool {
        firstRegisterName(insn) == regName
    }
}

// MARK: - Capstone Conversion

extension ARM64Instruction {
    init(_ raw: cs_insn) {
        let mnemonic = withUnsafeBytes(of: raw.mnemonic) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let operandString = withUnsafeBytes(of: raw.op_str) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let bytes = withUnsafeBytes(of: raw.bytes) { Array($0.prefix(Int(raw.size))) }

        var detail: ARM64InstructionDetail?
        var groups: [UInt8] = []
        if let rawDetail = raw.detail?.pointee {
            groups = withUnsafeBytes(of: rawDetail.groups) { buffer in
                Array(buffer.prefix(Int(rawDetail.groups_count)))
            }
            detail = ARM64InstructionDetail(rawDetail.aarch64, writeback: rawDetail.writeback)
        }

        self.init(
            isDecoded: raw.id != 0,
            address: raw.address,
            size: raw.size,
            bytes: bytes,
            mnemonic: mnemonic,
            operandString: operandString,
            detail: detail,
            isJump: groups.contains(UInt8(CS_GRP_JUMP.rawValue)),
            isCall: groups.contains(UInt8(CS_GRP_CALL.rawValue)),
            isReturn: groups.contains(UInt8(CS_GRP_RET.rawValue)),
        )
    }
}

extension ARM64InstructionDetail {
    init(_ raw: cs_aarch64, writeback: Bool) {
        let operands = withUnsafeBytes(of: raw.operands) { buffer in
            let pointer = buffer.baseAddress!.assumingMemoryBound(to: cs_aarch64_op.self)
            let capacity = buffer.count / MemoryLayout<cs_aarch64_op>.stride
            return (0 ..< min(Int(raw.op_count), capacity)).map { ARM64Operand(pointer[$0]) }
        }
        self.init(
            conditionCode: ARM64Condition(rawValue: raw.cc.rawValue),
            updatesFlags: raw.update_flags,
            postIndex: raw.post_index,
            operands: operands,
        )
        self.writeback = writeback
    }
}

extension ARM64Operand {
    init(_ raw: cs_aarch64_op) {
        let type: ARM64OperandType = switch raw.type {
        case AARCH64_OP_REG: .register
        case AARCH64_OP_IMM: .immediate
        case AARCH64_OP_MEM: .memory
        default: .other
        }
        self.init(
            type: type,
            reg: ARM64Register(rawValue: raw.reg.rawValue),
            imm: raw.imm,
            mem: ARM64MemoryOperand(
                base: ARM64Register(rawValue: raw.mem.base.rawValue),
                index: ARM64Register(rawValue: raw.mem.index.rawValue),
                disp: raw.mem.disp,
            ),
            shift: ARM64OperandShift(type: ARM64ShiftType(rawValue: raw.shift.type.rawValue) ?? .unsupported, amount: raw.shift.value),
        )
        self.writesRegister = raw.access.rawValue & CS_AC_WRITE.rawValue != 0
    }
}

// MARK: - Register Identity

public extension ARM64Register {
    static func b(_ number: Int) -> ARM64Register {
        precondition((0 ... 31).contains(number))
        return ARM64Register(rawValue: AARCH64_REG_B0.rawValue + UInt32(number))
    }

    static func h(_ number: Int) -> ARM64Register {
        precondition((0 ... 31).contains(number))
        return ARM64Register(rawValue: AARCH64_REG_H0.rawValue + UInt32(number))
    }

    static func s(_ number: Int) -> ARM64Register {
        precondition((0 ... 31).contains(number))
        return ARM64Register(rawValue: AARCH64_REG_S0.rawValue + UInt32(number))
    }

    static func d(_ number: Int) -> ARM64Register {
        precondition((0 ... 31).contains(number))
        return ARM64Register(rawValue: AARCH64_REG_D0.rawValue + UInt32(number))
    }

    static func q(_ number: Int) -> ARM64Register {
        precondition((0 ... 31).contains(number))
        return ARM64Register(rawValue: AARCH64_REG_Q0.rawValue + UInt32(number))
    }

    static let invalid = ARM64Register(rawValue: AARCH64_REG_INVALID.rawValue)
    static let sp = ARM64Register(rawValue: AARCH64_REG_SP.rawValue)
    static let wzr = ARM64Register(rawValue: AARCH64_REG_WZR.rawValue)
    static let xzr = ARM64Register(rawValue: AARCH64_REG_XZR.rawValue)

    /// The 64-bit general register `x<number>`; x29 and x30 are FP and LR.
    static func x(_ number: Int) -> ARM64Register {
        precondition((0 ... 30).contains(number), "x\(number) is not a general register")
        return switch number {
        case 29: ARM64Register(rawValue: AARCH64_REG_FP.rawValue)
        case 30: ARM64Register(rawValue: AARCH64_REG_LR.rawValue)
        default: ARM64Register(rawValue: AARCH64_REG_X0.rawValue + UInt32(number))
        }
    }

    /// The 32-bit general register `w<number>`.
    static func w(_ number: Int) -> ARM64Register {
        precondition((0 ... 30).contains(number), "w\(number) is not a general register")
        return ARM64Register(rawValue: AARCH64_REG_W0.rawValue + UInt32(number))
    }

    /// Canonical register name, such as "x0", "w1" or "wzr".
    var name: String? {
        guard let name = cs_reg_name(registerNameHandle, rawValue) else { return nil }
        return String(cString: name)
    }
}

/// Register names need a handle but no instruction state; one serves every lookup.
private let registerNameHandle: csh = {
    var handle: csh = 0
    let status = cs_open(CS_ARCH_AARCH64, CS_MODE_LITTLE_ENDIAN, &handle)
    precondition(status == CS_ERR_OK, "Capstone could not open an AArch64 handle: \(status)")
    return handle
}()
