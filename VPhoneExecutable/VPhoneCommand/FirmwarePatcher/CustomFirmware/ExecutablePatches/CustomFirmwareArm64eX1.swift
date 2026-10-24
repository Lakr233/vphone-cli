// Static ARM64E_X1 lowering for the pre-handler and fork-sensitive boot closure.

import Foundation
import os
import MachO
import VPhonePatchKit

public enum CustomFirmwareArm64eX1 {
    public struct Result: Sendable {
        public let records: [PatchRecord]
        public let unvisitedCandidates: Int
        public let unvisitedExamples: [Int]

        init(records: [PatchRecord], unvisitedCandidates: Int, unvisitedExamples: [Int] = []) {
            self.records = records; self.unvisitedCandidates = unvisitedCandidates; self.unvisitedExamples = unvisitedExamples
        }
    }

    private static let loweredMnemonics: Set<String> = [
        "pacibsppc", "paciasppc", "pacnbibsppc", "pacnbiasppc",
        "autibsppc", "autiasppc", "autibsppcr", "autiasppcr",
        "retabsppc", "retaasppc", "retabsppcr", "retaasppcr", "addpt", "subpt", "maddpt", "msubpt",
        "autia171615", "autib171615",
    ]

    /// Top bytes of every word `VPhoneArm64eX1Lowering` lowers or refuses.
    static let loweredTopBytes = topByteTable([0x44, 0x55, 0x9A, 0x9B, 0xD6, 0xDA, 0xF3])

    /// Top bytes of every word the walk follows or stops at: B, BL, B.cond,
    /// CBZ/CBNZ/TBZ/TBNZ, BR and its authenticated forms, the RET family,
    /// BRK, HLT and UDF.
    static let flowTopBytes = topByteTable([
        0x00, 0x14, 0x15, 0x16, 0x17, 0x34, 0x35, 0x36, 0x37, 0x54, 0x55,
        0x94, 0x95, 0x96, 0x97, 0xB4, 0xB5, 0xB6, 0xB7, 0xD4, 0xD6, 0xD7,
    ])

    private static func topByteTable(_ bytes: Set<UInt8>) -> [Bool] {
        (0 ... 255).map { bytes.contains(UInt8($0)) }
    }

    /// Encodings whose operands depend on the instruction's address: immediate
    /// branches, compare-and-branch, ADR/ADRP, literal loads, and the labelled
    /// PAuth_LR return and authenticate forms (top bytes 0x55 and 0xF3).
    static func isPCRelative(_ word: UInt32) -> Bool {
        word & 0x7C00_0000 == 0x1400_0000 || // B, BL
            word >> 24 == 0x54 || // B.cond, BC.cond
            word & 0x7C00_0000 == 0x3400_0000 || // CBZ, CBNZ, TBZ, TBNZ
            word & 0x7E00_0000 == 0x7400_0000 || // CB<cc>
            word & 0x1F00_0000 == 0x1000_0000 || // ADR, ADRP
            word & 0x3B00_0000 == 0x1800_0000 || // LDR, LDRSW, PRFM (literal)
            word >> 24 == 0x55 || word >> 24 == 0xF3
    }

    /// How a PC-relative decode follows its word to another address: not at
    /// all, its target operand by the address delta, or by the page delta.
    enum Move: CaseIterable { case none, address, page }

    /// The PC-relative families whose target the encoding states outright:
    /// the word with its offset field cleared, and the target it names at
    /// `address`. Two words of one family decode alike but for that target.
    static func targetFamily(_ word: UInt32, at address: Int) -> (key: UInt32, target: Int64)? {
        func signed(_ value: UInt32, bits: Int) -> Int64 {
            Int64(Int32(bitPattern: value << UInt32(32 - bits)) >> Int32(32 - bits))
        }
        let pc = Int64(address)
        if word & 0x7C00_0000 == 0x1400_0000 { // B, BL
            return (word & 0xFC00_0000, pc + signed(word & 0x03FF_FFFF, bits: 26) * 4)
        }
        if word >> 24 == 0x54 || word & 0x7E00_0000 == 0x3400_0000 || word & 0x3B00_0000 == 0x1800_0000 {
            // B.cond, BC.cond, CBZ, CBNZ, LDR/LDRSW/PRFM (literal): imm19.
            return (word & 0xFF00_001F, pc + signed((word >> 5) & 0x7FFFF, bits: 19) * 4)
        }
        if word & 0x7E00_0000 == 0x3600_0000 { // TBZ, TBNZ: imm14
            return (word & 0xFFF8_001F, pc + signed((word >> 5) & 0x3FFF, bits: 14) * 4)
        }
        if word & 0x1F00_0000 == 0x1000_0000 { // ADR, ADRP
            let immediate = signed(((word >> 5) & 0x7FFFF) << 2 | (word >> 29) & 3, bits: 21)
            return word >> 31 == 0
                ? (word & 0x9F00_001F, pc + immediate)
                : (word & 0x9F00_001F, (pc & ~0xFFF) + immediate << 12)
        }
        return nil
    }

    /// `item` as Capstone would decode it at `address` under `move`, or nil
    /// when its shape is not one a move can rebuild exactly: a last immediate
    /// operand that ends the operand text, and no flags a rebuild would drop.
    static func moved(_ item: ARM64Instruction, by move: Move, to address: Int) -> ARM64Instruction? {
        guard move != .none else {
            return ARM64Instruction(isDecoded: item.isDecoded, address: UInt64(address), size: item.size,
                bytes: item.bytes, mnemonic: item.mnemonic, operandString: item.operandString,
                detail: item.detail, isJump: item.isJump, isCall: item.isCall, isReturn: item.isReturn)
        }
        let from = Int64(item.address), to = Int64(address)
        let delta = move == .page ? (to & ~0xFFF) - (from & ~0xFFF) : to - from
        return retargeted(item, bytes: item.bytes, to: address, delta: delta)
    }

