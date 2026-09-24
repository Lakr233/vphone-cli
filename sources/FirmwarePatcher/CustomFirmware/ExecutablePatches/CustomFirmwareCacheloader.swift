// CustomFirmwareCacheloader.swift — open launchd_cache_loader's unsecure-cache gate.
//
// Swift port of `scripts/patchers/cfw_patch_cache_loader.py`, driven today by
// `cfw.py patch-launchd-cache-loader <binary>`.
//
// What the binary does. `/usr/libexec/launchd_cache_loader` builds the XPC
// service cache launchd loads at boot. Before it will accept a cache that did
// not come from the sealed system volume it looks for the boot-arg
// `launchd_unsecure_cache=` in `kern.bootargs`:
//
//     adrp x0, "kern.bootargs" ; add x0, x0, #… ; add x1, sp, #…
//     bl   <sysctl-by-name helper>
//     cbz  x0, no_bootargs
//     ldr  x0, [sp, #…] ; cbz x0, no_bootargs
//     adrp x1, "launchd_unsecure_cache=" ; add x1, x1, #…   <- the string xref
//     mov  x2, #0
//     bl   <boot-arg lookup>                                <- the call
//     cbz  x0, skip_unsecure_cache                          <- THE GATE
//     …                                                     <- "Using unsecure cache: %s"
//
// On a VM there is no way to set that boot-arg, so the gate always takes the
// skip and the loader refuses anything but the stock cache. NOP'ing the one
// `cbz` makes the unsecure path unconditional, which is what lets a MODIFIED
// `/System/Library/xpc/launchd.plist` be loaded — the only reason this patch
// exists (`research/0_binary_patch_comparison.md`, "Allow modified
// launchd.plist"). A flavour that does not rewrite `launchd.plist` does not
// need it; see `cfw-kit/lib/base_stages.sh:stage_launchd_cache_loader`.
//
// Nothing is hardcoded. The boot-arg string is found by content in the Mach-O's
// own string sections, its ADRP+ADD xref is recovered from Capstone-decoded
// operands, the call after it is found by control flow, and the gate is the
// conditional branch that consumes that call's return register. The replacement
// is `ARM64.nop`, which ARM64Constants generated with keystone.
//
// Two deliberate divergences from the Python, both documented at the site:
//
//  1. IDEMPOTENCE. The Python is not idempotent. On a second run it walks past
//     the NOP it wrote and takes the *next* conditional branch — `cbnz x0,`
//     over the log-file `fopen` — so it silently re-opens and truncates the log
//     on every cache build. This port recognises its own output and stops.
//     `CryptexFilesystemPatcher.patchLaunchdCacheLoader` patches in place with
//     no `.bak` restore, so that second run is reachable today.
//  2. REFUSAL OVER GUESSING. The Python takes the first conditional branch it
//     sees after the call, whatever it tests. This port checks that the branch
//     really consumes the call's result and jumps forward out of the unsecure
//     path, and throws when it does not, rather than NOP'ing an unrelated
//     branch on a firmware whose shape has moved.
//
// Re-signing is OFF by default, which is what keeps this byte-identical to the
// Python: every shipped caller re-signs the whole binary afterwards (`ldid_sign`
// in `cfw_install*.sh`, `VPhoneSigner.sign` in the Swift call site), so slot
// hashes written here would be thrown away. A caller that does NOT re-sign must
// pass `reattestsCodeSignature: true` or ship a binary TXM will SIGKILL on the
// first page-in of the patched page.

import Capstone
import Foundation

/// NOPs the `launchd_unsecure_cache=` gate in `/usr/libexec/launchd_cache_loader`.
public enum CustomFirmwareCacheLoaderPatcher {
    // MARK: - Identity

    /// Component name, matching the Python's `records.set_group`.
    public static let component = "launchd_cache_loader"

    /// Record identity, matching the Python's `records.site` label so a captured
    /// reference and this port sort together.
    public static let patchID = "launchd_cache_loader.unsecure_cache_gate"

