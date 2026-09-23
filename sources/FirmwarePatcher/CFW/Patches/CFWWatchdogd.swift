// CFWWatchdogd.swift — force watchdogd's cached "am I a VM?" byte to 1.
//
// Port of `scripts/patchers/cfw_patch_watchdogd.py` (453 lines). EXP only.
//
// Why the patch exists
// --------------------
// The EXP variant renames the kernel's `kern.hv_vmm_present` sysctl OID
// (`KernelEXPPatchHvVmmRename`), so every userland caller that still asks for
// that name gets ENOENT. `/usr/libexec/watchdogd` caches the answer at startup:
//
//     adrp x0, <page>
//     add  x0, x0, #<off>        ; "kern.hv_vmm_present"
//     sub  x1, x29, #4           ; &oldval
//     mov  x2, sp                ; &oldlen
//     mov  x3, #0
//     mov  x4, #0
//     bl   _sysctlbyname         ; via __auth_stubs
//     cbnz w0, <skip>            ; ENOENT -> skip the store
//     ldur w8, [x29, #-4]
//     cmp  w8, #0
//     cset w8, ne                ; w8 = (oldval != 0)
//     adrp x9, <page>
//     strb w8, [x9, #<off>]      ; the cached byte, a __DATA zero-fill global
//
// With the OID renamed the `cbnz` is taken, the store never runs, the cached
// byte keeps its BSS zero, and a downstream `cbz` on that byte falls into an
// `_os_crash` wrapper that executes `brk #1`. launchd's `_PanicOnCrash` turns
// the resulting SIGTRAP into a kernel panic, so this is a boot blocker rather
// than a cosmetic detection problem.
//
// What is changed
// ---------------
// Two instructions per site, and nothing else:
//
//     cbnz w0, <skip>   ->  nop            (never skip the store)
//     cset wN, ne       ->  mov wN, #1     (store 1, not the sysctl's answer)
//
// The cstring is deliberately NOT touched: the EXP design keeps every
// `kern.hv_vmm_present` consumer on the now-ENOENT name and opts individual
// consumers out by rewriting their logic, which is what this does. watchdogd
// then takes its clean-exit branch ("detected virtual machine environment and
// no watchdog KEXT found, exiting...") instead of the trap.
//
// How the site is anchored — no offsets, no byte patterns
// ------------------------------------------------------
// Five layers, each read off a Capstone decode or the Mach-O's own tables:
//
//   1. The `"kern.hv_vmm_present\0"` literal is found in a cstring section at a
//      NUL boundary, giving its VA.
//   2. In `__TEXT,__text`, an ADRP+ADD pair whose resolved address is that VA,
//      and whose result reaches x0 before the call — directly, or through a
//      `mov x0, xN`. That is the literal being passed as `sysctlbyname`'s
//      `name` argument rather than merely mentioned.
//   3. The following `bl`'s target is resolved through the indirect symbol
//      table to the imported function `_sysctlbyname`. This is an in-image
//      symbol lookup, which the Python does not do: it accepts any `bl`.
//   4. The instruction right after the call gates the store on the call's
//      return value (`cbnz w0`), and the value stored is `cset wN, ne` — the
//      truthiness of the sysctl's out-parameter. The condition is read from
//      Capstone's decoded condition code, not from operand text.
//   5. The `strb` stores that same wN into an ADRP-relative address inside a
//      `__DATA*` segment — a cached global, not a stack or heap field.
//
// Layers 2, 3 and 5 are additions over the Python, which stops at "some `bl`
// with a `cbnz w0` behind it". On `iPhone17,3` / iOS 27.0 (24A435) both
// implementations select exactly the same two sites; the extra layers are what
// keeps that true when the next firmware moves the code.
//
// Idempotence
// -----------
// A second run must be a no-op, not an error and not a double-apply (commit
// 8eb6c8b fixed exactly that class of bug elsewhere in this tree). The site
// matcher therefore recognises both shapes: the pristine one above and the one
// this patch leaves behind (`nop` … `mov wN, #1` … `strb wN`). A binary whose
// sites are all in the patched shape is reported as `.alreadyPatched`, nothing
// is written, and — importantly — re-attestation is skipped too, so the file
// on disk is byte-for-byte unchanged.
//
// Code signing
// ------------
// Editing bytes inside `__TEXT,__text` invalidates the SHA-256 slot hash of
// each containing 4 KiB page. On `codeSigningMonitor == 2` hardware TXM holds
// those hashes and kills the process on the first demand page-in, so every
// written offset is handed to `CFWMachOCodeSignature` to re-hash its page.
//
// The binary is NOT re-signed with an identity. Re-signing would reset the
// code-signing identifier to the local filename, which trips launchd's
// boot-task identity check — the failure mode observed on mobile_obliterator
// before an earlier attempt was reverted. Mutating the CD does change the
// binary's cdHash; the JB kernel patch `patch_amfi_cdhash_in_trustcache`
// short-circuits AMFI's trust-cache check, and that precondition still holds.