    /// `String(value, radix: 16)` for a non-negative value, without the generic
    /// formatting path that showed in profiles of a whole-cache run.
    static func hex(_ value: Int64) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var number = UInt64(value), buffer = [UInt8](repeating: 0, count: 16), index = 16
        repeat {
            index -= 1
            buffer[index] = digits[Int(number & 15)]
            number >>= 4
        } while number != 0
        return String(decoding: buffer[index...], as: UTF8.self)
    }

    /// `item` at `address` with `bytes`, its target operand shifted by `delta`;
    /// nil unless the target is a last immediate operand that ends the operand
    /// text and no flag a rebuild would drop is set.
    static func retargeted(_ item: ARM64Instruction, bytes: [UInt8], to address: Int, delta: Int64) -> ARM64Instruction? {
        guard let detail = item.detail, !detail.writeback, let last = detail.operands.last,
              last.type == .immediate, !last.writesRegister, last.imm >= 0,
              case let old = hex(last.imm), item.operandString.hasSuffix("0x" + old)
        else { return nil }
        let (target, overflow) = last.imm.addingReportingOverflow(delta)
        guard !overflow, target >= 0 else { return nil }
        let text = item.operandString.dropLast(old.utf8.count) + hex(target)
        // Capstone's operand is a union: an immediate's register and memory
        // views alias its low and high words, and the decode copies them all.
        let low = ARM64Register(rawValue: UInt32(truncatingIfNeeded: target))
        let high = ARM64Register(rawValue: UInt32(truncatingIfNeeded: target >> 32))
        let operands = detail.operands.dropLast() + [ARM64Operand(
            type: .immediate, reg: low, imm: target,
            mem: ARM64MemoryOperand(base: low, index: high, disp: last.mem.disp), shift: last.shift,
        )]
        return ARM64Instruction(isDecoded: item.isDecoded, address: UInt64(address), size: item.size,
            bytes: bytes, mnemonic: item.mnemonic, operandString: String(text),
            detail: ARM64InstructionDetail(conditionCode: detail.conditionCode, updatesFlags: detail.updatesFlags,
                                           postIndex: detail.postIndex, operands: Array(operands)),
            isJump: item.isJump, isCall: item.isCall, isReturn: item.isReturn)
    }

    /// Every field the planner and its callers read, compared exactly.
    static func sameDecode(_ lhs: ARM64Instruction, _ rhs: ARM64Instruction) -> Bool {
        guard lhs.isDecoded == rhs.isDecoded, lhs.address == rhs.address, lhs.size == rhs.size,
              lhs.bytes == rhs.bytes, lhs.mnemonic == rhs.mnemonic, lhs.operandString == rhs.operandString,
              lhs.isJump == rhs.isJump, lhs.isCall == rhs.isCall, lhs.isReturn == rhs.isReturn
        else { return false }
        guard let left = lhs.detail, let right = rhs.detail else { return lhs.detail == nil && rhs.detail == nil }
        return left.conditionCode == right.conditionCode && left.updatesFlags == right.updatesFlags &&
            left.postIndex == right.postIndex && left.writeback == right.writeback &&
            left.operands.count == right.operands.count &&
            zip(left.operands, right.operands).allSatisfy { a, b in
                a.type == b.type && a.reg == b.reg && a.imm == b.imm && a.writesRegister == b.writesRegister &&
                    a.mem.base == b.mem.base && a.mem.index == b.mem.index && a.mem.disp == b.mem.disp &&
                    a.shift.type == b.shift.type && a.shift.amount == b.shift.amount
            }
    }

    public static func lower(_ data: inout Data) throws -> Result {
        try lower(&data, identifier: FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap)
    }

    public static func lower(_ data: inout Data, identifier: String) throws -> Result {
        if isUniversal(data) { return try lowerUniversal(&data, identifier: identifier, reattest: false).result }
        guard data.count >= 32, data.loadLE(UInt32.self, at: 0) == 0xFEED_FACF,
              data.loadLE(UInt32.self, at: 4) == 0x0100_000C,
              data.loadLE(UInt32.self, at: 8) & 0x00FF_FFFF == 12,
              data.loadLE(UInt32.self, at: 12) != UInt32(MH_KEXT_BUNDLE)
        else { return Result(records: [], unvisitedCandidates: 0) }
        let segments = MachOParser.parseSegments(from: data)
        let sections = MachOParser.parseSections(from: data).values.filter {
            $0.size > 0 && ($0.sectionName == "__text" || $0.flags & 0x8000_0400 != 0)
        }
        guard !sections.isEmpty else { return Result(records: [], unvisitedCandidates: 0) }
        var (seeds, excluded) = try entryPoints(data, segments: segments)
        func fileOffset(_ address: UInt64, length: Int) throws -> Int {
            guard let segment = segments.first(where: {
                address >= $0.vmAddr && address - $0.vmAddr <= $0.fileSize &&
                UInt64(length) <= $0.fileSize - (address - $0.vmAddr)
            }), let offset = Int(exactly: segment.fileOffset + address - segment.vmAddr),
                  offset <= data.count, length <= data.count - offset else {
                throw PatcherError.invalidFormat("X1 exception metadata outside Mach-O")
            }
            return offset
        }
        if let text = segments.first(where: { $0.name == "__TEXT" }) {
            let exceptionVMAs = try exceptionEntries(sections: Array(MachOParser.parseSections(from: data).values),
                imageBase: text.vmAddr, readMemory: { address, length in
                    let offset = try fileOffset(address, length: length)
                    return data.subdata(in: offset ..< offset + length)
                })
            seeds += try exceptionVMAs.map { try fileOffset($0, length: 4) }
        }
        guard !seeds.isEmpty else {
            throw PatcherError.invalidFormat("X1 lowering requires function starts and executable text")
        }
        var ranges: [(address: Int, data: Data)] = []
        for section in sections {
            guard let start = Int(exactly: section.fileOffset),
                  let size = Int(exactly: section.size),
                  start <= data.count, size <= data.count - start else {
                throw PatcherError.invalidFormat("X1 text outside Mach-O")
            }
            ranges.append((start, data.subdata(in: start ..< start + size)))
        }
        let original = data
        let result = try planCode(ranges: ranges, seeds: seeds, excluded: excluded,
                                  identifier: identifier, readMemory: { address, length in
            guard address <= original.count, length <= original.count - address else {
                throw PatcherError.invalidFormat("X1 switch table outside image")
            }
            return original.subdata(in: address ..< address + length)
        })
        for record in result.records { data.replaceSubrange(record.fileOffset ..< record.fileOffset + 4, with: record.patchedBytes) }
        return result
    }

    static func planCode(ranges: [(address: Int, data: Data)], seeds: [Int], excluded: [Range<Int>], identifier: String,
                         readMemory: ((Int, Int) throws -> Data)? = nil,
                         authenticatedPointer: ((UInt64, UInt16) throws -> UInt64?)? = nil,
                         decoder words: Decoder = Decoder()) throws -> Result {
        let decoder = words.capstone
        func decode(_ word: UInt32, at address: Int) -> ARM64Instruction? { words.decode(word, at: address) }
        // Unpacked once: a generic load per word crosses PatchKit's resilient
        // boundary and costs a metadata lookup on every call.
        let rangeWords: [[UInt32]] = ranges.map { range in
            range.data.withUnsafeBytes { raw in
                (0 ..< raw.count / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
            }
        }
        // Data inside the code, as one bit per word: a linear scan of the ranges
        // on every step went quadratic in images with many switch tables.
        var dataWords = AddressSet(ranges: ranges.map { ($0.address, $0.data.count) })
        for span in excluded { dataWords.insertWords(in: span) }
        var candidates: [Int] = [], frameEntries: [Int] = []
        // Recover coalesced entries from return-PAC plus an SP frame setup.
        for (range, words) in zip(ranges, rangeWords) {
            for index in 0 ..< words.count {
                // Every lowered form and PAC prologue has one of these top
                // bytes; Capstone still decides, but only for words that could
                // match, which keeps a whole-cache scan affordable.
                switch words[index] >> 24 {
                case 0x55, 0x9A, 0x9B, 0xD5, 0xD6, 0xDA, 0xF3: break
                default: continue
                }
                let address = range.address + index * 4
                guard !excluded.contains(where: { $0.contains(address) }),
                      let item = decode(words[index], at: address)
                else { continue }
                if loweredMnemonics.contains(item.mnemonic) { candidates.append(address) }
                if ["pacibsppc", "paciasppc", "pacnbibsppc", "pacnbiasppc", "pacibsp", "paciasp"].contains(item.mnemonic), index + 1 < words.count,
                   let next = decode(words[index + 1], at: address + 4) {
                    let ops = next.detail?.operands ?? []
                    let savesFrame = ["stp", "str"].contains(next.mnemonic) && ops.last?.type == .memory && ops.last?.mem.base == .sp
                    let allocatesFrame = next.mnemonic == "sub" && ops.count == 3 && ops[0].reg == .sp && ops[1].reg == .sp && ops[2].type == .immediate
                    if savesFrame || allocatesFrame { frameEntries.append(address) }
                }
            }
        }
        // SKIPDATA gives every word its own 4-byte entry, so one word decodes
        // exactly as it would inside its page. Decoding whole pages behind a
        // small cache thrashed on large cache images, whose traversal jumps
        // between distant pages.
        func word(at address: Int) -> UInt32? {
            guard address & 3 == 0, !dataWords.contains(address),
                  let index = ranges.firstIndex(where: { address >= $0.address && address + 4 <= $0.address + $0.data.count }) else { return nil }
            return rangeWords[index][(address - ranges[index].address) / 4]
        }
        func decodedInstruction(at address: Int) -> ARM64Instruction? {
            word(at: address).flatMap { decode($0, at: address) }
        }
        var scheduled = AddressSet(ranges: ranges.map { ($0.address, $0.data.count) }), visited = scheduled
        var pending = Set(seeds + frameEntries).sorted(by: >)
        for entry in pending { _ = scheduled.insert(entry) }
        func schedule(_ address: Int) {
            if !visited.contains(address), scheduled.insert(address).inserted {
                pending.append(address)
            }
        }
        var records: [PatchRecord] = []
        while let entry = pending.popLast() {
            var offset = entry
            while visited.insert(offset).inserted, let word = word(at: offset) {
                // The top byte rules out most words before any mnemonic is
                // compared: only these can be lowered or refused, or end or
                // redirect the walk. Any other word only has to decode.
                let top = Int(word >> 24)
                guard Self.loweredTopBytes[top] || Self.flowTopBytes[top] else {
                    guard words.decodes(word) else { break }
                    offset += 4
                    continue
                }
                guard let instruction = decode(word, at: offset), instruction.isDecoded, instruction.size == 4 else { break }
                if Self.loweredTopBytes[top], let replacement = try replacement(for: instruction) {
                    // A few dozen replacement words recur millions of times
                    // across a cache; the word cache answers for them.
                    let after = replacement.count == 4
                        ? decode(replacement.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) },
                                 at: offset)
                        : decoder.disassembleOne(replacement, at: instruction.address)
                    records.append(PatchRecord(patchID: identifier + ".\(offset)", component: "Mach-O", fileOffset: offset,
                        originalBytes: Data(instruction.bytes), patchedBytes: replacement,
                        beforeDisasm: "\(instruction.mnemonic) \(instruction.operandString)",
                        afterDisasm: "\(after?.mnemonic ?? "?") \(after?.operandString ?? "")",
                        description: "X1 compatibility lowering; PC PAC/CPA checks reduced"))
                }
                guard Self.flowTopBytes[top] else {
                    offset += 4
                    continue
                }
                let mnemonic = instruction.mnemonic
                if mnemonic == "br", let readMemory,
                   let table = try switchTable(at: offset, instructionAt: decodedInstruction(at:), readMemory: readMemory) {
                    dataWords.insertWords(in: table.data)
                    for target in table.targets { schedule(target) }
                }
                if mnemonic == "braa", let authenticatedPointer,
                   let table = try authenticatedDispatch(at: offset, instructionAt: decodedInstruction(at:),
                                                         pointer: authenticatedPointer) {
                    dataWords.insertWords(in: table.data)
                    for target in table.targets {
                        guard decodedInstruction(at: target)?.isDecoded == true else {
                            throw PatcherError.invalidFormat("authenticated X1 dispatch target outside executable code")
                        }
                        schedule(target)
                    }
                }
                if mnemonic == "b" || mnemonic == "bl" || mnemonic.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) {
                    if let target = instruction.detail?.operands.last, target.type == .immediate,
                       let destination = Int(exactly: target.imm) {
                        schedule(destination)
                    }
                    if mnemonic == "b" { break }
                }
                if instruction.isReturn || mnemonic.hasPrefix("ret") ||
                    ["br", "braa", "brab", "braaz", "brabz", "brk", "hlt", "udf"].contains(mnemonic) { break }
                offset += 4
            }
        }
        records.removeAll { dataWords.contains($0.fileOffset) }
        let unvisited = candidates.filter { address in !visited.contains(address) && !dataWords.contains(address) }
        records.sort { $0.fileOffset < $1.fileOffset }
        return Result(records: records, unvisitedCandidates: unvisited.count, unvisitedExamples: Array(unvisited.prefix(16)))
    }

    static func exceptionEntries(sections: [MachOSectionInfo], imageBase: UInt64,
                                 readMemory: (UInt64, Int) throws -> Data) throws -> [UInt64] {
        guard let unwind = sections.first(where: { $0.sectionName == "__unwind_info" && $0.size > 0 }) else { return [] }
        let bytes = try readMemory(unwind.address, Int(unwind.size))
        guard bytes.count >= 28, bytes.loadLE(UInt32.self, at: 0) == 1 else {
            throw PatcherError.invalidFormat("invalid X1 compact unwind header")
        }
        let index = Int(bytes.loadLE(UInt32.self, at: 20)), count = Int(bytes.loadLE(UInt32.self, at: 24))
        guard index <= bytes.count, count <= (bytes.count - index) / 12 else {
            throw PatcherError.invalidFormat("X1 unwind index outside section")
        }
        guard count > 1 else { return [] }
        var entries: [(function: UInt64, lsda: UInt64)] = []
        for page in 0 ..< count - 1 {
            let start = Int(bytes.loadLE(UInt32.self, at: index + page * 12 + 8))
            let end = Int(bytes.loadLE(UInt32.self, at: index + (page + 1) * 12 + 8))
            guard start <= end, end <= bytes.count, (end - start) % 8 == 0 else {
                throw PatcherError.invalidFormat("invalid X1 LSDA index range")
            }
            for offset in stride(from: start, to: end, by: 8) {
                let (function, fOverflow) = imageBase.addingReportingOverflow(UInt64(bytes.loadLE(UInt32.self, at: offset)))
                let (lsda, lOverflow) = imageBase.addingReportingOverflow(UInt64(bytes.loadLE(UInt32.self, at: offset + 4)))
                guard !fOverflow, !lOverflow else { throw PatcherError.invalidFormat("X1 LSDA address overflow") }
                entries.append((function, lsda))
            }
        }
        guard !entries.isEmpty else { return [] }
        let executable = sections.filter { $0.sectionName == "__text" || $0.flags & 0x8000_0400 != 0 }
        let addresses = Set(entries.map(\.lsda)).sorted()
        let following = Dictionary(uniqueKeysWithValues: zip(addresses, addresses.dropFirst()))
        var result = Set<UInt64>()
        for entry in entries {
            guard let section = sections.first(where: {
                $0.sectionName == "__gcc_except_tab" && entry.lsda >= $0.address && entry.lsda - $0.address < $0.size
            }) else { throw PatcherError.invalidFormat("X1 LSDA outside exception section") }
            let remaining = Int(section.size - (entry.lsda - section.address))
            let next = following[entry.lsda]
            let length = min(remaining, next.map { Int($0 - entry.lsda) } ?? remaining)
            let lsda = try readMemory(entry.lsda, length)
            var cursor = 0
            func byte() throws -> UInt8 {
                guard cursor < lsda.count else { throw PatcherError.invalidFormat("truncated X1 LSDA") }
                defer { cursor += 1 }
                return lsda[cursor]
            }
            func uleb() throws -> UInt64 {
                var value: UInt64 = 0, shift: UInt64 = 0
                while true {
                    let part = try byte()
                    guard shift < 64, shift < 63 || part & 0x7F <= 1 else { throw PatcherError.invalidFormat("X1 LSDA ULEB overflow") }
                    value |= UInt64(part & 0x7F) << shift
                    if part & 0x80 == 0 { return value }
                    shift += 7
                }
            }
            // Apple AArch64 LSDAs use the function start and ULEB call-site offsets.
            guard try byte() == 0xFF else { throw PatcherError.invalidFormat("unsupported X1 LSDA landing base") }
            if try byte() != 0xFF { _ = try uleb() }
            guard try byte() == 1 else { throw PatcherError.invalidFormat("unsupported X1 LSDA call-site encoding") }
            let tableLength = try uleb()
            guard tableLength <= lsda.count - cursor else { throw PatcherError.invalidFormat("X1 LSDA call-site table outside section") }
            let end = cursor + Int(tableLength)
            while cursor < end {
                _ = try uleb() // protected start
                _ = try uleb() // protected length
                let landing = try uleb()
                _ = try uleb() // action-table index
                guard cursor <= end else { throw PatcherError.invalidFormat("X1 LSDA call-site entry crosses table") }
                if landing != 0 {
                    let (target, overflow) = entry.function.addingReportingOverflow(landing)
                    guard !overflow, target & 3 == 0, executable.contains(where: {
                        target >= $0.address && target - $0.address < $0.size
                    }) else { throw PatcherError.invalidFormat("X1 exception landing outside executable section") }
                    result.insert(target)
                }
            }
        }
        return result.sorted()
    }

    private static func authenticatedDispatch(at branch: Int, instructionAt: (Int) -> ARM64Instruction?,
                                              pointer: (UInt64, UInt16) throws -> UInt64?) throws -> (targets: [Int], data: Range<Int>)? {
        guard let jump = instructionAt(branch), jump.mnemonic == "braa",
              let j = jump.detail?.operands, j.count == 2,
              let modifier = instructionAt(branch - 4), modifier.mnemonic == "mov",
              let m = modifier.detail?.operands, m.count == 2, m[0].reg == j[1].reg,
              m[1].type == .immediate, (0 ... 65535).contains(m[1].imm) else { return nil }
        func aliases(_ lhs: ARM64Register, _ rhs: ARM64Register) -> Bool {
            if lhs == rhs { return true }
            return (0 ... 30).contains { (lhs == .x($0) && rhs == .w($0)) || (lhs == .w($0) && rhs == .x($0)) }
        }
        func writes(_ instruction: ARM64Instruction, _ register: ARM64Register) -> Bool {
            let ops = instruction.detail?.operands ?? []
            return ops.contains { $0.type == .register && $0.writesRegister && aliases($0.reg, register) }
                || (instruction.detail?.writeback == true && ops.contains { $0.type == .memory && aliases($0.mem.base, register) })
        }
        var loadAddress = branch - 8
        if let extra = instructionAt(loadAddress), ["mov", "ldr"].contains(extra.mnemonic),
           !writes(extra, j[0].reg), !writes(extra, j[1].reg) {
            loadAddress -= 4
        }
        guard let load = instructionAt(loadAddress), load.mnemonic == "ldr",
              let l = load.detail?.operands, l.count == 2, l[0].reg == j[0].reg,
              l[1].type == .memory, l[1].shift.type == .lsl, l[1].shift.amount == 3,
              l[1].mem.disp == 0, !aliases(l[1].mem.base, l[1].mem.index) else { return nil }
        var hasByteTag = false
        for distance in 1 ... 4 {
            guard let instruction = instructionAt(loadAddress - distance * 4) else { break }
            let o = instruction.detail?.operands ?? []
            if instruction.mnemonic == "lsr", o.count == 2, o[0].reg == l[1].mem.index,
               o[1].type == .register, o[1].shift.type == .lsr, o[1].shift.amount == 56 {
                hasByteTag = true
                break
            }
            if writes(instruction, l[1].mem.index) || instruction.isCall || instruction.isJump || instruction.isReturn { break }
        }
        guard hasByteTag else { return nil }
        var table: UInt64?
        let base = l[1].mem.base
        let calleeSaved = (19 ... 28).contains { base == .x($0) }
        for distance in 1 ... 64 {
            let address = loadAddress - distance * 4
            guard let instruction = instructionAt(address) else { break }
            if instruction.isReturn || ["brk", "hlt", "udf"].contains(instruction.mnemonic) { break }
            if instruction.isCall && !calleeSaved { break }
            guard writes(instruction, base) else { continue }
            let o = instruction.detail?.operands ?? []
            guard instruction.mnemonic == "add", o.count == 3, o[0].reg == base, o[1].reg == base,
                  o[2].type == .immediate, o[2].imm >= 0, o[2].shift.amount == 0,
                  let page = instructionAt(address - 4), page.mnemonic == "adrp",
                  let p = page.detail?.operands, p.count == 2, p[0].reg == base, p[1].type == .immediate else { break }
            let (value, overflow) = p[1].imm.addingReportingOverflow(o[2].imm)
            if !overflow { table = UInt64(exactly: value) }
            break
        }
        guard let table, table & 7 == 0 else { return nil }
        var targets: [Int] = []
        for index in 0 ..< 256 {
            let (entry, overflow) = table.addingReportingOverflow(UInt64(index * 8))
            guard !overflow else { throw PatcherError.invalidFormat("X1 dispatch table overflow") }
            guard let target = try pointer(entry, UInt16(m[1].imm)) else { break }
            guard target & 3 == 0, let target = Int(exactly: target) else {
                throw PatcherError.invalidFormat("invalid authenticated X1 dispatch target")
            }
            targets.append(target)
        }
        guard targets.count >= 2, let start = Int(exactly: table), start <= Int.max - targets.count * 8 else { return nil }
        return (targets, start ..< start + targets.count * 8)
    }

    private static func switchTable(at branch: Int, instructionAt: (Int) -> ARM64Instruction?,
                                    readMemory: (Int, Int) throws -> Data) throws -> (targets: [Int], data: Range<Int>)? {
        let window = (0 ... 7).compactMap { instructionAt(branch - (7 - $0) * 4) }
        guard window.count == 8 else { return nil }
        let c = window.map { $0.detail?.operands ?? [] }
        guard window[7].mnemonic == "br", c[7].count == 1,
              window[6].mnemonic == "add", c[6].count == 3,
              c[6][0].reg == c[7][0].reg,
              window[5].mnemonic == "adr", c[5].count == 2,
              c[5][0].reg == c[6][1].reg, c[5][1].type == .immediate,
              window[4].mnemonic == "ldrsw", c[4].count == 2,
              c[4][0].reg == c[6][2].reg, c[4][1].type == .memory,
              c[4][1].shift.type == .lsl, c[4][1].shift.amount == 2,
              window[3].mnemonic == "add", c[3].count == 3,
              c[3][0].reg == c[4][1].mem.base, c[3][1].reg == c[3][0].reg,
              c[3][2].type == .immediate, c[3][2].shift.amount == 0,
              window[2].mnemonic == "adrp", c[2].count == 2,
              c[2][0].reg == c[3][0].reg, c[2][1].type == .immediate,
              window[1].mnemonic == "csel", window[1].detail?.conditionCode == .ls, c[1].count == 3,
              c[1][0].reg == c[4][1].mem.index, c[1][1].reg == c[1][0].reg, c[1][2].reg == .xzr,
              window[0].mnemonic == "cmp", c[0].count == 2, c[0][0].reg == c[1][0].reg,
              c[0][1].type == .immediate, c[0][1].imm >= 0, c[0][1].imm < 4096
        else { return nil }
        let (tableAddress, overflow) = c[2][1].imm.addingReportingOverflow(c[3][2].imm)
        guard !overflow, let table = Int(exactly: tableAddress), table >= 0,
              let base = Int(exactly: c[5][1].imm) else { return nil }
        let count = Int(c[0][1].imm) + 1
        let bytes = try readMemory(table, count * 4)
        guard bytes.count == count * 4 else { throw PatcherError.invalidFormat("truncated X1 switch table") }
        var targets: [Int] = []
        for index in 0 ..< count {
            let (target, overflow) = base.addingReportingOverflow(Int(bytes.loadLE(Int32.self, at: index * 4)))
            guard !overflow, target & 3 == 0, !(table ..< table + count * 4).contains(target), instructionAt(target) != nil else {
                throw PatcherError.invalidFormat("invalid X1 switch destination at \(branch)")
            }
            targets.append(target)
        }
        return (targets, table ..< table + count * 4)
    }

    public static func lowerAndReattest(_ data: inout Data, identifier: String) throws -> (result: Result, slots: [CustomFirmwareSlotRehash]) {
        if isUniversal(data) { return try lowerUniversal(&data, identifier: identifier, reattest: true) }
        var patched = data
        let result = try lower(&patched, identifier: identifier)
        guard !result.records.isEmpty else { return (result, []) }
        guard let directories = CustomFirmwareMachOCodeSignature.codeDirectories(in: patched), !directories.isEmpty,
              directories.allSatisfy({ directory in
                  directory.hashType == 2 && directory.hashSize == 32 && result.records.allSatisfy { record in
                      directory.slotRange(record.fileOffset / directory.pageSize)?.contains(record.fileOffset + 3) == true
                  }
              }) else {
            throw PatcherError.invalidFormat("X1 instruction edits require complete SHA-256 signature coverage")
        }
        let slots = try CustomFirmwareMachOCodeSignature.reattest(&patched, modifiedOffsets: result.records.map(\.fileOffset))
        data = patched
        return (result, slots)
    }

    private static func isUniversal(_ data: Data) -> Bool {
        data.count >= 8 && [UInt32(0xBEBA_FECA), 0xBFBA_FECA].contains(data.loadLE(UInt32.self, at: 0))
    }

    private static func lowerUniversal(_ data: inout Data, identifier: String, reattest: Bool) throws -> (result: Result, slots: [CustomFirmwareSlotRehash]) {
        let wide = data.loadLE(UInt32.self, at: 0) == 0xBFBA_FECA
        let stride = wide ? 32 : 20
        let count = Int(UInt32(bigEndian: data.loadLE(UInt32.self, at: 4)))
        guard count > 0, count <= (data.count - 8) / stride else {
            throw PatcherError.invalidFormat("truncated X1 universal architecture table")
        }
        var slices: [Range<Int>] = [], selected: [Range<Int>] = []
        for index in 0 ..< count {
            let entry = 8 + index * stride
            let cpu = UInt32(bigEndian: data.loadLE(UInt32.self, at: entry))
            let subtype = UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 4))
            let offset = wide ? UInt64(bigEndian: data.loadLE(UInt64.self, at: entry + 8))
                : UInt64(UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 8)))
            let size = wide ? UInt64(bigEndian: data.loadLE(UInt64.self, at: entry + 16))
                : UInt64(UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 12)))
            guard let start = Int(exactly: offset), let length = Int(exactly: size),
                  start >= 8 + count * stride, length >= 32, start <= data.count, length <= data.count - start else {
                throw PatcherError.invalidFormat("X1 universal slice outside container")
            }
            let range = start ..< start + length
            guard !slices.contains(where: { $0.overlaps(range) }) else {
                throw PatcherError.invalidFormat("overlapping X1 universal slices")
            }
            slices.append(range)
            guard cpu == 0x0100_000C, subtype & 0x00FF_FFFF == 12 else { continue }
            guard data.loadLE(UInt32.self, at: start) == 0xFEED_FACF,
                  data.loadLE(UInt32.self, at: start + 4) == cpu,
                  data.loadLE(UInt32.self, at: start + 8) == subtype else {
                throw PatcherError.invalidFormat("X1 universal architecture disagrees with slice header")
            }
            selected.append(range)
        }
        var patched = data, records: [PatchRecord] = [], slots: [CustomFirmwareSlotRehash] = [], examples: [Int] = []
        var unvisited = 0
        for range in selected {
            var slice = data.subdata(in: range)
            let result: Result
            let hashes: [CustomFirmwareSlotRehash]
            let id = identifier + ".slice\(range.lowerBound)"
            if reattest {
                (result, hashes) = try lowerAndReattest(&slice, identifier: id)
            } else {
                result = try lower(&slice, identifier: id)
                hashes = []
            }
            let base = range.lowerBound
            records += result.records.map {
                PatchRecord(patchID: $0.patchID, component: $0.component, fileOffset: base + $0.fileOffset,
                    virtualAddress: $0.virtualAddress, originalBytes: $0.originalBytes, patchedBytes: $0.patchedBytes,
                    beforeDisasm: $0.beforeDisasm, afterDisasm: $0.afterDisasm, description: $0.patchDescription)
            }
            slots += hashes.map {
                CustomFirmwareSlotRehash(codeDirectoryOffset: base + $0.codeDirectoryOffset, slotType: $0.slotType,
                    pageIndex: $0.pageIndex, pageStart: base + $0.pageStart, pageEnd: base + $0.pageEnd,
                    hashFileOffset: base + $0.hashFileOffset, before: $0.before, after: $0.after, pageSize: $0.pageSize)
            }
            unvisited += result.unvisitedCandidates
            examples += result.unvisitedExamples.map { base + $0 }
            patched.replaceSubrange(range, with: slice)
        }
        data = patched
        return (Result(records: records.sorted { $0.fileOffset < $1.fileOffset }, unvisitedCandidates: unvisited,
                       unvisitedExamples: Array(examples.prefix(16))), slots)
    }

    public static func patch(fileAt url: URL, log: (String) -> Void = { print($0) }) throws {
        try patch(fileAt: url, identifier: FirmwareGuestSystemPatchSet.arm64eX1DyldBootstrap, log: log)
    }

    public static func patch(fileAt url: URL, identifier: String, log: (String) -> Void = { print($0) }) throws {
        var data = try Data(contentsOf: url)
        let (result, slots) = try lowerAndReattest(&data, identifier: identifier)
        guard !result.records.isEmpty else {
            log("  [·] X1: no reachable instructions to lower (unvisited candidates: \(result.unvisitedCandidates))")
            return
        }
        try data.write(to: url)
        for record in result.records { log(record.description) }
        log("  [+] X1: lowered \(result.records.count) instructions, re-attested \(slots.count) slots; unvisited candidates: \(result.unvisitedCandidates)")
    }

    private static func replacement(for instruction: ARM64Instruction) throws -> Data? {
        do {
            return try VPhoneArm64eX1Lowering.replacement(for: instruction)
        } catch {
            throw PatcherError.invalidFormat(String(describing: error))
        }
    }

    private static func entryPoints(_ data: Data, segments: [MachOSegmentInfo]) throws -> ([Int], [Range<Int>]) {
        guard let text = segments.first(where: { $0.name == "__TEXT" }) else {
            throw PatcherError.invalidFormat("X1 image has no __TEXT")
        }
        let count = Int(data.loadLE(UInt32.self, at: 16))
        var position = 32, seeds: [Int] = [], excluded: [Range<Int>] = []
        for _ in 0 ..< count {
            guard position <= data.count - 8 else { throw PatcherError.invalidFormat("truncated X1 load commands") }
            let command = data.loadLE(UInt32.self, at: position), size = Int(data.loadLE(UInt32.self, at: position + 4))
            guard size >= 8, size <= data.count - position else { throw PatcherError.invalidFormat("invalid X1 load command") }
            if command == 0x26 || command == 0x29 {
                guard size >= 16 else { throw PatcherError.invalidFormat("short X1 linkedit command") }
                let start = Int(data.loadLE(UInt32.self, at: position + 8)), length = Int(data.loadLE(UInt32.self, at: position + 12))
                guard start <= data.count, length <= data.count - start else { throw PatcherError.invalidFormat("X1 linkedit outside image") }
                if command == 0x26 {
                    var cursor = start, address = text.vmAddr
                    while cursor < start + length {
                        var delta: UInt64 = 0, shift = 0
                        while true {
                            guard cursor < start + length, shift < 63 else { throw PatcherError.invalidFormat("invalid function-start ULEB") }
                            let byte = data[cursor]; cursor += 1
                            delta |= UInt64(byte & 0x7F) << shift
                            if byte & 0x80 == 0 { break }
                            shift += 7
                        }
                        if delta == 0 { break }
                        let (next, overflow) = address.addingReportingOverflow(delta)
                        guard !overflow else { throw PatcherError.invalidFormat("function-start overflow") }
                        address = next
                        if let offset = MachOParser.vaToFileOffset(address, segments: segments) { seeds.append(offset) }
                    }
                } else {
                    guard length % 8 == 0 else { throw PatcherError.invalidFormat("invalid data-in-code table") }
                    for entry in stride(from: start, to: start + length, by: 8) {
                        let offset = Int(data.loadLE(UInt32.self, at: entry)), length = Int(data.loadLE(UInt16.self, at: entry + 4))
                        guard offset <= data.count, length <= data.count - offset else { throw PatcherError.invalidFormat("data-in-code outside image") }
                        excluded.append(offset ..< offset + length)
                    }
                }
            } else if command == 5, size >= 288, data.loadLE(UInt32.self, at: position + 8) == 6 {
                if let entry = MachOParser.vaToFileOffset(data.loadLE(UInt64.self, at: position + 272), segments: segments) { seeds.append(entry) }
            } else if command == 0x8000_0028, size >= 24 {
                let entry = data.loadLE(UInt64.self, at: position + 8)
                if entry < UInt64(data.count) { seeds.append(Int(entry)) }
            }
            position += size
        }
        return (seeds, excluded)
    }
}

