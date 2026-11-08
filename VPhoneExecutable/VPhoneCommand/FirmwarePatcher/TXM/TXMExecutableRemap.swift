import Foundation
import VPhonePatchKit

/// The classifier's category byte: `[state, #offset]`, or `[pointer]` when
/// the classifier keeps a pointer to it.
private struct TXMRemapCategory {
    let state: ARM64Register
    let offset: Int64
    let pointer: ARM64Register?
}

extension TXMDevPatcher {
    static let executableRemapID = "txm-cfw-executable_remap"

    /// Preserve native remap policy by keeping real cache/CMS classification.
    /// Research signatures, including the installer's CMS-less ldid form, use
    /// Apple's path-dependent tolerance. Ad-hoc fallback remains type 10.
    func patchExecutableRemap() throws {
        guard gate.isEnabled(Self.executableRemapID) else { return }

        let code = MachOParser.parseSegments(from: buffer.original)
            .filter { $0.name == "__TEXT_EXEC" }
            .flatMap { disasm.disassemble(in: buffer.original, at: Int($0.fileOffset), count: Int($0.fileSize / 4)) }
        let byAddress = Dictionary(uniqueKeysWithValues: code.enumerated().map { ($0.element.address, $0.offset) })

        // The pre-check walks policy callbacks before CMS/ad-hoc classification.
        // Recover that function from the authenticated call and its result codes.
        var prechecks = Set<Int>()
        for i in 0 ..< max(0, code.count - 3) {
            guard remapImmediate(code[i], "mov", .x(17), 0x7e51),
                  code[i + 1].mnemonic == "blraa",
                  code[i + 1].detail?.operands.last?.reg == .x(17),
                  remapImmediate(code[i + 2], "tst", .w(0), 0xff00),
                  remapBranch(code[i + 3], "b.ne") != nil,
                  let function = remapFunction(code, containing: i),
                  function.contains(where: { remapImmediate($0, "mov", .w(0), 0x2990) }),
                  function.contains(where: { remapImmediate($0, "mov", .w(0), 0x90) })
            else { continue }
            prechecks.insert(Int(function[0].address))
        }
        guard prechecks.count == 1, let precheck = prechecks.first else {
            throw PatcherError.patchSiteNotFound("TXM classification: expected one policy pre-check")
        }

        var classifiers: [(code: [ARM64Instruction], cms: Int, context: Int64, category: TXMRemapCategory)] = []
        for i in 0 ..< max(0, code.count - 6) {
            guard remapBranch(code[i], "bl") == precheck,
                  let function = remapFunction(code, containing: i),
                  let category = remapCategory(function, call: code[i]),
                  remapImmediate(code[i + 1], "tst", .w(0), 0xff00),
                  let success = remapBranch(code[i + 2], "b.eq"),
                  let context = remapLoad(code[i + 3], "ldr", category.state), context.offset == 0,
                  let tolerance = remapLoad(code[i + 4], "ldrb", context.register),
                  let native = remapBitBranch(code[i + 5], "tbz", tolerance.register, 0),
                  let n = byAddress[UInt64(native)], n + 6 < code.count,
                  let flags = remapLoad(code[n], "ldrb", .sp),
                  remapBitBranch(code[n + 1], "tbnz", flags.register, 1) != nil,
                  let cms = remapBranch(code[n + 4], "bl"),
                  remapImmediate(code[n + 5], "tst", .w(0), 0xff00),
                  remapSuccess(code, at: n + 6) == success
            else { continue }
            classifiers.append((function, cms, tolerance.offset, category))
        }
        guard classifiers.count == 1, let classifier = classifiers.first,
              let cmsIndex = byAddress[UInt64(classifier.cms)],
              code[cmsIndex].mnemonic == "pacibsp",
              let cms = remapFunction(code, containing: cmsIndex)
        else {
            throw PatcherError.patchSiteNotFound("TXM classification: expected one native CMS/ad-hoc split")
        }

        var adhocSites: [Int] = []
        let classification = classifier.code
        for i in 0 ..< max(0, classification.count - 7) {
            guard let context = remapLoad(classification[i], "ldr", classifier.category.state), context.offset == 0,
                  let tolerance = remapLoad(classification[i + 1], "ldrb", context.register),
                  tolerance.offset == classifier.context + 1,
                  let reject = remapBitBranch(classification[i + 2], "tbz", tolerance.register, 0),
                  remapImmediate(classification[i + 3], "mov", .w(8), 10),
                  let store = remapBranch(classification[i + 4], "b"),
                  reject == Int(classification[i + 5].address),
                  remapImmediate(classification[i + 5], "mov", .w(0), 0x2202),
                  remapImmediate(classification[i + 6], "movk", .w(0), 3),
                  let s = byAddress[UInt64(store)],
                  remapCategoryStore(code[s], classifier.category) == .w(8)
            else { continue }
            adhocSites.append(Int(classification[i + 2].address))
        }

        // Recover the native fallback. CMS parse/digest failures, the second
        // policy flag, and the path marker selecting type 5 versus 10 stay intact.
        var cmsSites: [Int] = []
        for i in 0 ..< max(0, cms.count - 12) {
            guard let tolerance = remapLoad(cms[i], "ldrb", .x(23)), tolerance.offset == classifier.context + 1,
                  let reject = remapBitBranch(cms[i + 1], "tbz", tolerance.register, 0),
                  let restriction = remapLoad(cms[i + 2], "ldrb", .x(23)), restriction.offset == tolerance.offset + 3,
                  remapBitBranch(cms[i + 3], "tbnz", restriction.register, 0) == reject,
                  remapImmediate(cms[i + 4], "mov", .w(8), 0),
                  remapImmediate(cms[i + 5], "mov", .w(22), 0),
                  let container = remapLoad(cms[i + 6], "ldrb", .x(20)), container.offset == 0x2a,
                  remapImmediate(cms[i + 7], "tst", container.register, 1),
                  remapImmediate(cms[i + 8], "mov", .w(9), 10),
                  remapImmediate(cms[i + 9], "mov", .w(10), 5),
                  cms[i + 10].mnemonic == "csel", cms[i + 10].detail?.conditionCode == .ne,
                  cms[i + 10].detail?.operands.map(\.reg) == [.w(9), .w(10), .w(9)],
                  let store = remapBranch(cms[i + 11], "b"),
                  reject == Int(cms[i + 12].address),
                  let s = byAddress[UInt64(store)],
                  let type = remapLoad(code[s], "strb", .x(19)), type.register == .w(9), type.offset == 0
            else { continue }
            cmsSites.append(Int(cms[i + 1].address))
        }
        guard adhocSites.count == 1, cmsSites.count == 1 else {
            throw PatcherError.patchSiteNotFound("TXM classification: expected native ad-hoc and CMS tolerance gates")
        }

        // The bundled installer writes ldid signatures: CS_ADHOC clear, no CMS.
        // These reach CMS classification after a real cache miss and fail before
        // the certificate-policy fallback. Redirect only the absent-wrapper exit
        // to that fallback. The earlier SuperBlob validator rejects a present
        // slot with the wrong magic, duplicate slots and malformed bounds; an
        // existing wrapper still reaches every CMS parse and digest check.
        var missingCMSSites: [Int] = []
        for i in 0 ..< max(0, cms.count - 5) {
            guard remapImmediate(cms[i], "mov", .w(2), 0x10000),
                  remapImmediate(cms[i + 1], "mov", .w(3), 0xb01),
                  remapImmediate(cms[i + 2], "movk", .w(3), 0xfade),
                  cms[i + 2].detail?.operands.last?.shift.type == .lsl,
                  cms[i + 2].detail?.operands.last?.shift.amount == 16,
                  remapImmediate(cms[i + 3], "mov", .x(4), 0),
                  remapBranch(cms[i + 4], "bl") != nil,
                  let missing = remapCompareBranch(cms[i + 5], "cbz", .x(0)),
                  let m = byAddress[UInt64(missing)], m + 1 < code.count,
                  remapImmediate(code[m], "mov", .w(8), 0x124),
                  remapBranch(code[m + 1], "b") != nil
            else { continue }
            missingCMSSites.append(Int(cms[i + 5].address))
        }
        guard missingCMSSites.count == 1, let missingCMS = missingCMSSites.first,
              let fallback = byAddress[UInt64(cmsSites[0])], fallback > 0,
              let missingCMSBranch = ARM64Encoder.encodeCompareBranch(
                  nonzero: false, register: 0, from: missingCMS,
                  to: Int(code[fallback - 1].address), width64: true,
              )
        else {
            throw PatcherError.patchSiteNotFound("TXM classification: expected the absent CMS wrapper exit")
        }

        let library = try remapLibraryCompatibility(code, byAddress: byAddress)

        // Resolve every site before selecting a different base bypass. A missing
        // shape must not leave fabricated cache hits disabled without tolerance.
        try patchTrustcacheBypass(preservingCacheQueries: true)
        emit(cmsSites[0], ARM64.nop, patchID: Self.executableRemapID + ".cms",
             description: "use native CMS research fallback after certificate-policy miss")
        emit(adhocSites[0], ARM64.nop, patchID: Self.executableRemapID + ".adhoc",
             description: "use native type-10 fallback after ad-hoc classification miss")
        emit(missingCMS, missingCMSBranch, patchID: Self.executableRemapID + ".ldid",
             description: "use native path-dependent research fallback for CMS-less installer signatures")
        emit(library.site, library.bytes, patchID: Self.executableRemapID + ".library",
             description: "research compatibility: allow absent or mismatched library Team IDs")
    }

