// CustomFirmwareWatchDogDiscovery.swift — Locate watchdogd VM-presence cache sites.

import Capstone
import Foundation

extension CustomFirmwareWatchDog {
    // MARK: - Site discovery

    /// Every VM-presence cache site in `data`, pristine or already patched, in
    /// address order.
    ///
    /// Throws rather than returning an empty array when nothing matches: an
    /// empty result would be indistinguishable from "this binary does not need
    /// the patch", and for watchdogd it always does.
    public static func locateSites(in data: Data, log: ((String) -> Void)? = nil) throws -> [Site] {
        let data = data.startIndex == 0 ? data : Data(data)
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections[textSectionKey] else {
            throw PatcherError.invalidFormat("no \(textSectionKey) section")
        }
        guard let literal = findLiteral(in: data, sections: sections) else {
            throw PatcherError.patchSiteNotFound("'\(sysctlName)' cstring not present")
        }
        log?("  [.] cstring at va:0x\(hex(literal.address)) "
            + "(foff:0x\(hex(UInt64(literal.fileOffset))), sect=\(literal.section))")

        guard let symbols = CustomFirmwareWatchDogSymbolTargets(data: data) else {
            throw PatcherError.invalidFormat(
                "no LC_SYMTAB/LC_DYSYMTAB — \(sysctlFunction) cannot be resolved",
            )
        }

        let start = Int(text.fileOffset)
        let end = start + Int(text.size)
        guard start >= 0, end <= data.count else {
            throw PatcherError.invalidFormat("\(textSectionKey) falls outside the file")
        }
        let instructions = ARM64Disassembler().disassemble(data.subdata(in: start ..< end), at: text.address)

        let segments = MachOParser.parseSegments(from: data)
        var pages: [UInt32: (page: UInt64, index: Int)] = [:]
        var sites: [Site] = []

        for (index, instruction) in instructions.enumerated() {
            // Capstone runs with `skipData` on, so a word it cannot decode
            // arrives as a data pseudo-instruction rather than ending the
            // stream. Register state across such a word means nothing.
            guard instruction.id != 0 else {
                pages.removeAll()
                continue
            }

            if instruction.mnemonic == "adrp" {
                if let destination = registerNumber(instruction, 0),
                   let page = immediate(instruction, 1)
                {
                    pages[destination] = (UInt64(bitPattern: page), index)
                }
                continue
            }

            // Layer 2: an ADRP+ADD pair that resolves to the literal. The 64-bit
            // form only — a `w` destination is arithmetic, not an address.
            guard instruction.mnemonic == "add",
                  let pointer = registerName(instruction, 0), pointer.hasPrefix("x"),
                  let base = registerNumber(instruction, 1),
                  let offset = immediate(instruction, 2),
                  let page = pages[base],
                  index - page.index <= pageToOffsetWindow,
                  page.page &+ UInt64(bitPattern: offset) == literal.address
            else { continue }

            guard let site = matchSite(
                instructions: instructions,
                addIndex: index,
                pointerRegister: pointer,
                literalVMA: literal.address,
                text: text,
                segments: segments,
                symbols: symbols,
            ) else { continue }

            if !sites.contains(where: { $0.gateVMA == site.gateVMA }) {
                sites.append(site)
            }
        }

        guard !sites.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "no '\(sysctlName)' cache site: expected an adrp+add for the cstring reaching "
                    + "\(argumentRegister), a bl \(sysctlFunction), a cbnz w0 gate, a cset wN, ne "
                    + "and a strb into a \(globalSegmentPrefix) global",
            )
        }
        return sites.sorted { $0.gateVMA < $1.gateVMA }
    }

    /// Match the canonical shape forward from the ADD that formed the string
    /// pointer. Returns `nil` when any layer of the anchor fails, which is how
    /// the three unrelated `sysctlbyname` calls in watchdogd are rejected.
    static func matchSite(
        instructions: [Instruction],
        addIndex: Int,
        pointerRegister: String,
        literalVMA: UInt64,
        text: MachOSectionInfo,
        segments: [MachOSegmentInfo],
        symbols: CustomFirmwareWatchDogSymbolTargets,
    ) -> Site? {
        // Layer 3: the call, and the import it resolves to.
        guard let callIndex = firstIndex(
            in: instructions,
            from: addIndex + 1,
            within: argumentSetupWindow,
            where: { $0.mnemonic == "bl" },
        ) else { return nil }
        let call = instructions[callIndex]
        guard let target = ARM64Encoder.decodeBranchTarget(
            insn: word(of: call),
            pc: call.address,
        ), symbols.name(forBranchTarget: target) == sysctlFunction else { return nil }

        // Layer 2, concluded: the literal has to be the call's `name` argument,
        // not just something this stretch of code also mentions.
        guard passesLiteral(
            inRegister: pointerRegister,
            from: addIndex,
            toCallAt: callIndex,
            in: instructions,
        ) else { return nil }

        // Layer 4a: the gate, which must be the very next instruction — the
        // defensive check on the call's return value.
        let gateIndex = callIndex + 1
        guard gateIndex < instructions.count else { return nil }
        let gate = instructions[gateIndex]
        let state: Site.State
        if gate.mnemonic == "cbnz", registerName(gate, 0) == "w0" {
            state = .pristine
        } else if gate.mnemonic == "nop" {
            state = .patched
        } else {
            return nil
        }

        // Layer 4b: the value the store writes. `cset wN, ne` is the stock
        // truthiness of the sysctl's out-parameter; `mov wN, #1` is what this
        // patch leaves in its place.
        guard let valueIndex = firstIndex(
            in: instructions, from: gateIndex + 1, within: gateToValueWindow,
            where: { instruction in
                switch state {
                case .pristine:
                    instruction.mnemonic == "cset" && instruction.aarch64?.conditionCode == AArch64CC_NE
                case .patched:
                    isMoveOfOne(instruction)
                }
            },
        ) else { return nil }
        let value = instructions[valueIndex]
        guard let valueRegister = registerName(value, 0),
              let valueNumber = wRegisterNumber(valueRegister) else { return nil }

        // Layer 5: the store of that same register into an ADRP-relative
        // __DATA address — the cached global.
        guard let storeIndex = firstIndex(
            in: instructions,
            from: valueIndex + 1,
            within: valueToStoreWindow,
            where: { $0.mnemonic == "strb" && registerName($0, 0) == valueRegister },
        ) else { return nil }
        let store = instructions[storeIndex]
        guard let memory = memoryOperand(store) else { return nil }
        guard let basePage = pageAddress(
            ofRegister: UInt32(memory.base.rawValue),
            before: storeIndex,
            notBefore: addIndex,
            in: instructions,
        ) else { return nil }
        let cachedByte = basePage &+ UInt64(bitPattern: Int64(memory.disp))
        guard let segment = segments.first(where: {
            cachedByte >= $0.vmAddr && cachedByte < $0.vmAddr &+ $0.vmSize
        }), segment.name.hasPrefix(globalSegmentPrefix) else { return nil }

        return Site(
            state: state,
            literalVMA: literalVMA,
            addVMA: instructions[addIndex].address,
            callVMA: call.address,
            gateVMA: gate.address,
            gateFileOffset: fileOffset(of: gate.address, in: text),
            valueVMA: value.address,
            valueFileOffset: fileOffset(of: value.address, in: text),
            valueRegister: valueRegister,
            valueRegisterNumber: valueNumber,
            storeVMA: store.address,
            cachedByteVMA: cachedByte,
        )
    }

    /// True when the literal the ADD at `addIndex` formed is in `x0` by the time
    /// the call at `callIndex` runs.
    ///
    /// Two ways that happens, and both occur in Apple's own codegen: the ADD
    /// writes `x0` outright, or it writes a scratch register that a later
    /// `mov x0, xN` moves into place. Accepting only the first would make the
    /// patch miss the site on a build that schedules the argument differently —
    /// loudly, but still wrongly.
    static func passesLiteral(
        inRegister pointer: String,
        from addIndex: Int,
        toCallAt callIndex: Int,
        in instructions: [Instruction],
    ) -> Bool {
        if pointer == argumentRegister {
            return true
        }
        for index in (addIndex + 1) ..< callIndex {
            let instruction = instructions[index]
            if instruction.mnemonic == "mov",
               registerName(instruction, 0) == argumentRegister,
               registerName(instruction, 1) == pointer
            {
                return true
            }
        }
        return false
    }

    /// The literal's VA, file offset and section, matched only at a string
    /// boundary so a suffix of a longer literal cannot pass.
    static func findLiteral(
        in data: Data,
        sections: [String: MachOSectionInfo],
    ) -> (address: UInt64, fileOffset: Int, section: String)? {
        for (key, section) in sections.sorted(by: { $0.key < $1.key })
            where literalSectionNames.contains(section.sectionName)
        {
            let start = Int(section.fileOffset)
            let end = start + Int(section.size)
            guard start >= 0, end <= data.count, start < end else { continue }
            let body = data.subdata(in: start ..< end)

            var searchFrom = body.startIndex
            while let found = body.range(of: needle, in: searchFrom ..< body.endIndex) {
                let index = found.lowerBound
                if index == body.startIndex || body[index - 1] == 0 {
                    return (section.address &+ UInt64(index), start + index, key)
                }
                searchFrom = index + 1
            }
        }
        return nil
    }
}