// MARK: - Address Set

/// A set of instruction addresses: one bit per word inside the planned code
/// ranges, and a plain set for anything else. A whole-cache traversal inserts
/// hundreds of millions of addresses, where hashing each one dominated.
struct AddressSet {
    private let ranges: [(address: Int, count: Int)]
    private var bits: [[UInt64]]
    private var others = Set<Int>()

    init(ranges: [(address: Int, count: Int)]) {
        self.ranges = ranges
        bits = ranges.map { [UInt64](repeating: 0, count: ($0.count / 4 + 63) / 64) }
    }

    private func slot(_ address: Int) -> (range: Int, word: Int, mask: UInt64)? {
        guard address & 3 == 0,
              let range = ranges.firstIndex(where: { address >= $0.address && address - $0.address < $0.count / 4 * 4 })
        else { return nil }
        let index = (address - ranges[range].address) / 4
        return (range, index / 64, 1 << UInt64(index % 64))
    }

    func contains(_ address: Int) -> Bool {
        guard let slot = slot(address) else { return others.contains(address) }
        return bits[slot.range][slot.word] & slot.mask != 0
    }

    @discardableResult
    mutating func insert(_ address: Int) -> (inserted: Bool, memberAfterInsert: Int) {
        guard let slot = slot(address) else { return others.insert(address) }
        let inserted = bits[slot.range][slot.word] & slot.mask == 0
        bits[slot.range][slot.word] |= slot.mask
        return (inserted, address)
    }