    /// Substrings that name the gate's boot-arg, most specific first. The same
    /// list the Python carries: the later three are there for a firmware that
    /// renames the boot-arg, and have never matched on a shipping build.
    public static let anchorTokens = ["unsecure_cache", "unsecure", "cache_valid", "validation"]

    // MARK: - Search windows

    /// How far an ADD may sit from the ADRP it completes. Both are emitted by
    /// the same relocation pair, so the compiler keeps them close; 8 is the
    /// Python's window.
    static let maxADRPToADDInstructions = 8

    /// How far past the string xref to look for the call it is an argument to.
    static let maxInstructionsToCall = 16

    /// How far past that call the branch on its result may sit.
    static let maxInstructionsAfterCall = 8

    /// The no-call fallback window, used only when no call follows the xref.
    static let maxFallbackInstructions = 32

    // MARK: - Results

    /// The boot-arg string the gate is built around, and the code that loads it.
    public struct Anchor: Sendable, Equatable {
        /// Which of ``anchorTokens`` matched.
        public let token: String
        /// The whole null-terminated string the token sits inside.
        public let text: String
        /// `"__TEXT,__cstring"` and the like — where the string was found.
        public let sectionName: String
        /// File offset of the string's FIRST byte, which is what code addresses.
        public let stringFileOffset: Int
        public let stringVMA: UInt64
        /// Address of the matched substring, which differs from ``stringVMA``
        /// whenever the token is not itself the start of the string.
        public let matchVMA: UInt64
        /// File offset of the ADRP that forms the string's address.
        public let referenceFileOffset: Int
        public let referenceVMA: UInt64
    }

    /// The conditional branch that skips the unsecure-cache path — or the NOP a
    /// previous run already left in its place.
    public struct Gate: Sendable, Equatable {
        public let fileOffset: Int
        public let vma: UInt64
        /// Capstone's mnemonic: `cbz`/`cbnz`/`tbz`/`tbnz`/`b.<cond>`, or `nop`
        /// when this binary has already been patched.
        public let mnemonic: String
        public let operandString: String
        /// The call whose return value the gate tests, when one was found. The
        /// fallback path leaves this `nil`.
        public let callFileOffset: Int?
        public let callVMA: UInt64?
        /// Where the branch jumps when it is taken, i.e. past the unsecure path.
        /// `nil` once the gate is a NOP and there is no target left to read.
        public let targetVMA: UInt64?

        /// True when the site already holds this patch's own output.
        public var wasAlreadyNOP: Bool {
            mnemonic == "nop"
        }

        /// How the gate reads in disassembly.
        public var text: String {
            operandString.isEmpty ? mnemonic : "\(mnemonic) \(operandString)"
        }
    }

    /// What a run did.
    public enum Outcome: String, Sendable, Equatable {
        /// The gate already held a NOP. Nothing was written.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The branch was replaced with a NOP.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        public let anchor: Anchor
        public let gate: Gate
        /// The write, in the shape the Python's reference capture records it.
        /// `nil` unless bytes actually changed.
        public let record: PatchRecord?
        /// Slot hashes recomputed, empty unless `reattestsCodeSignature` was set.
        public let reattestedSlots: [CustomFirmwareSlotRehash]

        /// Sites whose bytes this run changed. The parity number: the Python
        /// writes exactly one, and so must this.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }
    }

    /// Where progress goes when the caller does not say. The Python prints to
    /// stdout and `cfw_install*.sh` captures that, so this does too.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Patching

