// V201 dequeues a tick, then the compositor predicts presentation one tick
// later. Submission waits until that prediction before returning. Its small
// positive tail therefore reaches the next dequeue just after the current
// tick. Rounding that lateness upward skips another tick on every frame.
//
// Keep the current tick when less than one whole period late. The compositor
// still targets the next tick and retains all its rendering/presentation waits;
// genuinely missed whole periods still advance the IDs and timestamps.
// Native visionOS 26.4 wakeboardd only; the patch-set gate owns the release.

import Foundation
import VPhonePatchKit

public enum CustomFirmwareVisionOSFramePacing {
    public static let patchID = "system-wakeboard-exp-visionos_frame_pacing"
    static let dequeueSymbol = "_rt_v201_display_vsync_dequeue"
    static let statusSymbol = "_rt_v201_display_status"

    public enum Outcome: String, Sendable { case patched, wouldPatch, alreadyPatched }

    public struct Site: Sendable {
        public let virtualAddress: UInt64
        public let fileOffset: Int
        public let alreadyPatched: Bool
    }

    public struct Report: Sendable {
        public let outcome: Outcome
        public let site: Site
        public let records: [PatchRecord]
        public let rehashedSlots: [CustomFirmwareSlotRehash]
    }

    @discardableResult
    public static func patch(
        at url: URL, dryRun: Bool = false, log: ((String) -> Void)? = nil,
    ) throws -> Report {
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(&data, dryRun: dryRun, log: log)
        if report.outcome == .patched { try data.write(to: url) }
        return report
    }

    /// Resolve, encode and re-attest a private copy before changing the caller's
    /// bytes. A missing signature or changed instruction shape is a hard refusal.
    @discardableResult
    public static func patch(
        _ data: inout Data, dryRun: Bool = false, log: ((String) -> Void)? = nil,
    ) throws -> Report {
        var output = Data(data)
        let site = try locate(in: output)
        try validateSignature(in: output, covering: site.fileOffset)

        if site.alreadyPatched {
            let stale = try CustomFirmwareMachOCodeSignature.reattest(
                &output, modifiedOffsets: [site.fileOffset], dryRun: true,
            )
            guard stale.isEmpty else {
                throw PatcherError.patchVerificationFailed("V201 frame pacing has stale code-page hashes")
            }
            log?("  [.] wakeboardd frame pacing already uses complete missed periods")
            return Report(outcome: .alreadyPatched, site: site, records: [], rehashedSlots: [])
        }

        guard let replacement = ARM64Encoder.encodeFcvtzsXFromD(rd: 10, rn: 0) else {
            throw PatcherError.patchVerificationFailed("cannot encode V201 frame-pacing conversion")
        }
        let decoder = ARM64Disassembler()
        guard let decoded = decoder.disassembleOne(replacement, at: site.virtualAddress),
              registers(decoded, mnemonic: "fcvtzs", names: ["x10", "d0"])
        else { throw PatcherError.patchVerificationFailed("invalid V201 frame-pacing replacement") }

        let before = output.subdata(in: site.fileOffset..<site.fileOffset + 4)
        let record = PatchRecord(
            patchID: patchID, component: "wakeboardd", fileOffset: site.fileOffset,
            virtualAddress: site.virtualAddress, originalBytes: before, patchedBytes: replacement,
            beforeDisasm: "fcvtps x10, d0", afterDisasm: "fcvtzs x10, d0",
            description: "Count only complete missed V201 display periods",
        )
        output.replaceSubrange(site.fileOffset..<site.fileOffset + 4, with: replacement)
        let slots = try CustomFirmwareMachOCodeSignature.reattest(&output, modifiedOffsets: [site.fileOffset])
        guard !slots.isEmpty, try locate(in: output).alreadyPatched else {
            throw PatcherError.patchVerificationFailed("V201 frame-pacing write did not re-attest a code page")
        }
        log?("  [+] wakeboardd 0x\(String(site.fileOffset, radix: 16)): fcvtps x10, d0 -> fcvtzs x10, d0")
        for slot in slots { log?("      [+] re-attest: \(slot)") }
        if !dryRun { data = output }
        return Report(outcome: dryRun ? .wouldPatch : .patched, site: site, records: [record], rehashedSlots: slots)
    }

    // MARK: - In-image anchors