    /// Every word address of `span` that lies in the ranges. A set of data
    /// words is only ever asked about addresses inside them.
    mutating func insertWords(in span: Range<Int>) {
        var address = (span.lowerBound + 3) & ~3
        while address < span.upperBound {
            if slot(address) != nil { insert(address) }
            address += 4
        }
    }
}

// MARK: - Decoder

extension CustomFirmwareArm64eX1 {
    /// Decodability answers shared by every worker of one run: an answer
    /// belongs to the word, not to the image or worker that asked. Striped so
    /// that workers rarely wait on one another.
    final class SharedDecodability: Sendable {
        private let stripes = (0 ..< 64).map { _ in OSAllocatedUnfairLock(initialState: [UInt32: Bool]()) }

        private func stripe(_ word: UInt32) -> OSAllocatedUnfairLock<[UInt32: Bool]> {
            stripes[Int((word &* 0x9E37_79B1) >> 26)]
        }

        func answer(_ word: UInt32) -> Bool? {
            stripe(word).withLock { $0[word] }
        }

        func record(_ word: UInt32, _ decodes: Bool) {
            stripe(word).withLock { $0[word] = decodes }
        }
    }

    /// Capstone behind two word-keyed caches, kept for as long as its owner
    /// plans: one worker reuses it across every image it takes.
    ///
    /// Most words decode the same at any address, and a few prologue,
    /// epilogue and move words make up much of every image. A PC-relative
    /// word is reused only once Capstone, decoding it at a second address,
    /// agrees field for field with one of the moves; a word no move reproduces
    /// always goes back to Capstone. The caps bound memory; the plain cache
    /// starts over when full, so a long run keeps the current image's words.
    final class Decoder {
        let capstone = ARM64Disassembler()
        private var plain: [UInt32: ARM64Instruction] = [:]
        private var relative: [UInt32: (item: ARM64Instruction, move: Move?, settled: Bool)] = [:]
        private var families: [UInt32: (item: ARM64Instruction, target: Int64, settled: Bool, agrees: Bool)] = [:]
        private var decodable: [UInt32: Bool] = [:]
        private let shared: SharedDecodability?