    /// Open the gate in the `launchd_cache_loader` at `url`.
    ///
    /// Idempotent: a binary this has already patched is reported
    /// `.alreadyPatched` and left untouched, byte for byte.
    ///
    /// - Parameter reattestsCodeSignature: recompute the code-directory slot
    ///   hash of the page the NOP lands in. Off by default because every
    ///   shipped caller re-signs the binary wholesale afterwards; a caller that
    ///   does not MUST set it, or TXM SIGKILLs the guest process.
    /// - Throws: ``PatcherError/patchSiteNotFound(_:)`` when the boot-arg
    ///   string, its xref, or a branch with the gate's shape is missing — each
    ///   of which means the firmware moved and has to stop the install rather
    ///   than be guessed at.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        dryRun: Bool = false,
        reattestsCodeSignature: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(
            &data,
            dryRun: dryRun,
            reattestsCodeSignature: reattestsCodeSignature,
            log: log,
        )
        if !dryRun, report.sitesWritten > 0 || !report.reattestedSlots.isEmpty {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form, for callers that already hold the binary.
    ///
    /// `data` is left untouched unless the run writes, so an `.alreadyPatched`
    /// or `.wouldPatch` result cannot change a byte.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        dryRun: Bool = false,
        reattestsCodeSignature: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        // Every offset below is an absolute file offset, so the buffer has to be
        // zero-based — a slice handed in by a caller is not.
        if data.startIndex != 0 {
            data = Data(data)
        }

        let located = try locateGate(in: data)
        let anchor = located.anchor
        let gate = located.gate

        if anchor.text == anchor.token {
            log?("  Found anchor '\(anchor.token)' at va:0x\(hex(anchor.stringVMA))")
        } else {
            log?("  Found anchor '\(anchor.token)' inside \"\(anchor.text)\"")
            log?("    String start: va:0x\(hex(anchor.stringVMA))  "
                + "(match at va:0x\(hex(anchor.matchVMA)))")
        }
        log?("  Found string ref at 0x\(hex(UInt64(anchor.referenceFileOffset)))")
        if let callVMA = gate.callVMA {
            log?("    Call at va:0x\(hex(callVMA)); gate tests its result")
        }

        guard !gate.wasAlreadyNOP else {
            // The Python has no such branch: it walks past its own NOP and takes
            // the next conditional branch, which on this binary is the `cbnz`
            // guarding the log-file `fopen`. Stopping here is the whole
            // difference between running the installer twice and corrupting the
            // binary on the second pass.
            log?("  [=] already NOP at 0x\(hex(UInt64(gate.fileOffset))); nothing to do")
            // Re-attestation still runs when asked for: a binary the Python
            // patched carries a stale slot hash, and this is the one call that
            // can repair it without rewriting an instruction. It returns nothing
            // when the stored hashes already match, so the idempotent case stays
            // byte-stable.
            var slots: [CustomFirmwareSlotRehash] = []
            if reattestsCodeSignature, !dryRun {
                slots = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [gate.fileOffset])
                for slot in slots {
                    log?("    re-attested \(slot)")
                }
            }
            return Report(
                outcome: .alreadyPatched,
                anchor: anchor,
                gate: gate,
                record: nil,
                reattestedSlots: slots,
            )
        }

        let nop = ARM64.nop
        let original = Data(data[gate.fileOffset ..< gate.fileOffset + nop.count])

        log?("  Before:")
        log?(context(in: data, around: gate, marking: gate.fileOffset))

        guard !dryRun else {
            log?("  [.] dry-run: would NOP \(gate.text) at 0x\(hex(UInt64(gate.fileOffset)))")
            return Report(
                outcome: .wouldPatch,
                anchor: anchor,
                gate: gate,
                record: nil,
                reattestedSlots: [],
            )
        }

        data.replaceSubrange(gate.fileOffset ..< gate.fileOffset + nop.count, with: nop)

        log?("  After:")
        log?(context(in: data, around: gate, marking: gate.fileOffset))

        let written = Data(data[gate.fileOffset ..< gate.fileOffset + nop.count])
        guard written == nop else {
            throw PatcherError.patchVerificationFailed(
                "\(component): gate at 0x\(hex(UInt64(gate.fileOffset))) reads \(written.hex) after write",
            )
        }