    static func locate(in data: Data) throws -> Site {
        func fail() -> PatcherError { .patchSiteNotFound("unexpected native V201 dequeue control flow") }
        guard let symbols = MachOSymbolTargets(data: data),
              let text = MachOParser.parseSections(from: data)["__TEXT,__text"],
              text.size <= UInt64(data.count), UInt64(text.fileOffset) <= UInt64(data.count) - text.size
        else { throw fail() }

        func exactSymbol(_ name: String) throws -> UInt64 {
            let matches = (0..<symbols.symbolCount).compactMap { index -> UInt64? in
                let entry = symbols.symbolOffset + index * 16
                guard data[entry + 4] & 0xEE == 0x0E,
                      symbols.symbolName(at: index) == name else { return nil }
                return data.loadLE(UInt64.self, at: entry + 8)
            }
            guard matches.count == 1, let value = matches.first else { throw fail() }
            return value
        }
        let start = try exactSymbol(dequeueSymbol), end = try exactSymbol(statusSymbol)
        guard start >= text.address, start % 4 == 0, end > start, end - start <= 4096,
              end - text.address <= text.size else { throw fail() }
        let base = Int(text.fileOffset) + Int(start - text.address)
        let body = data.subdata(in: base..<base + Int(end - start))
        let code = ARM64Disassembler().disassemble(body, at: start)
        guard code.count * 4 == body.count,
              code.allSatisfy({ $0.isDecoded && $0.size == 4 }) else { throw fail() }

        var matches: [Site] = []
        for i in code.indices where i >= 7 && i + 9 < code.count {
            let conversion = code[i]
            guard ["fcvtps", "fcvtzs"].contains(conversion.mnemonic),
                  registers(conversion, mnemonic: conversion.mnemonic, names: ["x10", "d0"])
            else { continue }
            // The positive-lateness branch must skip directly to this function's
            // mach_wait_until. Both timestamps and both ID counters use the
            // converted period count below, so the instruction cannot be an
            // unrelated floating-point conversion elsewhere in the image.
            let branch = code[i - 5], wait = code[i + 9]
            guard memory(code[i - 7], mnemonic: "ldr", registers: ["x0"], base: "x20", offset: 0xE8),
                  registers(code[i - 6], mnemonic: "subs", names: ["x8", "x8", "x0"]),
                  branch.mnemonic == "b.ls", branch.detail?.conditionCode == .ls,
                  immediate(branch) == Int64(wait.address),
                  registers(code[i - 4], mnemonic: "scvtf", names: ["d0", "x8"]),
                  memory(code[i - 3], mnemonic: "ldp", registers: ["x9", "x8"], base: "x20", offset: 0xF0),
                  registers(code[i - 2], mnemonic: "scvtf", names: ["d1", "x8"]),
                  registers(code[i - 1], mnemonic: "fdiv", names: ["d0", "d0", "d1"]),
                  registers(code[i + 1], mnemonic: "dup", names: ["q0", "x10"]),
                  registers(code[i + 2], mnemonic: "mul", names: ["x8", "x8", "x10"]),
                  memory(code[i + 3], mnemonic: "ldur", registers: ["q1"], base: "x20", offset: 0xD8),
                  registers(code[i + 4], mnemonic: "add", names: ["q0", "q1", "q0"]),
                  memory(code[i + 5], mnemonic: "stur", registers: ["q0"], base: "x20", offset: 0xD8),
                  registers(code[i + 6], mnemonic: "add", names: ["x0", "x8", "x0"]),
                  registers(code[i + 7], mnemonic: "add", names: ["x8", "x9", "x8"]),
                  memory(code[i + 8], mnemonic: "stp", registers: ["x0", "x8"], base: "x20", offset: 0xE8),
                  wait.mnemonic == "bl", let target = immediate(wait), target >= 0,
                  symbols.name(forBranchTarget: UInt64(target)) == "_mach_wait_until"
            else { throw fail() }
            matches.append(Site(
                virtualAddress: conversion.address, fileOffset: base + i * 4,
                alreadyPatched: conversion.mnemonic == "fcvtzs",
            ))
        }
        guard matches.count == 1, let site = matches.first else { throw fail() }
        return site
    }

    static func validateSignature(in data: Data, covering offset: Int) throws {
        guard let directories = CustomFirmwareMachOCodeSignature.codeDirectories(in: data), !directories.isEmpty,
              directories.allSatisfy({ directory in
                  directory.hashType == CustomFirmwareMachOCodeSignature.hashTypeSHA256
                      && directory.hashSize == 32 && directory.codeLimit >= offset + 4
                      && directory.slotRange(offset / directory.pageSize)?.contains(offset + 3) == true
              }) else {
            throw PatcherError.patchVerificationFailed("V201 frame pacing requires covering SHA-256 code directories")
        }
    }

    static func registers(_ instruction: ARM64Instruction, mnemonic: String, names: [String]) -> Bool {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands,
              operands.count == names.count else { return false }
        return zip(operands, names).allSatisfy { $0.type == .register && $0.reg.name == $1 }
    }

    static func memory(
        _ instruction: ARM64Instruction, mnemonic: String, registers names: [String], base: String, offset: Int32,
    ) -> Bool {
        guard instruction.mnemonic == mnemonic, let detail = instruction.detail,
              detail.operands.count == names.count + 1, !detail.writeback
        else { return false }
        let operands = detail.operands
        guard
              zip(operands.prefix(names.count), names).allSatisfy({ $0.type == .register && $0.reg.name == $1 }),
              let operand = operands.last, operand.type == .memory
        else { return false }
        return operand.mem.base.name == base && operand.mem.index == .invalid && operand.mem.disp == offset
    }

    static func immediate(_ instruction: ARM64Instruction) -> Int64? {
        guard let operands = instruction.detail?.operands, operands.count == 1,
              operands[0].type == .immediate else { return nil }
        return operands[0].imm
    }
}
