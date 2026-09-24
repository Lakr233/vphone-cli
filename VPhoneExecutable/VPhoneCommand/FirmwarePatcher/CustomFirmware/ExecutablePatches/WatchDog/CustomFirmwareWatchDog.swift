// CustomFirmwareWatchDog.swift — force watchdogd's cached "am I a VM?" byte to 1.
//
// Port of `scripts/patchers/cfw_patch_watchdogd.py` (453 lines). EXP only.
//
// Why the patch exists
// --------------------
// The EXP variant renames the kernel's `kern.hv_vmm_present` sysctl OID
// (`KernelExperimentalPatchHvVmmRename`), so every userland caller that still asks for
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
// written offset is handed to `CustomFirmwareMachOCodeSignature` to re-hash its page.
//
// The binary is NOT re-signed with an identity. Re-signing would reset the
// code-signing identifier to the local filename, which trips launchd's
// boot-task identity check — the failure mode observed on mobile_obliterator
// before an earlier attempt was reverted. Mutating the CD does change the
// binary's cdHash; the JB kernel patch `patch_amfi_cdhash_in_trustcache`
// short-circuits AMFI's trust-cache check, and that precondition still holds.

import Capstone
import Foundation

public enum CustomFirmwareWatchDog {
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
        public let rehashedSlots: [CustomFirmwareSlotRehash]

        /// Sites whose bytes this run changed. The parity number against the
        /// Python, whose `patch_watchdogd()` returns exactly this.
        public var sitesWritten: Int {
            records.count / 2
        }
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
        log: ((String) -> Void)? = stdoutLog,
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
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }

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
                    "could not encode `mov \(site.valueRegister), #1`",
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
                disassembler: disassembler,
            ))
            records.append(record(
                in: data,
                at: site.valueFileOffset,
                virtualAddress: site.valueVMA,
                patched: value,
                id: "\(component).hv_vmm_cache.cset@0x\(hex(site.valueVMA))",
                description: "cset \(site.valueRegister) -> mov \(site.valueRegister), #1 "
                    + "(cached 'am I a VM?' byte forced to 1)",
                disassembler: disassembler,
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

        for directory in CustomFirmwareMachOCodeSignature.unsupportedCodeDirectories(in: data) {
            log?("  [!] CodeDirectory @0x\(hex(UInt64(directory.offset))) uses hashType "
                + "\(directory.hashType); its slots are left stale")
        }

        let rehashed = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: modifiedOffsets)
        for slot in rehashed {
            log?("      [+] re-attest: \(slot)")
        }
        log?("  [+] re-attest updated \(rehashed.count) slot(s)")

        try verify(sites: pending, in: data)
        return Report(outcome: .patched, sites: sites, records: records, rehashedSlots: rehashed)
    }

    // MARK: - Verification

    /// Read the patched words back out and confirm they are what was written.
    static func verify(sites: [Site], in data: Data) throws {
        for site in sites {
            let gate = data.subdata(in: site.gateFileOffset ..< site.gateFileOffset + 4)
            guard gate == ARM64.nop else {
                throw PatcherError.patchVerificationFailed(
                    "gate at 0x\(hex(site.gateVMA)) reads \(gate.hex) after write",
                )
            }
            let value = data.subdata(in: site.valueFileOffset ..< site.valueFileOffset + 4)
            guard value == ARM64Encoder.encodeMovzW(rd: site.valueRegisterNumber, imm16: 1) else {
                throw PatcherError.patchVerificationFailed(
                    "value at 0x\(hex(site.valueVMA)) reads \(value.hex) after write",
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
        disassembler: ARM64Disassembler,
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
            description: description,
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
        where predicate: (Instruction) -> Bool,
    ) -> Int? {
        guard from >= 0 else { return nil }
        let end = min(instructions.count, from + within)
        var index = from
        while index < end {
            guard instructions[index].id != 0 else { return nil }
            if predicate(instructions[index]) {
                return index
            }
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
        in instructions: [Instruction],
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
        for byte in instruction.bytes.prefix(4).reversed() {
            value = (value << 8) | UInt32(byte)
        }
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