    /// Temporary research policy for installed and separately pushed hot-reload
    /// libraries. Skip only Team ID matching (including one/both absent) after
    /// native signature, category-order and context/role checks. This is not
    /// proof of a common signer/package and does not grant X to arbitrary pages.
    /// Follow-up: vphone's re-signer should retain the original CodeDirectory
    /// Team ID, so this research exception can be narrowed or removed. Directly
    /// pushed hot-reload libraries must also be covered before tightening it.
    /// Types 1/2 and >=6 and executable range/alias checks remain native.
    private func remapLibraryCompatibility(_ code: [ARM64Instruction], byAddress: [UInt64: Int]) throws
        -> (site: Int, bytes: Data)
    {
        var sites: [(Int, Int)] = []
        for i in 0 ..< max(0, code.count - 25) {
            guard let mainType = remapLoad(code[i], "ldrb", .sp), mainType.register == .w(9),
                  code[i + 1].mnemonic == "cmp", code[i + 1].detail?.operands.map(\.reg) == [.w(8), .w(9)],
                  remapBranch(code[i + 2], "b.hs") == Int(code[i + 6].address),
                  remapImmediate(code[i + 3], "mov", .w(21), 0x3007),
                  remapImmediate(code[i + 4], "movk", .w(21), 5),
                  let exit = remapBranch(code[i + 5], "b"),
                  remapImmediate(code[i + 6], "mov", .w(21), 0x2407),
                  remapImmediate(code[i + 7], "movk", .w(21), 6),
                  let reader = remapBranch(code[i + 11], "bl"),
                  remapBranch(code[i + 15], "bl") == reader,
                  let mainTeam = remapLoad(code[i + 16], "ldr", .sp), mainTeam.register == .x(0),
                  remapCompareBranch(code[i + 17], "cbz", .x(0)) == exit,
                  let libraryTeam = remapLoad(code[i + 18], "ldr", .sp), libraryTeam.register == .x(1),
                  mainTeam.offset != libraryTeam.offset,
                  remapCompareBranch(code[i + 19], "cbz", .x(1)) == Int(code[i + 25].address),
                  code[i + 20].mnemonic == "bl", code[i + 20].detail?.operands.first?.type == .immediate,
                  remapImmediate(code[i + 21], "cmp", .w(0), 0),
                  remapImmediate(code[i + 22], "mov", .w(8), 7),
                  code[i + 23].mnemonic == "csel", code[i + 23].detail?.conditionCode == .eq,
                  code[i + 23].detail?.operands.map(\.reg) == [.w(21), .w(8), .w(26)],
                  remapBranch(code[i + 24], "b") == exit,
                  let e = byAddress[UInt64(exit)], code[e].mnemonic == "mov",
                  code[e].detail?.operands.map(\.reg) == [.x(0), .x(21)],
                  let function = remapFunction(code, containing: i)
            else { continue }

            // Prove only ordinary types reach the rewritten block. Native
            // special handling for types 1/2 and >=6 must not be redirected.
            let ordinaryOnly = function.indices.dropLast(2).contains { n in
                guard remapImmediate(function[n], "cmp", .w(8), 6),
                      let low = remapBranch(function[n + 1], "b.lo"),
                      let l = byAddress[UInt64(low)], l + 3 < code.count else { return false }
                return remapImmediate(code[l], "cmp", .w(8), 2)
                    && remapBranch(code[l + 1], "b.eq") != nil
                    && remapImmediate(code[l + 2], "cmp", .w(8), 1)
                    && remapBranch(code[l + 3], "b.ne") == Int(code[i].address)
            }
            if ordinaryOnly { sites.append((Int(code[i + 6].address), exit)) }
        }
        guard sites.count == 1, let (site, exit) = sites.first,
              let success = ARM64Encoder.encodeMovzW(rd: 21, imm16: 7),
              let branch = ARM64Encoder.encodeB(from: site + 4, to: exit) else {
            throw PatcherError.patchSiteNotFound("TXM library compatibility: expected one ordinary-library comparison")
        }
        return (site, success + branch)
    }