import Capstone
import Foundation

public enum CFWWatchdogd {
    // MARK: - Anchors

    /// Component name carried by every ``PatchRecord`` this patcher emits.
    public static let component = "watchdogd"

    /// The sysctl whose cached answer this patch overrides.
    public static let sysctlName = "kern.hv_vmm_present"

    /// The imported function the call site must resolve to. Layer 3 of the
    /// anchor: a `bl` that goes anywhere else is not this call.
    public static let sysctlFunction = "_sysctlbyname"

    /// `"kern.hv_vmm_present\0"` — the terminator is part of the match, so a
    /// longer name that merely starts with this one cannot pass.
    static let needle = Data((sysctlName + "\0").utf8)

    /// Sections a C string literal can land in. `__cstring` is where the linker
    /// puts them; the ObjC name pools could hold the same bytes, and the
    /// reference scans those too.
    static let literalSectionNames: Set<String> = [
        "__cstring", "__objc_methname", "__objc_classname",
    ]

    static let textSectionKey = "__TEXT,__text"

    /// Segment prefix a cached global must live under. `__bss` and `__common`
    /// are both `__DATA` sections; the prefix also covers `__DATA_DIRTY`.
    static let globalSegmentPrefix = "__DATA"

    /// Where the AArch64 C ABI puts `sysctlbyname`'s first argument.
    static let argumentRegister = "x0"

    // MARK: - Scan windows
    //
    // Instruction counts, not byte counts. Same values as the Python, which
    // measured them against the shipped binary.

    /// ADRP and the ADD that completes it may be separated by argument setup.
    static let pageToOffsetWindow = 8
    /// From the ADD that forms the string pointer forward to the call.
    static let argumentSetupWindow = 20
    /// From the gate forward to the instruction that produces the stored value.
    static let gateToValueWindow = 12
    /// From that instruction forward to the store.
    static let valueToStoreWindow = 8

    // MARK: - Sites

    /// One "cache the VM-presence answer" site, pristine or already patched.
    public struct Site: Sendable, Equatable {
        /// Which shape the site is in.
        public enum State: String, Sendable {
            /// The stock shape: `cbnz w0` gating a `cset wN, ne`.
            case pristine
            /// This patch's own output: `nop` and `mov wN, #1`.
            case patched
        }

        public let state: State
        /// VA of the `"kern.hv_vmm_present\0"` literal this site loads.
        public let literalVMA: UInt64
        /// VA of the ADD that completes the literal's address in x0.
        public let addVMA: UInt64
        /// VA of the `bl _sysctlbyname`.
        public let callVMA: UInt64
        /// VA of the gate — `cbnz w0` when pristine, `nop` when patched.
        public let gateVMA: UInt64
        public let gateFileOffset: Int
        /// VA of the instruction producing the cached value — `cset wN, ne`
        /// when pristine, `mov wN, #1` when patched.
        public let valueVMA: UInt64
        public let valueFileOffset: Int
        /// The `w` register carrying the cached value, e.g. `"w8"`.
        public let valueRegister: String
        /// That register's number, for re-encoding it as `mov wN, #1`.
        public let valueRegisterNumber: UInt32
        /// VA of the `strb` that writes the cached byte.
        public let storeVMA: UInt64
        /// VA of the cached byte itself — the `__DATA` global.
        public let cachedByteVMA: UInt64
    }

