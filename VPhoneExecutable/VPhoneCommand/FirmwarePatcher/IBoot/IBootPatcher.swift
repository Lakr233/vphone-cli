// IBootPatcher.swift — iBoot chain patcher (iBSS, iBEC, LLB).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
// Each patch mirrors Python logic exactly — no hardcoded offsets.
//
// Patch schedule by mode:
//   ibss — serial labels + image4 callback
//   ibec — serial labels + image4 callback + boot-args + bootx precondition (if present)
//   llb  — serial labels + image4 callback + boot-args + rootfs bypass (5 patches) + panic bypass
//
// Each patch method is defined as an extension in its own file under IBoot/Patches/.

import Capstone
import Foundation

/// Patcher for iBoot components (iBSS, iBEC, LLB).
public class IBootPatcher: Patcher {
    // MARK: - Types

    public enum Mode: String, Sendable {
        case ibss
        case ibec
        case llb
    }

    // MARK: - Constants

    /// Default custom boot-args string (Python: IBootPatcher.BOOT_ARGS)
    static let bootArgs = "serial=3 -v debug=0x2014e %s"

    /// Chunked disassembly parameters (Python: CHUNK_SIZE, OVERLAP)
    private static let chunkSize = 0x2000
    private static let chunkOverlap = 0x100

    // MARK: - Properties

    public let component: String
    public let verbose: Bool

    /// Extra boot-args token(s) inserted before the trailing `%s` in the
    /// patched boot-args (ibec/llb). Used to add `if_attach_nx=0x3` on iOS 18
    /// bases (disables the skywalk flowswitch netagents so Network.framework
    /// uses the BSD path; the 26.1-kernel skywalk channel-create traps in the
    /// 18.x Network.framework and crash-loops mDNSResponder → no DNS). Empty
    /// by default, so 26.x bases keep the stock boot-args.
    public var extraBootArgs: String = ""

    let buffer: BinaryBuffer
    let mode: Mode
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    // MARK: - Init

    public init(data: Data, mode: Mode, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.mode = mode
        component = mode.rawValue
        self.verbose = verbose
    }

    // MARK: - Patcher Protocol

    public func findAll() throws -> [PatchRecord] {
        patches = []

        patchSerialLabels()
        patchImage4Callback()

        switch mode {
        case .ibss:
            break
        case .ibec:
            patchBootArgs()
            patchBootxPrecondition()
        case .llb:
            patchBootArgs()
            patchRootfssBypass()
            patchPanicBypass()
        }

        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            let _ = try findAll()
        }
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) \(mode.rawValue) patches applied]")
        }
        return patches.count
    }

    /// Get the patched data.
    public var patchedData: Data {
        buffer.data
    }

    // MARK: - Emit Helpers

    /// Record a code patch (disassembles before/after for logging).
    func emit(_ offset: Int, _ patchBytes: Data, id: String, description: String) {
        let originalBytes = buffer.readBytes(at: offset, count: patchBytes.count)

        let beforeInsn = disasm.disassembleOne(in: buffer.original, at: offset)
        let afterInsn = disasm.disassembleOne(patchBytes, at: UInt64(offset))
        let beforeStr = beforeInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"

        let record = PatchRecord(
            patchID: id,
            component: component,
            fileOffset: offset,
            originalBytes: originalBytes,
            patchedBytes: patchBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: description,
        )
        patches.append(record)

        if verbose {
            print(String(format: "  0x%06X: %@ → %@  [%@]", offset, beforeStr, afterStr, description))
        }
    }

    /// Record a string/data patch (not disassemblable).
    func emitString(_ offset: Int, _ data: Data, id: String, description: String) {
        let originalBytes = buffer.readBytes(at: offset, count: data.count)
        let txt = String(data: data, encoding: .ascii) ?? data.hex

        let record = PatchRecord(
            patchID: id,
            component: component,
            fileOffset: offset,
            originalBytes: originalBytes,
            patchedBytes: data,
            beforeDisasm: "",
            afterDisasm: repr(txt),
            description: description,
        )
        patches.append(record)

        if verbose {
            print(String(format: "  0x%06X: → %@  [%@]", offset, repr(txt), description))
        }
    }

    private func repr(_ s: String) -> String {
        "\"\(s)\""
    }

    // MARK: - Pattern Search Helpers

    /// Encode `mov w8, #<imm16>` (MOVZ W8, #imm) as 4 little-endian bytes.
    /// MOVZ W encoding: [31]=0 sf, [30:29]=10, [28:23]=100101, [22:21]=hw=00,
    ///                   [20:5]=imm16, [4:0]=Rd=8
    func encodedMovW8(_ imm16: UInt32) -> Data {
        let insn: UInt32 = 0x5280_0000 | ((imm16 & 0xFFFF) << 5) | 8
        return withUnsafeBytes(of: insn.littleEndian) { Data($0) }
    }

    /// Encode `movk w8, #<imm16>, lsl #16` (MOVK W8, #imm, LSL #16).
    /// MOVK W: [31]=0, [30:29]=11, [28:23]=100101, [22:21]=hw=01,
    ///          [20:5]=imm16, [4:0]=Rd=8
    func encodedMovkW8Lsl16(_ imm16: UInt32) -> Data {
        let insn: UInt32 = 0x72A0_0000 | ((imm16 & 0xFFFF) << 5) | 8
        return withUnsafeBytes(of: insn.littleEndian) { Data($0) }
    }

    // MARK: - Chunked Disassembly

    /// Yield chunks of disassembled instructions over the whole binary.
    /// Mirrors Python `_chunked_disasm()` with CHUNK_SIZE=0x2000, OVERLAP=0x100.
    func chunkedDisasm() -> [[Instruction]] {
        let size = buffer.original.count
        var results: [[Instruction]] = []
        var off = 0
        while off < size {
            let end = min(off + IBootPatcher.chunkSize, size)
            let chunkLen = end - off
            let slice = buffer.original[off ..< off + chunkLen]
            let insns = disasm.disassemble(Data(slice), at: UInt64(off))
            results.append(insns)
            off += IBootPatcher.chunkSize - IBootPatcher.chunkOverlap
        }
        return results
    }
}