    /// The pre-check's arguments: the signature state and its category byte.
    /// cloudOS 26.4 passes `add x1, x20, #0x101`; 26.1 keeps
    /// `x20 = x21 + 0xa1` for the whole function and passes `mov x1, x20`.
    private func remapCategory(_ function: [ARM64Instruction], call: ARM64Instruction) -> TXMRemapCategory? {
        guard let c = function.firstIndex(where: { $0.address == call.address }) else { return nil }
        var state: ARM64Register?
        var argument: ARM64Instruction?
        for instruction in function[..<c].reversed() {
            if instruction.isCall || instruction.isJump { break }
            if state == nil, remapWrites(instruction, .x(0)) {
                guard let source = remapMove(instruction, to: .x(0)) else { return nil }
                state = source
            }
            if argument == nil, remapWrites(instruction, .x(1)) { argument = instruction }
            if state != nil, argument != nil { break }
        }
        guard let state, let argument else { return nil }
        if let offset = remapAddImmediate(argument, to: .x(1), from: state) {
            return TXMRemapCategory(state: state, offset: offset, pointer: nil)
        }
        // The pointer must keep its single definition across the classifier;
        // only the epilogue may reload it from the stack.
        guard let pointer = remapMove(argument, to: .x(1)),
              let definition = function[..<c].last(where: { remapWrites($0, pointer) }),
              let offset = remapAddImmediate(definition, to: pointer, from: state),
              function.allSatisfy({ instruction in
                  instruction.address == definition.address || !remapWrites(instruction, pointer)
                      || instruction.detail?.operands.contains { $0.type == .memory && $0.mem.base == .sp } == true
              })
        else { return nil }
        return TXMRemapCategory(state: state, offset: offset, pointer: pointer)
    }