    // MARK: - Report

    /// What a run did, as a whole.
    public enum Outcome: String, Sendable, Equatable {
        /// Every site was already in the patched shape; nothing was written.
        case alreadyPatched
        /// `dryRun` was set: sites were located and reported only.
        case wouldPatch
        /// Bytes were written and the affected pages re-attested.
        case patched
    }

    /// The outcome of one run, and what it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        /// Every site the matcher recognised, in address order.
        public let sites: [Site]
        /// One record per instruction actually rewritten — two per patched
        /// site. Empty for `.alreadyPatched`.
        public let records: [PatchRecord]
        /// Code-directory slots re-hashed as a result.
        public let rehashedSlots: [CFWSlotRehash]

        /// Sites whose bytes this run changed. The parity number against the
        /// Python, whose `patch_watchdogd()` returns exactly this.
        public var sitesWritten: Int { records.count / 2 }
    }

    /// Where progress goes when the caller does not say. The Python prints to
    /// stdout and `cfw_install_exp.sh` captures that, so this does too.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Patching

    /// Patch the watchdogd Mach-O at `url` in place.
    ///
    /// - Returns: a ``Report``. `.alreadyPatched` leaves the file untouched,
    ///   which is what makes a second install run a clean no-op.
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when the file is not the
    ///   kind of Mach-O this patch understands, and
    ///   ``PatcherError/patchSiteNotFound(_:)`` when it is but holds no site in
    ///   either shape — a watchdogd that no longer caches the sysctl, which has
    ///   to stop the install rather than be silently skipped.
    @discardableResult
    public static func patch(
        at url: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(&data, dryRun: dryRun, log: log)
        if !dryRun, report.outcome == .patched {
            try data.write(to: url)
            log?("  [+] \(url.path): wrote \(report.sitesWritten) site(s)")
        }
        return report
    }

    /// In-memory form of ``patch(at:dryRun:log:)``.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog
    ) throws -> Report {
        if data.startIndex != 0 { data = Data(data) }

        let sites = try locateSites(in: data, log: log)
        let pending = sites.filter { $0.state == .pristine }

        guard !pending.isEmpty else {
            log?("  [.] all \(sites.count) matching site(s) already patched — nothing to do")
            return Report(outcome: .alreadyPatched, sites: sites, records: [], rehashedSlots: [])
        }
        log?("  [+] found \(sites.count) '\(sysctlName)' cache site(s), \(pending.count) to patch")

        let disassembler = ARM64Disassembler()
        var records: [PatchRecord] = []
        var modifiedOffsets: [Int] = []

        for site in pending {
            guard let value = ARM64Encoder.encodeMovzW(rd: site.valueRegisterNumber, imm16: 1) else {
                throw PatcherError.patchVerificationFailed(
                    "could not encode `mov \(site.valueRegister), #1`"
                )
            }
            let gate = ARM64.nop

            log?("    site @ add 0x\(hex(site.addVMA))  (bl 0x\(hex(site.callVMA)), "
                + "gate 0x\(hex(site.gateVMA)), value \(site.valueRegister) 0x\(hex(site.valueVMA)), "
                + "strb 0x\(hex(site.storeVMA)) -> cached byte 0x\(hex(site.cachedByteVMA)))")

            records.append(record(
                in: data,
                at: site.gateFileOffset,
                virtualAddress: site.gateVMA,
                patched: gate,
                id: "\(component).hv_vmm_cache.cbnz@0x\(hex(site.gateVMA))",
                description: "NOP the cbnz w0 that skips the cached hv_vmm_present store",
                disassembler: disassembler
            ))
            records.append(record(
                in: data,
                at: site.valueFileOffset,
                virtualAddress: site.valueVMA,
                patched: value,
                id: "\(component).hv_vmm_cache.cset@0x\(hex(site.valueVMA))",
                description: "cset \(site.valueRegister) -> mov \(site.valueRegister), #1 "
                    + "(cached 'am I a VM?' byte forced to 1)",
                disassembler: disassembler
            ))

            if !dryRun {
                data.replaceSubrange(site.gateFileOffset ..< site.gateFileOffset + 4, with: gate)
                data.replaceSubrange(site.valueFileOffset ..< site.valueFileOffset + 4, with: value)
            }
            modifiedOffsets.append(site.gateFileOffset)
            modifiedOffsets.append(site.valueFileOffset)
        }

        for record in records {
            log?("      [+] 0x\(hex(UInt64(record.fileOffset))): \(record.beforeDisasm) -> \(record.afterDisasm)")
        }

        guard !dryRun else {
            log?("  [.] dry-run — nothing written, no page re-attested")
            return Report(outcome: .wouldPatch, sites: sites, records: records, rehashedSlots: [])
        }

        for directory in CFWMachOCodeSignature.unsupportedCodeDirectories(in: data) {
            log?("  [!] CodeDirectory @0x\(hex(UInt64(directory.offset))) uses hashType "
                + "\(directory.hashType); its slots are left stale")
        }

        let rehashed = try CFWMachOCodeSignature.reattest(&data, modifiedOffsets: modifiedOffsets)
        for slot in rehashed { log?("      [+] re-attest: \(slot)") }
        log?("  [+] re-attest updated \(rehashed.count) slot(s)")

        try verify(sites: pending, in: data)
        return Report(outcome: .patched, sites: sites, records: records, rehashedSlots: rehashed)
    }

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

        guard let symbols = CFWWatchdogdSymbolTargets(data: data) else {
            throw PatcherError.invalidFormat(
                "no LC_SYMTAB/LC_DYSYMTAB — \(sysctlFunction) cannot be resolved"
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
                symbols: symbols
            ) else { continue }

            if !sites.contains(where: { $0.gateVMA == site.gateVMA }) { sites.append(site) }
        }

        guard !sites.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "no '\(sysctlName)' cache site: expected an adrp+add for the cstring reaching "
                    + "\(argumentRegister), a bl \(sysctlFunction), a cbnz w0 gate, a cset wN, ne "
                    + "and a strb into a \(globalSegmentPrefix) global"
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
        symbols: CFWWatchdogdSymbolTargets
    ) -> Site? {
        // Layer 3: the call, and the import it resolves to.
        guard let callIndex = firstIndex(
            in: instructions, from: addIndex + 1, within: argumentSetupWindow,
            where: { $0.mnemonic == "bl" }
        ) else { return nil }
        let call = instructions[callIndex]
        guard let target = ARM64Encoder.decodeBranchTarget(
            insn: word(of: call), pc: call.address
        ), symbols.name(forBranchTarget: target) == sysctlFunction else { return nil }

        // Layer 2, concluded: the literal has to be the call's `name` argument,
        // not just something this stretch of code also mentions.
        guard passesLiteral(
            inRegister: pointerRegister, from: addIndex, toCallAt: callIndex, in: instructions
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
            }
        ) else { return nil }
        let value = instructions[valueIndex]
        guard let valueRegister = registerName(value, 0),
              let valueNumber = wRegisterNumber(valueRegister) else { return nil }

        // Layer 5: the store of that same register into an ADRP-relative
        // __DATA address — the cached global.
        guard let storeIndex = firstIndex(
            in: instructions, from: valueIndex + 1, within: valueToStoreWindow,
            where: { $0.mnemonic == "strb" && registerName($0, 0) == valueRegister }
        ) else { return nil }
        let store = instructions[storeIndex]
        guard let memory = memoryOperand(store) else { return nil }
        guard let basePage = pageAddress(
            ofRegister: UInt32(memory.base.rawValue),
            before: storeIndex, notBefore: addIndex, in: instructions
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
            cachedByteVMA: cachedByte
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
        in instructions: [Instruction]
    ) -> Bool {
        if pointer == argumentRegister { return true }
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
        sections: [String: MachOSectionInfo]
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

    // MARK: - Verification

    /// Read the patched words back out and confirm they are what was written.
    static func verify(sites: [Site], in data: Data) throws {
        for site in sites {
            let gate = data.subdata(in: site.gateFileOffset ..< site.gateFileOffset + 4)
            guard gate == ARM64.nop else {
                throw PatcherError.patchVerificationFailed(
                    "gate at 0x\(hex(site.gateVMA)) reads \(gate.hex) after write"
                )
            }
            let value = data.subdata(in: site.valueFileOffset ..< site.valueFileOffset + 4)
            guard value == ARM64Encoder.encodeMovzW(rd: site.valueRegisterNumber, imm16: 1) else {
                throw PatcherError.patchVerificationFailed(
                    "value at 0x\(hex(site.valueVMA)) reads \(value.hex) after write"
                )
            }
        }
    }

    // MARK: - Records

    static func record(
        in data: Data,
        at fileOffset: Int,
        virtualAddress: UInt64,
        patched: Data,
        id: String,
        description: String,
        disassembler: ARM64Disassembler
    ) -> PatchRecord {
        let original = data.subdata(in: fileOffset ..< fileOffset + patched.count)
        return PatchRecord(
            patchID: id,
            component: component,
            fileOffset: fileOffset,
            virtualAddress: virtualAddress,
            originalBytes: original,
            patchedBytes: patched,
            beforeDisasm: text(of: original, at: virtualAddress, disassembler),
            afterDisasm: text(of: patched, at: virtualAddress, disassembler),
            description: description
        )
    }

    static func text(of word: Data, at address: UInt64, _ disassembler: ARM64Disassembler) -> String {
        guard let instruction = disassembler.disassembleOne(word, at: address) else { return "???" }
        return instruction.operandString.isEmpty
            ? instruction.mnemonic
            : "\(instruction.mnemonic) \(instruction.operandString)"
    }

    // MARK: - Instruction helpers

    /// Index of the first instruction at or after `from` that satisfies
    /// `predicate`, within `within` instructions. A word Capstone could not
    /// decode ends the window: past it the stream is no longer this function's
    /// instructions.
    static func firstIndex(
        in instructions: [Instruction],
        from: Int,
        within: Int,
        where predicate: (Instruction) -> Bool
    ) -> Int? {
        guard from >= 0 else { return nil }
        let end = min(instructions.count, from + within)
        var index = from
        while index < end {
            guard instructions[index].id != 0 else { return nil }
            if predicate(instructions[index]) { return index }
            index += 1
        }
        return nil
    }

    /// Page address an ADRP put in `register`, searching back from `before`
    /// (exclusive) no further than `notBefore`.
    static func pageAddress(
        ofRegister register: UInt32,
        before: Int,
        notBefore: Int,
        in instructions: [Instruction]
    ) -> UInt64? {
        var index = before - 1
        while index >= notBefore {
            let instruction = instructions[index]
            if instruction.mnemonic == "adrp", registerNumber(instruction, 0) == register,
               let page = immediate(instruction, 1)
            {
                return UInt64(bitPattern: page)
            }
            index -= 1
        }
        return nil
    }

    /// True for `mov wN, #1` in any encoding Capstone aliases to it (MOVZ, and
    /// the ORR-immediate form) — the shape this patch writes.
    static func isMoveOfOne(_ instruction: Instruction) -> Bool {
        guard instruction.mnemonic == "mov",
              let register = registerName(instruction, 0), register.hasPrefix("w"),
              let value = immediate(instruction, 1)
        else { return false }
        return value == 1
    }

    /// The instruction's raw little-endian word, for the branch decoder.
    static func word(of instruction: Instruction) -> UInt32 {
        var value: UInt32 = 0
        for byte in instruction.bytes.prefix(4).reversed() { value = (value << 8) | UInt32(byte) }
        return value
    }

    static func registerName(_ instruction: Instruction, _ index: Int) -> String? {
        guard let operands = instruction.aarch64?.operands, index < operands.count,
              operands[index].type == AARCH64_OP_REG
        else { return nil }
        return sharedDisassembler.registerName(UInt32(operands[index].reg.rawValue))
    }

    static func registerNumber(_ instruction: Instruction, _ index: Int) -> UInt32? {
        guard let operands = instruction.aarch64?.operands, index < operands.count,
              operands[index].type == AARCH64_OP_REG
        else { return nil }
        return UInt32(operands[index].reg.rawValue)
    }

    static func immediate(_ instruction: Instruction, _ index: Int) -> Int64? {
        guard let operands = instruction.aarch64?.operands, index < operands.count,
              operands[index].type == AARCH64_OP_IMM
        else { return nil }
        return operands[index].imm
    }

    static func memoryOperand(_ instruction: Instruction) -> aarch64_op_mem? {
        guard let operands = instruction.aarch64?.operands,
              let operand = operands.first(where: { $0.type == AARCH64_OP_MEM })
        else { return nil }
        return operand.mem
    }

    /// `"w8"` -> 8. `wzr` is rejected: the patch re-encodes this register as
    /// the destination of a `mov #1`, which is meaningless for the zero
    /// register and would mean the shape was misread.
    static func wRegisterNumber(_ name: String) -> UInt32? {
        guard name.hasPrefix("w"), let number = UInt32(name.dropFirst()), number <= 30 else { return nil }
        return number
    }

    /// Capstone handle used only for register-name lookups, which need no
    /// per-call state.
    static let sharedDisassembler = ARM64Disassembler()

    // MARK: - Addresses

    static func fileOffset(of address: UInt64, in text: MachOSectionInfo) -> Int {
        Int(text.fileOffset) + Int(address &- text.address)
    }

    static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}