        init(shared: SharedDecodability? = nil) {
            self.shared = shared
        }

        /// Whether Capstone decodes `word` as one 4-byte instruction. That does
        /// not depend on the address, and costs far less to keep than a decode.
        /// A miss here asks the workers' shared answers before Capstone.
        func decodes(_ word: UInt32) -> Bool {
            if let known = decodable[word] { return known }
            let decodes: Bool
            if let known = shared?.answer(word) {
                decodes = known
            } else {
                let item = plain[word] ?? capstone.disassembleOne(ARM64.encodeU32(word), at: 0)
                decodes = item.map { $0.isDecoded && $0.size == 4 } ?? false
                shared?.record(word, decodes)
            }
            if decodable.count >= 1 << 22 { decodable.removeAll(keepingCapacity: true) }
            decodable[word] = decodes
            return decodes
        }

        func decode(_ word: UInt32, at address: Int) -> ARM64Instruction? {
            if let known = plain[word] { return moved(known, by: .none, to: address) }
            // A family template moves to any word of its family once Capstone,
            // at a second instance naming another target, agreed with the move.
            if let family = targetFamily(word, at: address) {
                let bytes = [UInt8](ARM64.encodeU32(word))
                if let known = families[family.key], known.settled {
                    if known.agrees, let item = retargeted(known.item, bytes: bytes, to: address,
                                                           delta: family.target - known.target)
                    {
                        return item
                    }
                }
                guard let item = capstone.disassembleOne(ARM64.encodeU32(word), at: UInt64(address)) else { return nil }
                if let known = families[family.key] {
                    if !known.settled, family.target != known.target {
                        let agrees = retargeted(known.item, bytes: bytes, to: address,
                                                delta: family.target - known.target).map { sameDecode($0, item) } ?? false
                        families[family.key] = (known.item, known.target, true, agrees)
                    }
                } else if families.count < 1 << 19 {
                    families[family.key] = (item, family.target, false, false)
                }
                return item
            }
            let isRelative = isPCRelative(word)
            if isRelative, let known = relative[word], known.settled,
               let move = known.move, let item = moved(known.item, by: move, to: address)
            {
                return item
            }
            guard let item = capstone.disassembleOne(ARM64.encodeU32(word), at: UInt64(address)) else { return nil }
            if !isRelative {
                if plain.count >= 1 << 19 { plain.removeAll(keepingCapacity: true) }
                plain[word] = item
            } else if let known = relative[word] {
                // Only a pair differing in both page and page offset tells the
                // three moves apart; a move that cannot be rebuilt then counts
                // as a mismatch, and a single match settles the word.
                if !known.settled, known.item.address >> 12 != item.address >> 12,
                   known.item.address & 0xFFF != item.address & 0xFFF
                {
                    let matches = Move.allCases.filter { move in
                        moved(known.item, by: move, to: address).map { sameDecode($0, item) } ?? false
                    }
                    if matches.count <= 1 { relative[word] = (known.item, matches.first, true) }
                }
            } else if relative.count < 1 << 19 {
                relative[word] = (item, nil, false)
            }
            return item
        }
    }
}