    /// The register a `strb` writes into the classifier's category byte.
    private func remapCategoryStore(_ instruction: ARM64Instruction, _ category: TXMRemapCategory) -> ARM64Register? {
        if let store = remapLoad(instruction, "strb", category.state), store.offset == category.offset {
            return store.register
        }
        if let pointer = category.pointer, let store = remapLoad(instruction, "strb", pointer), store.offset == 0 {
            return store.register
        }
        return nil
    }

    /// Where a `tst w0, #0xff00` result continues on success: `b.eq target`,
    /// or the inverted `b.ne failure; b target` that cloudOS 26.1 emits.
    private func remapSuccess(_ code: [ARM64Instruction], at index: Int) -> Int? {
        if let target = remapBranch(code[index], "b.eq") { return target }
        guard remapBranch(code[index], "b.ne") != nil, index + 1 < code.count else { return nil }
        return remapBranch(code[index + 1], "b")
    }

    private func remapWrites(_ instruction: ARM64Instruction, _ register: ARM64Register) -> Bool {
        instruction.detail?.operands.contains { $0.type == .register && $0.reg == register && $0.writesRegister } == true
    }

    private func remapMove(_ instruction: ARM64Instruction, to destination: ARM64Register) -> ARM64Register? {
        guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands, operands.count == 2,
              operands[0].type == .register, operands[0].reg == destination, operands[1].type == .register
        else { return nil }
        return operands[1].reg
    }