        var slots: [CustomFirmwareSlotRehash] = []
        if reattestsCodeSignature {
            slots = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [gate.fileOffset])
            for slot in slots {
                log?("    re-attested \(slot)")
            }
        }

        log?("  [+] NOPped at 0x\(hex(UInt64(gate.fileOffset)))")

        return Report(
            outcome: .patched,
            anchor: anchor,
            gate: gate,
            record: record(anchor: anchor, gate: gate, original: original, patched: nop),
            reattestedSlots: slots,
        )
    }

    // MARK: - Locating the gate

    /// Find the gate without touching the binary.
    ///
    /// The three failure modes are reported apart, because they mean different
    /// things: no boot-arg string at all (not this binary), a string with no
    /// xref (the check was compiled out), and an xref whose branch no longer has
    /// the gate's shape (the function was rewritten).
    public static func locateGate(in data: Data) throws -> (anchor: Anchor, gate: Gate) {
        let data = data.startIndex == 0 ? data : Data(data)
        let sections = MachOParser.parseSections(from: data)
        guard !sections.isEmpty else {
            throw PatcherError.invalidFormat("not a 64-bit Mach-O, or it carries no sections")
        }
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("__TEXT,__text not found")
        }

        var firstFound: StringHit?
        for hit in stringHits(in: data, sections: sections) {
            if firstFound == nil {
                firstFound = hit
            }
            // The code addresses the string's first byte, so that VA is tried
            // first; the substring's own VA is the Python's fallback, for a
            // compiler that split the literal.
            let candidates = hit.stringVMA == hit.matchVMA
                ? [hit.stringVMA]
                : [hit.stringVMA, hit.matchVMA]
            guard let reference = candidates.lazy.compactMap({ target in
                findStringReference(in: data, text: text, targetVMA: target)
            }).first else { continue }

            let anchor = Anchor(
                token: hit.token,
                text: hit.text,
                sectionName: hit.sectionName,
                stringFileOffset: hit.stringFileOffset,
                stringVMA: hit.stringVMA,
                matchVMA: hit.matchVMA,
                referenceFileOffset: reference.fileOffset,
                referenceVMA: reference.vma,
            )
            return try (anchor, findGate(in: data, text: text, anchor: anchor))
        }

        guard let found = firstFound else {
            throw PatcherError.patchSiteNotFound(
                "\(component): none of \(anchorTokens) appears in this binary's string sections",
            )
        }
        throw PatcherError.patchSiteNotFound(
            "\(component): \"\(found.text)\" is present but nothing in __TEXT,__text "
                + "forms its address (ADRP+ADD) — the boot-arg check looks compiled out",
        )
    }

    // MARK: - The boot-arg string

    /// One `anchorTokens` match, resolved to the whole C string around it.
    struct StringHit: Sendable, Equatable {
        let token: String
        let text: String
        let sectionName: String
        let stringFileOffset: Int
        let stringVMA: UInt64
        let matchVMA: UInt64
    }

    /// Every token match, most specific token first and, within a token,
    /// `__TEXT,__cstring` before the rest.
    ///
    /// Searching sections rather than the raw file — which is what the Python
    /// does — is what keeps a byte sequence inside the code signature or the
    /// link-edit tables from being mistaken for a string literal.
    static func stringHits(in data: Data, sections: [String: MachOSectionInfo]) -> [StringHit] {
        // A zerofill section has no file bytes, and its `offset` field is 0;
        // searching it would walk the Mach-O header instead.
        let searchable = sections.values
            .filter { $0.fileOffset > 0 && $0.size > 0 }
            .filter { Int($0.fileOffset) + Int($0.size) <= data.count }
            .sorted {
                let cstring = "__cstring"
                if ($0.sectionName == cstring) != ($1.sectionName == cstring) {
                    return $0.sectionName == cstring
                }
                return $0.fileOffset < $1.fileOffset
            }

        var hits: [StringHit] = []
        for token in anchorTokens {
            let needle = Array(token.utf8)
            for section in searchable {
                let start = Int(section.fileOffset)
                let end = start + Int(section.size)
                guard let match = firstOccurrence(of: needle, in: data, from: start, to: end) else {
                    continue
                }
                let stringStart = cStringStart(in: data, containing: match, notBefore: start)
                let stringEnd = cStringEnd(in: data, from: stringStart, notAfter: end)
                hits.append(StringHit(
                    token: token,
                    text: String(decoding: data[stringStart ..< stringEnd], as: UTF8.self),
                    sectionName: "\(section.segmentName),\(section.sectionName)",
                    stringFileOffset: stringStart,
                    stringVMA: section.address + UInt64(stringStart - start),
                    matchVMA: section.address + UInt64(match - start),
                ))
                break
            }
        }
        return hits
    }

    static func firstOccurrence(of needle: [UInt8], in data: Data, from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, to - from >= needle.count else { return nil }
        for offset in from ... (to - needle.count) {
            var matched = true
            for (index, byte) in needle.enumerated() where data[offset + index] != byte {
                matched = false
                break
            }
            if matched {
                return offset
            }
        }
        return nil
    }

    /// The first byte of the null-terminated string containing `offset`.
    ///
    /// Code forms the address of a literal's START, never of a substring inside
    /// it, so a token that matched mid-string has to be walked back before its
    /// address can be looked for.
    static func cStringStart(in data: Data, containing offset: Int, notBefore floor: Int) -> Int {
        var position = offset - 1
        while position >= floor, data[position] != 0 {
            position -= 1
        }
        return position + 1
    }

    static func cStringEnd(in data: Data, from start: Int, notAfter ceiling: Int) -> Int {
        var position = start
        while position < ceiling, data[position] != 0 {
            position += 1
        }
        return position
    }

    // MARK: - The string xref

    /// The ADRP of the first ADRP+ADD pair in `__TEXT,__text` that forms
    /// `targetVMA`.
    ///
    /// The pair need not be adjacent — the compiler interleaves other setup
    /// between them — so an ADRP is remembered per destination register and
    /// matched against a later ADD that reads it. Everything is read from
    /// Capstone's decoded operands: the ADRP's immediate is already the absolute
    /// page, and the ADD's is the page offset.
    static func findStringReference(
        in data: Data,
        text: MachOSectionInfo,
        targetVMA: UInt64,
    ) -> (fileOffset: Int, vma: UInt64)? {
        let targetPage = Int64(targetVMA & ~0xFFF)
        let targetPageOffset = Int64(targetVMA & 0xFFF)
        let disassembler = ARM64Disassembler()

        // ADRP destination register -> (instruction index, address, page).
        var pendingADRP: [UInt32: (index: Int, fileOffset: Int, vma: UInt64, page: Int64)] = [:]

        for (index, offset) in wordOffsets(of: text).enumerated() {
            let vma = text.address + UInt64(offset - Int(text.fileOffset))
            guard let instruction = disassembler.disassembleOne(in: data, at: offset, address: vma),
                  let operands = instruction.aarch64?.operands
            else { continue }

            switch instruction.mnemonic {
            case "adrp":
                guard operands.count >= 2,
                      operands[0].type == AARCH64_OP_REG,
                      operands[1].type == AARCH64_OP_IMM
                else { continue }
                pendingADRP[UInt32(operands[0].reg.rawValue)] = (index, offset, vma, operands[1].imm)

            case "add":
                guard operands.count >= 3,
                      operands[1].type == AARCH64_OP_REG,
                      operands[2].type == AARCH64_OP_IMM,
                      let adrp = pendingADRP[UInt32(operands[1].reg.rawValue)],
                      adrp.page == targetPage,
                      operands[2].imm == targetPageOffset,
                      index - adrp.index <= maxADRPToADDInstructions
                else { continue }
                return (adrp.fileOffset, adrp.vma)

            default:
                continue
            }
        }
        return nil
    }

    // MARK: - The gate

    /// The conditional branch that consumes the boot-arg lookup's result.
    ///
    /// Shape, in order: the first `bl` at or after the string xref, then the
    /// first conditional branch after that call. A `nop` reached before that
    /// branch is this patch's own output and ends the search — see the file
    /// header for why that matters.
    static func findGate(
        in data: Data,
        text: MachOSectionInfo,
        anchor: Anchor,
    ) throws -> Gate {
        let disassembler = ARM64Disassembler()
        let textEnd = Int(text.fileOffset) + Int(text.size)
        func decode(_ offset: Int) -> Instruction? {
            guard offset >= Int(text.fileOffset), offset + 4 <= textEnd else { return nil }
            return disassembler.disassembleOne(
                in: data,
                at: offset,
                address: text.address + UInt64(offset - Int(text.fileOffset)),
            )
        }

        var call: Instruction?
        for step in 0 ..< maxInstructionsToCall {
            guard let instruction = decode(anchor.referenceFileOffset + step * 4) else { break }
            // A direct `bl` only — the string is an argument to a call, and an
            // indirect `blr`/`blraa` through a register is not one this pass can
            // attribute a return value to.
            if instruction.mnemonic == "bl", branchTarget(of: instruction) != nil {
                call = instruction
                break
            }
        }

        let searchBase = call.map { Int($0.address - text.address) + Int(text.fileOffset) }
            ?? anchor.referenceFileOffset
        let window = call == nil ? maxFallbackInstructions : maxInstructionsAfterCall

        for step in 1 ... window {
            let offset = searchBase + step * 4
            guard let instruction = decode(offset) else { break }

            if instruction.mnemonic == "nop" {
                return Gate(
                    fileOffset: offset,
                    vma: instruction.address,
                    mnemonic: instruction.mnemonic,
                    operandString: instruction.operandString,
                    callFileOffset: call.map { Int($0.address - text.address) + Int(text.fileOffset) },
                    callVMA: call?.address,
                    targetVMA: nil,
                )
            }

            guard isConditionalBranch(instruction) else { continue }
            try validate(gate: instruction, in: data, text: text, after: call, disassembler)
            return Gate(
                fileOffset: offset,
                vma: instruction.address,
                mnemonic: instruction.mnemonic,
                operandString: instruction.operandString,
                callFileOffset: call.map { Int($0.address - text.address) + Int(text.fileOffset) },
                callVMA: call?.address,
                targetVMA: branchTarget(of: instruction),
            )
        }

        throw PatcherError.patchSiteNotFound(
            "\(component): no conditional branch within \(window) instructions of "
                + (call.map { "the call at 0x\(hex($0.address))" }
                    ?? "the \"\(anchor.text)\" xref at 0x\(hex(anchor.referenceVMA))"),
        )
    }

    /// Conditional branches, decided on the mnemonic Capstone produced.
    static func isConditionalBranch(_ instruction: Instruction) -> Bool {
        switch instruction.mnemonic {
        case "cbz", "cbnz", "tbz", "tbnz": true
        default: instruction.mnemonic.hasPrefix("b.")
        }
    }

    /// Reject a branch that is not the gate.
    ///
    /// Two properties have to hold, and the Python checks neither: the branch
    /// tests the register the call returned in, and it jumps FORWARD, past the
    /// unsecure-cache path it guards. A branch that fails either is some other
    /// branch, and NOP'ing it would be a silent miscompile of a boot-critical
    /// binary — so this throws instead.
    static func validate(
        gate: Instruction,
        in data: Data,
        text: MachOSectionInfo,
        after call: Instruction?,
        _ disassembler: ARM64Disassembler,
    ) throws {
        if let target = branchTarget(of: gate) {
            let textEnd = text.address + text.size
            guard target > gate.address, target < textEnd else {
                throw PatcherError.patchSiteNotFound(
                    "\(component): branch at 0x\(hex(gate.address)) jumps to 0x\(hex(target)), "
                        + "which is not forward inside __TEXT,__text — not the unsecure-cache gate",
                )
            }
        }

        guard call != nil else { return } // Fallback path: nothing to attribute.

        switch gate.mnemonic {
        case "cbz", "cbnz", "tbz", "tbnz":
            let register = disassembler.firstRegisterName(gate)
            guard register == "x0" || register == "w0" else {
                throw PatcherError.patchSiteNotFound(
                    "\(component): branch at 0x\(hex(gate.address)) tests "
                        + "\(register ?? "an unknown register"), not the call's result in x0/w0",
                )
            }
        default:
            // `b.<cond>` reads the flags, so the call's result has to reach it
            // through a flag-setting instruction on x0/w0 in between.
            guard flagSetterOnResult(between: call!, and: gate, in: data, text: text, disassembler)
            else {
                throw PatcherError.patchSiteNotFound(
                    "\(component): \(gate.mnemonic) at 0x\(hex(gate.address)) is not preceded by a "
                        + "compare of the call's result — nothing ties it to the boot-arg lookup",
                )
            }
        }
    }

    /// Whether some instruction between the call and the branch sets the flags
    /// from x0/w0 — a `cmp`/`subs`/`ands`/`tst` reading register 0.
    static func flagSetterOnResult(
        between call: Instruction,
        and gate: Instruction,
        in data: Data,
        text: MachOSectionInfo,
        _ disassembler: ARM64Disassembler,
    ) -> Bool {
        var address = call.address + 4
        while address < gate.address {
            defer { address += 4 }
            let offset = Int(address - text.address) + Int(text.fileOffset)
            guard let instruction = disassembler.disassembleOne(in: data, at: offset, address: address),
                  instruction.aarch64?.updatesFlags == true,
                  let operands = instruction.aarch64?.operands
            else { continue }
            for operand in operands where operand.type == AARCH64_OP_REG {
                let name = disassembler.registerName(UInt32(operand.reg.rawValue))
                if name == "x0" || name == "w0" {
                    return true
                }
            }
        }
        return false
    }

    /// The absolute address a branch jumps to, read from its last immediate
    /// operand, or `nil` when the instruction carries none.
    static func branchTarget(of instruction: Instruction) -> UInt64? {
        guard let operands = instruction.aarch64?.operands,
              let last = operands.last,
              last.type == AARCH64_OP_IMM,
              last.imm >= 0
        else { return nil }
        return UInt64(last.imm)
    }

    // MARK: - Recording

    private static func record(
        anchor: Anchor,
        gate: Gate,
        original: Data,
        patched: Data,
    ) -> PatchRecord {
        PatchRecord(
            patchID: patchID,
            component: component,
            fileOffset: gate.fileOffset,
            virtualAddress: gate.vma,
            originalBytes: original,
            patchedBytes: patched,
            beforeDisasm: disassemblyText(of: original, at: gate.vma),
            afterDisasm: disassemblyText(of: patched, at: gate.vma),
            // Worded as the Python words it, so a captured reference compares.
            description: "NOP the cache-validation branch gated on '\(anchor.token)'",
        )
    }

    // MARK: - Logging

    /// Five instructions around the gate, with the gate itself marked — the
    /// Python's `_log_asm` before/after block.
    private static func context(in data: Data, around gate: Gate, marking marker: Int) -> String {
        let disassembler = ARM64Disassembler()
        let start = max(gate.fileOffset - 8, 0)
        return (0 ..< 5).compactMap { step -> String? in
            let offset = start + step * 4
            guard offset + 4 <= data.count else { return nil }
            // The window starts two instructions BEFORE the gate, so the delta is
            // negative for the first steps. `UInt64(Int)` traps on a negative
            // value even under -O; wrap through the bit pattern instead.
            let vma = gate.vma &+ UInt64(bitPattern: Int64(offset - gate.fileOffset))
            guard let instruction = disassembler.disassembleOne(in: data, at: offset, address: vma)
            else { return nil }
            let tag = offset == marker ? " >>>" : "    "
            let mnemonic = instruction.mnemonic.count < 8
                ? instruction.mnemonic.padding(toLength: 8, withPad: " ", startingAt: 0)
                : instruction.mnemonic
            // Laid out by hand rather than with `String(format:)`: `%X` consumes
            // 32 bits, and every offset here is an `Int`.
            return "   \(tag) 0x\(hex(UInt64(offset), padTo: 8)): \(mnemonic) \(instruction.operandString)"
        }.joined(separator: "\n")
    }

    private static func disassemblyText(of bytes: Data, at vma: UInt64) -> String {
        ARM64Disassembler()
            .disassemble(bytes, at: vma)
            .map { $0.operandString.isEmpty ? $0.mnemonic : "\($0.mnemonic) \($0.operandString)" }
            .joined(separator: "; ")
    }

    // MARK: - Helpers

    /// Every 4-byte instruction offset in a section, in order.
    static func wordOffsets(of section: MachOSectionInfo) -> StrideTo<Int> {
        let start = Int(section.fileOffset)
        return stride(from: start, to: start + (Int(section.size) & ~3), by: 4)
    }

    private static func hex(_ value: UInt64, padTo width: Int = 0) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
