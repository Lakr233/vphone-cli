// The paravirtual driver hashes its build date/time into Metal's cacheUUID.
// Replacing our compiler plugin does not change that identity, so persistent
// caches can return metallibs made by an older compiler. Change only the two
// eight-byte inputs of setupCompiler's SHA-256 calculation, using the plugin's
// content digest. Metal then handles invalidation through its existing key.
//
// Discovery follows setupCompiler's relative Objective-C method metadata and
// the imported CC_SHA256_Init/Update/Final calls. Both Update calls must read
// eight bytes of __cstring, exclusively referenced at those call sites, and
// Final's stack output must become the MTLCompiler initializer's cacheUUID.
// No addresses, build stamps or replacement instructions are embedded here.

import CryptoKit
import Foundation
import VPhonePatchKit

public enum CustomFirmwareParavirtGPUCompilerCache {
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }
    static let selector = "setupCompiler"
    static let compilerSelector = "initWithTargetData:cacheUUID:pluginPath:device:compilerFlags:"

    public enum State: Sendable, Equatable { case patched, alreadyPatched }

    public struct Site: Sendable, Equatable {
        public let fileOffset: Int
        public let before: Data
        public let after: Data
    }

    public struct Report: Sendable, Equatable {
        public let sites: [Site]
        public let state: State
        public let identity: String
    }

    /// Sixteen printable bytes retain 96 digest bits, rather than the 64 bits
    /// hexadecimal would fit. There are no embedded NULs or altered terminators.
    /// At a million distinct plugin builds, birthday collision probability is
    /// approximately 6.3e-18. This is cache separation, not authentication.
    static func identity(for plugin: Data) throws -> String {
        guard !plugin.isEmpty else { throw failure("compiler plugin is empty") }
        return Data(SHA256.hash(data: plugin).prefix(12)).base64EncodedString()
    }

    @discardableResult
    public static func patch(
        fileAt url: URL, compilerPluginAt pluginURL: URL,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(&data, compilerPlugin: Data(contentsOf: pluginURL), log: log)
        if report.state == .patched { try data.write(to: url) }
        return report
    }

    /// All discovery and verification completes before the caller's data changes.
    @discardableResult
    public static func patch(
        _ data: inout Data, compilerPlugin: Data,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        let original = Data(data)
        let identity = try identity(for: compilerPlugin)
        let seed = Data(identity.utf8)
        let offsets = try resolve(in: original)
        let sites = offsets.enumerated().map { index, offset in
            Site(fileOffset: offset, before: original.subdata(in: offset ..< offset + 8),
                 after: seed.subdata(in: index * 8 ..< index * 8 + 8))
        }
        let changed = sites.contains { $0.before != $0.after }
        if changed {
            var patched = original
            for site in sites {
                patched.replaceSubrange(site.fileOffset ..< site.fileOffset + 8, with: site.after)
            }
            guard try resolve(in: patched) == offsets,
                  sites.allSatisfy({ patched.subdata(in: $0.fileOffset ..< $0.fileOffset + 8) == $0.after })
            else { throw failure("cache seed readback failed") }
            data = patched
        }
        for site in sites {
            let before = site.before.map { String(format: "%02x", $0) }.joined()
            let after = site.after.map { String(format: "%02x", $0) }.joined()
            log?("  [\(changed ? "+" : "·")] 0x\(String(site.fileOffset, radix: 16)): compiler cache seed \(before) -> \(after)")
        }
        return Report(sites: sites, state: changed ? .patched : .alreadyPatched, identity: identity)
    }

    /// The two hash-input file offsets, in SHA-256 update order.
    public static func resolve(in data: Data) throws -> [Int] {
        let data = Data(data)
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"], let strings = sections["__TEXT,__cstring"],
              let methods = sections["__TEXT,__objc_methlist"],
              let symbols = MachOSymbolTargets(data: data)
        else { throw failure("missing code, strings, method lists or symbol imports") }
        for section in [text, strings, methods] { try check(section, in: data) }
        let slots = try selectorSlots(selector, in: data, sections: sections)
        let imps = methodImplementations(naming: slots, in: data, section: methods)
        guard imps.count == 1, let start = imps.first,
              start >= text.address, start < text.address + text.size, start % 4 == 0
        else { throw failure("setupCompiler has no unique in-text implementation") }
        let decoder = ARM64Disassembler()
        let all = decoder.disassemble(data.subdata(in: Int(text.fileOffset) ..< Int(text.fileOffset) + Int(text.size)), at: text.address)
        guard let first = all.firstIndex(where: { $0.address == start }),
              let last = all[first...].firstIndex(where: { $0.isReturn }), last - first < 256
        else { throw failure("setupCompiler has no bounded return") }
        let body = Array(all[first ... last])
        guard body.allSatisfy({ $0.isDecoded && $0.size == 4 }),
              ["pacibsp", "paciasp"].contains(body[0].mnemonic),
              !body.dropFirst().contains(where: { ["pacibsp", "paciasp"].contains($0.mnemonic) })
        else { throw failure("setupCompiler crosses an undecoded instruction or another function") }
        let calls = body.enumerated().compactMap { index, instruction -> (Int, String)? in
            guard instruction.mnemonic == "bl", let target = immediate(instruction),
                  let name = symbols.name(forBranchTarget: target), name.hasPrefix("_CC_SHA256_")
            else { return nil }
            return (index, name)
        }
        guard calls.map(\.1) == ["_CC_SHA256_Init", "_CC_SHA256_Update", "_CC_SHA256_Update", "_CC_SHA256_Final"]
        else { throw failure("setupCompiler must contain one Init, two Updates and one Final") }
        let initIndex = calls[0].0
        guard initIndex > 0, let context = stackAddress(body[initIndex - 1], destination: .x(0)), context.base == .sp
        else { throw failure("SHA-256 context is not a local stack buffer") }
        // The digest is one straight-line calculation. A branch or an extra
        // call could bypass an update or change the stack buffer between calls.
        let hashBody = body[(initIndex + 1) ..< calls[3].0]
        let hashCalls = Set(calls[1 ... 2].map { body[$0.0].address })
        guard hashBody.allSatisfy({ !$0.isJump && (!$0.isCall || hashCalls.contains($0.address)) && !writes($0, register: .sp) && !writes($0, register: .x(29)) })
        else { throw failure("SHA-256 calculation has unexpected control flow or stack changes") }
        var offsets: [Int] = []
        var references: [UInt64] = []
        for (index, _) in calls[1 ... 2] {
            guard index >= 4,
                  let pointer = addressPair(body[index - 4], body[index - 3], destination: .x(1)),
                  stackAddress(body[index - 2], destination: .x(0)) == context,
                  moves(body[index - 1], register: .w(2), immediate: 8),
                  pointer >= strings.address, pointer + 8 < strings.address + strings.size
            else { throw failure("SHA-256 Update must consume a distinct eight-byte string range") }
            let offset = Int(strings.fileOffset) + Int(pointer - strings.address)
            // Each input starts a complete string, and leaves its terminator
            // untouched. Date has eleven characters; time has eight.
            guard offset == Int(strings.fileOffset) || data[offset - 1] == 0,
                  data[offset ..< offset + 8].allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
                  data[offset + 8 ..< min(offset + 16, Int(strings.fileOffset) + Int(strings.size))].contains(0)
            else { throw failure("hash input is not an eight-byte printable string prefix") }
            offsets.append(offset)
            references.append(body[index - 3].address)
        }
        guard abs(offsets[0] - offsets[1]) >= 8 else { throw failure("hash input ranges overlap") }
        let final = calls[3].0
        guard final >= 2,
              let output = stackAddress(body[final - 2], destination: .x(0)), output.base == .x(29),
              stackAddress(body[final - 1], destination: .x(1)) == context
        else { throw failure("SHA-256 Final does not write the expected local output") }
        let initializerSlots = try selectorSlots(compilerSelector, in: data, sections: sections)
        var initializers = 0
        for index in final + 1 ..< body.count where stackAddress(body[index], destination: .x(3)) == output {
            // cacheUUID is x3. All instructions through the initializer must
            // preserve it; no intervening call can invalidate the argument.
            for next in index + 1 ..< min(index + 8, body.count) {
                let instruction = body[next]
                if instruction.isCall {
                    if instruction.mnemonic == "bl", let target = immediate(instruction),
                       let stub = sections["__TEXT,__objc_stubs"], target >= stub.address,
                       target + 8 <= stub.address + stub.size {
                        try check(stub, in: data)
                        let offset = Int(stub.fileOffset) + Int(target - stub.address)
                        let insns = decoder.disassemble(data.subdata(in: offset ..< offset + 8), at: target)
                        if insns.count == 2, let slot = loadPair(insns[0], insns[1]), initializerSlots.contains(slot) {
                            initializers += 1
                        }
                    }
                    break
                }
                if instruction.isJump || instruction.isReturn || writes(instruction, register: .x(3)) { break }
            }
        }
        guard initializers == 1 else { throw failure("SHA-256 output does not uniquely reach MTLCompiler cacheUUID") }
        // Refuse shared literals: updating a build stamp must affect only the
        // cache key. Scan decoded ADR/ADRP+ADD references across all driver code.
        for (offset, expected) in zip(offsets, references) {
            let address = strings.address + UInt64(offset - Int(strings.fileOffset))
            var users: [UInt64] = []
            for index in all.indices {
                let instruction = all[index]
                if ["adr", "ldr"].contains(instruction.mnemonic), let target = immediate(instruction), (address ..< address + 8).contains(target) {
                    users.append(instruction.address)
                }
                // A scheduled instruction between ADRP and its use must not
                // hide a second reference to the seed. Track the page register
                // until a call, branch, return or overwrite ends its lifetime.
                if instruction.mnemonic == "adrp", let ops = instruction.detail?.operands,
                   ops.count == 2, ops[0].type == .register, let page = immediate(instruction) {
                    for use in all[(index + 1)...] {
                        if let target = addressPair(instruction, use), (address ..< address + 8).contains(target) {
                            users.append(use.address)
                        }
                        for operand in use.detail?.operands ?? [] where operand.type == .memory && operand.mem.base == ops[0].reg && operand.mem.index == .invalid {
                            let (target, overflow) = Int64(page).addingReportingOverflow(Int64(operand.mem.disp))
                            if !overflow, target >= 0, (address ..< address + 8).contains(UInt64(target)) { users.append(use.address) }
                        }
                        if use.isCall || use.isJump || use.isReturn || writes(use, register: ops[0].reg) { break }
                    }
                }
            }
            guard users == [expected] else { throw failure("compiler cache seed is referenced outside its SHA-256 Update") }
        }
        return offsets
    }

    // MARK: - Semantic decoding

    struct StackAddress: Equatable { let base: ARM64Register; let displacement: Int64 }

    static func writes(_ instruction: ARM64Instruction, register: ARM64Register) -> Bool {
        let aliases: Set<ARM64Register>
        if let index = (0 ..< 31).first(where: { register == .x($0) || register == .w($0) }) {
            aliases = [.x(index), .w(index)]
        } else {
            aliases = [register]
        }
        return instruction.detail?.operands.contains(where: {
            ($0.writesRegister && aliases.contains($0.reg)) ||
                ($0.type == .memory && instruction.detail?.writeback == true && aliases.contains($0.mem.base))
        }) == true
    }

    static func stackAddress(_ instruction: ARM64Instruction, destination: ARM64Register) -> StackAddress? {
        guard ["add", "sub"].contains(instruction.mnemonic), let ops = instruction.detail?.operands, ops.count == 3,
              ops[0].type == .register, ops[0].reg == destination,
              ops[1].type == .register, [.sp, .x(29)].contains(ops[1].reg),
              ops[2].type == .immediate, ops[2].shift.amount == 0
        else { return nil }
        return StackAddress(base: ops[1].reg, displacement: instruction.mnemonic == "sub" ? -ops[2].imm : ops[2].imm)
    }

    static func immediate(_ instruction: ARM64Instruction) -> UInt64? {
        instruction.detail?.operands.last.flatMap { $0.type == .immediate && $0.imm >= 0 ? UInt64($0.imm) : nil }
    }

    static func moves(_ instruction: ARM64Instruction, register: ARM64Register, immediate: Int64) -> Bool {
        guard ["mov", "movz"].contains(instruction.mnemonic), let ops = instruction.detail?.operands, ops.count == 2 else { return false }
        return ops[0].type == .register && ops[0].reg == register && ops[1].type == .immediate && ops[1].imm == immediate && ops[1].shift.amount == 0
    }

    static func addressPair(_ page: ARM64Instruction, _ add: ARM64Instruction, destination: ARM64Register? = nil) -> UInt64? {
        guard page.mnemonic == "adrp", add.mnemonic == "add",
              let p = page.detail?.operands, p.count == 2, let a = add.detail?.operands, a.count == 3,
              p[0].type == .register, p[1].type == .immediate, p[1].imm >= 0,
              a[0].type == .register, a[1].type == .register, a[2].type == .immediate, a[2].imm >= 0,
              a[1].reg == p[0].reg, destination == nil || a[0].reg == destination,
              a[2].shift.amount == 0
        else { return nil }
        return UInt64(p[1].imm) + UInt64(a[2].imm)
    }

    static func loadPair(_ page: ARM64Instruction, _ load: ARM64Instruction) -> UInt64? {
        guard page.mnemonic == "adrp", load.mnemonic == "ldr",
              let p = page.detail?.operands, p.count == 2, let l = load.detail?.operands, l.count == 2,
              p[0].type == .register, p[0].reg == .x(1), p[1].type == .immediate, p[1].imm >= 0,
              l[0].type == .register, l[0].reg == .x(1), l[1].type == .memory,
              l[1].mem.base == .x(1), l[1].mem.index == .invalid, l[1].mem.disp >= 0
        else { return nil }
        return UInt64(p[1].imm) + UInt64(l[1].mem.disp)
    }

    // MARK: - Objective-C metadata

    static func selectorSlots(_ selector: String, in data: Data, sections: [String: MachOSectionInfo]) throws -> Set<UInt64> {
        let referenceSections = sections.values.filter { $0.sectionName == "__objc_selrefs" }
        guard let names = sections["__TEXT,__objc_methname"], referenceSections.count == 1,
              let refs = referenceSections.first, refs.size % 8 == 0
        else { throw failure("missing Objective-C selector metadata") }
        try check(names, in: data)
        try check(refs, in: data)
        let needle = Data(selector.utf8) + [0]
        let range = Int(names.fileOffset) ..< Int(names.fileOffset) + Int(names.size)
        var cursor = range.lowerBound
        var addresses: Set<UInt64> = []
        while cursor < range.upperBound, let found = data.range(of: needle, in: cursor ..< range.upperBound) {
            if found.lowerBound == range.lowerBound || data[found.lowerBound - 1] == 0 {
                addresses.insert(names.address + UInt64(found.lowerBound - range.lowerBound))
            }
            cursor = found.upperBound
        }
        guard addresses.count == 1, let address = addresses.first else { throw failure("selector \(selector) is absent or ambiguous") }
        let base = MachOParser.parseSegments(from: data).first(where: { $0.name == "__TEXT" })?.vmAddr ?? 0
        var slots: Set<UInt64> = []
        for offset in stride(from: 0, to: Int(refs.size) - 7, by: 8) {
            let value = data.loadLE(UInt64.self, at: Int(refs.fileOffset) + offset)
            let target = value & ((1 << 36) - 1)
            if value == address || target == address || (base <= UInt64.max - target && target + base == address) {
                slots.insert(refs.address + UInt64(offset))
            }
        }
        guard !slots.isEmpty else { throw failure("selector \(selector) has no reference") }
        return slots
    }

    static func methodImplementations(naming slots: Set<UInt64>, in data: Data, section: MachOSectionInfo) -> Set<UInt64> {
        var result: Set<UInt64> = []
        var cursor = 0
        while cursor + 8 <= Int(section.size) {
            let file = Int(section.fileOffset) + cursor
            let flags = data.loadLE(UInt32.self, at: file)
            let count = Int(data.loadLE(UInt32.self, at: file + 4))
            guard flags & 0x8000_0000 != 0, flags & 0x7fff_fffc == 12,
                  count <= (Int(section.size) - cursor - 8) / 12 else { return [] }
            for index in 0 ..< count {
                let entry = cursor + 8 + index * 12
                let (name, nameOverflow) = Int64(section.address + UInt64(entry)).addingReportingOverflow(Int64(data.loadLE(Int32.self, at: Int(section.fileOffset) + entry)))
                if !nameOverflow, name >= 0, slots.contains(UInt64(name)) {
                    let (imp, impOverflow) = Int64(section.address + UInt64(entry + 8)).addingReportingOverflow(Int64(data.loadLE(Int32.self, at: Int(section.fileOffset) + entry + 8)))
                    if !impOverflow, imp >= 0 { result.insert(UInt64(imp)) }
                }
            }
            cursor = (cursor + 8 + count * 12 + 7) & ~7
        }
        return result
    }

    static func check(_ section: MachOSectionInfo, in data: Data) throws {
        guard section.size > 0, section.size <= UInt64(data.count),
              UInt64(section.fileOffset) <= UInt64(data.count) - section.size,
              section.address <= UInt64(Int64.max) - section.size
        else { throw failure("invalid \(section.segmentName),\(section.sectionName) bounds") }
    }

    static func failure(_ message: String) -> PatcherError {
        .patchSiteNotFound("paravirtual GPU compiler cache: \(message)")
    }
}