// MARK: - Symbol targets

/// Resolves a branch target to the name of the function it calls.
///
/// Two paths, because a call can reach a function either way:
///
///   * through a stub section (`S_SYMBOL_STUBS`, which is what `__auth_stubs`
///     is), whose entries map one-to-one onto a window of the indirect symbol
///     table — the classic Mach-O import lookup, and the one watchdogd's
///     `bl _sysctlbyname` takes;
///   * directly to a defined symbol, for a statically linked build.
///
/// This is deliberately not in `MachOParser`: it needs each section's `flags`,
/// `reserved1` and `reserved2` and the `LC_DYSYMTAB` indirect table, none of
/// which that shared parser exposes. It carries this patcher's name because
/// this patcher is its only caller — the first time a second one needs the same
/// lookup, move it to `Binary/` under a neutral name rather than growing a copy.
struct CFWWatchdogdSymbolTargets {
    /// A section of branch-island stubs, one per imported symbol.
    struct StubSection {
        let address: UInt64
        let size: UInt64
        /// `reserved2` — bytes per stub.
        let entrySize: UInt64
        /// `reserved1` — index of this section's first indirect symbol.
        let firstIndirectIndex: Int
    }

    let data: Data
    let symbolOffset: Int
    let symbolCount: Int
    let stringOffset: Int
    let stringSize: Int
    let indirectOffset: Int
    let indirectCount: Int
    let stubSections: [StubSection]