    private func remapAddImmediate(_ instruction: ARM64Instruction, to destination: ARM64Register, from source: ARM64Register) -> Int64? {
        guard instruction.mnemonic == "add", let operands = instruction.detail?.operands, operands.count == 3,
              operands[0].type == .register, operands[0].reg == destination,
              operands[1].type == .register, operands[1].reg == source,
              operands[2].type == .immediate, operands[2].imm > 0, operands[2].shift.type == .none
        else { return nil }
        return operands[2].imm
    }

    private func remapFunction(_ code: [ARM64Instruction], containing index: Int) -> [ARM64Instruction]? {
        guard let start = code[...index].lastIndex(where: { $0.mnemonic == "pacibsp" }) else { return nil }
        let end = code[(start + 1)...].firstIndex(where: { $0.mnemonic == "pacibsp" }) ?? code.endIndex
        // Cold blocks may follow a RETAB; include them up to the next function.
        return Array(code[start ..< end])
    }

    private func remapLoad(_ instruction: ARM64Instruction, _ mnemonic: String, _ base: ARM64Register)
        -> (register: ARM64Register, offset: Int64)?
    {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 2,
              operands[0].type == .register, operands[1].type == .memory, operands[1].mem.base == base,
              operands[1].mem.index == .invalid, instruction.detail?.writeback == false
        else { return nil }
        return (operands[0].reg, Int64(operands[1].mem.disp))
    }

    private func remapImmediate(_ instruction: ARM64Instruction, _ mnemonic: String, _ register: ARM64Register, _ immediate: Int64) -> Bool {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 2 else { return false }
        return operands[0].type == .register && operands[0].reg == register && operands[1].type == .immediate && operands[1].imm == immediate
    }

    private func remapBranch(_ instruction: ARM64Instruction, _ mnemonic: String) -> Int? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands,
              operands.count == 1, operands[0].type == .immediate, operands[0].imm >= 0 else { return nil }
        return Int(operands[0].imm)
    }

    private func remapBitBranch(_ instruction: ARM64Instruction, _ mnemonic: String, _ register: ARM64Register, _ bit: Int64) -> Int? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 3,
              operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .immediate, operands[1].imm == bit,
              operands[2].type == .immediate, operands[2].imm >= 0 else { return nil }
        return Int(operands[2].imm)
    }

    private func remapCompareBranch(_ instruction: ARM64Instruction, _ mnemonic: String, _ register: ARM64Register) -> Int? {
        guard instruction.mnemonic == mnemonic, let operands = instruction.detail?.operands, operands.count == 2,
              operands[0].type == .register, operands[0].reg == register,
              operands[1].type == .immediate, operands[1].imm >= 0 else { return nil }
        return Int(operands[1].imm)
    }
}
