import Foundation
import VPhonePatchKit

public enum CustomFirmwareRemotePairing {
    public static let patchID = "system-remotepairingdeviced-cfw-local_connections"

    private static let controlMessage = "%{public}s: Rejecting control channel connection originating from local machine: %{public}s"
    private static let tunnelMessage = "Rejecting tunnel connection originating from local machine"

    @discardableResult
    public static func patch(fileAt url: URL, dryRun: Bool = false) throws -> [PatchRecord] {
        var data = try Data(contentsOfFileToRewrite: url)
        let sites = try locate(in: data)
        var records: [PatchRecord] = []
        for (index, site) in sites.enumerated() {
            let before = data.subdata(in: site.offset ..< site.offset + 4)
            let status = before == ARM64.movW0_0 ? "=" : dryRun ? "." : "+"
            print("  [\(status)] local-connection check at 0x\(String(site.address, radix: 16)) (file 0x\(String(site.offset, radix: 16))): \(site.instruction) -> mov w0, #0")
            guard before != ARM64.movW0_0 else { continue }
            records.append(PatchRecord(
                patchID: "\(patchID).\(index + 1)",
                component: "remotepairingdeviced",
                fileOffset: site.offset,
                virtualAddress: site.address,
                originalBytes: before,
                patchedBytes: ARM64.movW0_0,
                beforeDisasm: site.instruction,
                afterDisasm: "mov w0, #0",
                description: "Allow a local pairing connection",
            ))
            data.replaceSubrange(site.offset ..< site.offset + 4, with: ARM64.movW0_0)
        }
        if !dryRun, !records.isEmpty {
            try data.write(to: url)
        }
        return records
    }

    private struct Site {
        let offset: Int
        let address: UInt64
        let instruction: String
    }

    private static func locate(in data: Data) throws -> [Site] {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"],
              UInt64(text.fileOffset) + text.size <= data.count,
              let symbols = MachOSymbolTargets(data: data)
        else { throw PatcherError.invalidFormat("remotepairingdeviced: missing Mach-O text, strings or imports") }
        let stringSections = ["__TEXT,__cstring", "__TEXT,__oslogstring"].compactMap { sections[$0] }
        guard stringSections.allSatisfy({ UInt64($0.fileOffset) + $0.size <= data.count }) else {
            throw PatcherError.invalidFormat("remotepairingdeviced: string section outside the image")
        }

        let instructions = ARM64Disassembler().disassemble(
            data.subdata(in: Int(text.fileOffset) ..< Int(text.fileOffset) + Int(text.size)),
            at: text.address,
        )
        // An arm64e.x1 build (iPhone19,x on 27.1 and later) signs its frames
        // with the PC-salted forms, so they open functions too.
        let prologues: Set = ["pacibsp", "pacibsppc", "pacnbibsppc"]
        let starts = instructions.indices.filter { prologues.contains(instructions[$0].mnemonic) }
        func function(containing index: Int) throws -> Range<Int> {
            guard let start = starts.last(where: { $0 <= index }),
                  let end = starts.first(where: { $0 > index })
            else { throw PatcherError.patchSiteNotFound("remotepairingdeviced: unbounded function") }
            return start ..< end
        }
        func importedCall(_ index: Int) -> String? {
            guard instructions[index].mnemonic == "bl",
                  let target = immediate(instructions[index], 0), target >= 0
            else { return nil }
            return symbols.importName(atStub: UInt64(target))
        }

        let localCalls = instructions.indices.filter { importedCall($0) == "_nw_path_is_local" }
        guard localCalls.count == 1 else {
            throw PatcherError.patchSiteNotFound("remotepairingdeviced: expected one local-path predicate")
        }
        let helperRange = try function(containing: localCalls[0])
        let helperCalls = helperRange.compactMap { importedCall($0) }
        guard helperCalls == ["_nw_connection_copy_current_path", "_nw_path_is_local", "_nw_path_uses_interface_type", "_swift_unknownObjectRelease"],
              let interfaceCall = helperRange.first(where: { importedCall($0) == "_nw_path_uses_interface_type" }),
              instructions[interfaceCall - 1].mnemonic == "mov",
              register(instructions[interfaceCall - 1], 0) == .w(1),
              immediate(instructions[interfaceCall - 1], 1) == 4
        else { throw PatcherError.patchSiteNotFound("remotepairingdeviced: unrecognized local-path predicate") }
        let helper = instructions[helperRange.lowerBound].address

        var sites: [Site] = []
        for (message, counts) in [(controlMessage, 1 ... 1), (tunnelMessage, 2 ... 3)] {
            let needle = Data((message + "\0").utf8)
            var addresses: [UInt64] = []
            for strings in stringSections {
                let bytes = data.subdata(in: Int(strings.fileOffset) ..< Int(strings.fileOffset) + Int(strings.size))
                var from = 0
                while let hit = bytes.range(of: needle, in: from ..< bytes.count) {
                    if hit.lowerBound == 0 || bytes[hit.lowerBound - 1] == 0 {
                        addresses.append(strings.address + UInt64(hit.lowerBound))
                    }
                    from = hit.upperBound
                }
            }
            guard addresses.count == 1 else {
                throw PatcherError.patchSiteNotFound("remotepairingdeviced: missing or ambiguous rejection message")
            }
            let address = addresses[0]
            let references = instructions.indices.filter { referencesString(address, at: $0, in: instructions) }
            guard counts.contains(references.count) else {
                throw PatcherError.patchSiteNotFound("remotepairingdeviced: expected \(counts) rejection references, found \(references.count)")
            }
            for reference in references {
                let range = try function(containing: reference)
                let candidates = range.filter { index in
                    let instruction = instructions[index]
                    let pristine = instruction.mnemonic == "bl" && immediate(instruction, 0) == Int64(helper)
                    guard pristine || Data(instruction.bytes) == ARM64.movW0_0 else { return false }
                    return rejectsLocalConnection(
                        at: index, reference: reference, function: range,
                        control: message == controlMessage, instructions: instructions, symbols: symbols,
                    )
                }
                guard candidates.count == 1 else {
                    throw PatcherError.patchSiteNotFound("remotepairingdeviced: missing or ambiguous rejection gate")
                }
                let instruction = instructions[candidates[0]]
                sites.append(Site(
                    offset: Int(text.fileOffset) + Int(instruction.address - text.address),
                    address: instruction.address,
                    instruction: "\(instruction.mnemonic) \(instruction.operandString)",
                ))
            }
        }
        let callers = instructions.filter { $0.mnemonic == "bl" && immediate($0, 0) == Int64(helper) }
        guard (3 ... 4).contains(sites.count), Set(sites.map(\.address)).count == sites.count,
              callers.allSatisfy({ call in sites.contains(where: { $0.address == call.address }) })
        else { throw PatcherError.patchSiteNotFound("remotepairingdeviced: local-path predicate has unrecognized callers") }
        return sites.sorted { $0.address < $1.address }
    }