    static let machMagic64: UInt32 = 0xFEED_FACF
    static let lcSegment64: UInt32 = 0x19
    static let lcDysymtab: UInt32 = 0x0B
    /// `SECTION_TYPE` of a stub section.
    static let sectionTypeSymbolStubs: UInt32 = 0x08
    /// Indirect entries that name no import.
    static let indirectSymbolLocal: UInt32 = 0x8000_0000
    static let indirectSymbolAbs: UInt32 = 0x4000_0000
    /// `N_STAB` — a debug entry, never a call target name.
    static let symbolIsDebug: UInt8 = 0xE0

    init?(data: Data) {
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count > 32, data.loadLE(UInt32.self, at: 0) == Self.machMagic64 else { return nil }
        guard let symtab = MachOParser.parseSymtab(from: data) else { return nil }

        var indirectOffset = 0
        var indirectCount = 0
        var stubs: [StubSection] = []

        let commandCount = data.loadLE(UInt32.self, at: 16)
        var offset = 32
        for _ in 0 ..< commandCount {
            guard offset + 8 <= data.count else { return nil }
            let command = data.loadLE(UInt32.self, at: offset)
            let commandSize = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard commandSize > 0 else { return nil }

            if command == Self.lcDysymtab, offset + 64 <= data.count {
                indirectOffset = Int(data.loadLE(UInt32.self, at: offset + 56))
                indirectCount = Int(data.loadLE(UInt32.self, at: offset + 60))
            } else if command == Self.lcSegment64, offset + 72 <= data.count {
                let sectionCount = data.loadLE(UInt32.self, at: offset + 64)
                var section = offset + 72
                for _ in 0 ..< sectionCount {
                    guard section + 80 <= data.count else { break }
                    let flags = data.loadLE(UInt32.self, at: section + 64)
                    let entrySize = UInt64(data.loadLE(UInt32.self, at: section + 72)) // reserved2
                    if flags & 0xFF == Self.sectionTypeSymbolStubs, entrySize > 0 {
                        stubs.append(StubSection(
                            address: data.loadLE(UInt64.self, at: section + 32),
                            size: data.loadLE(UInt64.self, at: section + 40),
                            entrySize: entrySize,
                            firstIndirectIndex: Int(data.loadLE(UInt32.self, at: section + 68)) // reserved1
                        ))
                    }
                    section += 80
                }
            }
            offset += commandSize
        }

        self.data = data
        symbolOffset = symtab.symoff
        symbolCount = symtab.nsyms
        stringOffset = symtab.stroff
        stringSize = symtab.strsize
        self.indirectOffset = indirectOffset
        self.indirectCount = indirectCount
        stubSections = stubs
    }