    private static func rejectsLocalConnection(
        at index: Int, reference: Int, function: Range<Int>, control: Bool,
        instructions: [ARM64Instruction], symbols: MachOSymbolTargets,
    ) -> Bool {
        guard index + 7 < function.upperBound, index < reference else { return false }
        if control, instructions[index + 1].mnemonic != "tbz" {
            let result = instructions[index + 1]
            let release = instructions[index + 3]
            let gate = instructions[index + 4]
            guard result.mnemonic == "mov", register(result, 1) == .x(0),
                  let saved = register(result, 0),
                  let number = (0 ... 30).first(where: { .x($0) == saved }),
                  instructions[index + 2].mnemonic == "mov",
                  register(instructions[index + 2], 0) == .x(0),
                  release.mnemonic == "bl", let target = immediate(release, 0), target >= 0,
                  symbols.importName(atStub: UInt64(target)) == "_swift_unknownObjectRelease",
                  gate.mnemonic == "tbz", register(gate, 0) == .w(number),
                  immediate(gate, 1) == 0, let accepted = immediate(gate, 2)
            else { return false }
            return accepted > instructions[reference].address && accepted < instructions[function.upperBound].address
        }
        let gate = instructions[index + 1]
        guard gate.mnemonic == "tbz", register(gate, 0) == .w(0), immediate(gate, 1) == 0,
              let accepted = immediate(gate, 2)
        else { return false }
        if control {
            return accepted > instructions[reference].address && accepted < instructions[function.upperBound].address
        }
        let flagIndex = instructions[index + 2].mnemonic == "ldrb" ? index + 2 : index + 4
        let flag = instructions[flagIndex]
        let comparison = instructions[flagIndex + 1]
        let rejection = instructions[flagIndex + 2]
        guard accepted == Int64(instructions[flagIndex + 3].address),
              flag.mnemonic == "ldrb", let flagRegister = register(flag, 0),
              comparison.mnemonic == "cmp", register(comparison, 0) == flagRegister,
              immediate(comparison, 1) == 1,
              rejection.mnemonic == "b.ne", let target = immediate(rejection, 0), target >= 0
        else { return false }
        let logAddress = instructions[reference].address
        return UInt64(target) <= logAddress && logAddress - UInt64(target) <= 64
    }

    private static func referencesString(_ address: UInt64, at index: Int, in instructions: [ARM64Instruction]) -> Bool {
        let add = instructions[index]
        if add.mnemonic == "adr" {
            return register(add, 0) == .x(3) && immediate(add, 1) == Int64(address)
        }
        guard add.mnemonic == "add", register(add, 0) == .x(3),
              let base = register(add, 1), let offset = immediate(add, 2), offset >= 0
        else { return false }
        for prior in stride(from: index - 1, through: max(0, index - 8), by: -1) {
            let page = instructions[prior]
            guard register(page, 0) == base else { continue }
            return page.mnemonic == "adrp" && immediate(page, 1).map { $0 + offset == Int64(address) } == true
        }
        return false
    }

    private static func register(_ instruction: ARM64Instruction, _ index: Int) -> ARM64Register? {
        guard let operands = instruction.detail?.operands, operands.indices.contains(index), operands[index].type == .register else { return nil }
        return operands[index].reg
    }

    private static func immediate(_ instruction: ARM64Instruction, _ index: Int) -> Int64? {
        guard let operands = instruction.detail?.operands, operands.indices.contains(index), operands[index].type == .immediate else { return nil }
        return operands[index].imm
    }
}