    /// Name of the function a `bl`/`b` to `address` ends up in, or `nil`.
    func name(forBranchTarget address: UInt64) -> String? {
        importName(atStub: address) ?? definedName(at: address)
    }

    /// The imported symbol a stub at `address` stands for.
    func importName(atStub address: UInt64) -> String? {
        guard indirectCount > 0 else { return nil }
        for section in stubSections {
            guard address >= section.address, address < section.address &+ section.size else { continue }
            let index = section.firstIndirectIndex + Int((address - section.address) / section.entrySize)
            guard index >= 0, index < indirectCount else { return nil }
            let entryOffset = indirectOffset + index * 4
            guard entryOffset + 4 <= data.count else { return nil }
            let entry = data.loadLE(UInt32.self, at: entryOffset)
            guard entry & (Self.indirectSymbolLocal | Self.indirectSymbolAbs) == 0 else { return nil }
            return symbolName(at: Int(entry))
        }
        return nil
    }

    /// A defined symbol whose value is exactly `address`.
    func definedName(at address: UInt64) -> String? {
        guard address != 0 else { return nil }
        for index in 0 ..< symbolCount {
            let entry = symbolOffset + index * 16
            guard entry + 16 <= data.count else { return nil }
            guard data[entry + 4] & Self.symbolIsDebug == 0 else { continue }
            guard data.loadLE(UInt64.self, at: entry + 8) == address else { continue }
            return symbolName(at: index)
        }
        return nil
    }

    func symbolName(at index: Int) -> String? {
        guard index >= 0, index < symbolCount else { return nil }
        let entry = symbolOffset + index * 16
        guard entry + 4 <= data.count else { return nil }
        let stringIndex = Int(data.loadLE(UInt32.self, at: entry))
        guard stringIndex < stringSize else { return nil }
        let start = stringOffset + stringIndex
        guard start < data.count else { return nil }
        var end = start
        let limit = min(data.count, stringOffset + stringSize)
        while end < limit, data[end] != 0 { end += 1 }
        return String(data: data.subdata(in: start ..< end), encoding: .utf8)
    }
}
