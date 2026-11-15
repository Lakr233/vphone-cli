// DyldSharedCacheIOMFBForceKernPatcher.swift — Route IOMobileFramebuffer presents
// to the kernel only for connections that actually have a kernel userclient.
//
// Why
// ---
// On vphone600 26.x the host `VZVirtualMachineView` is fed by the guest
// `AppleParavirtGPU` scanout, and the 26.4 kernel drives that scanout ONLY from
// the IOMFB userclient swap methods — the `_kern_Swap*` family, of which
// `_kern_SwapEnd` is external method 5. A 26.x userland presents through
// `_kern_*`, which is why the SwapEnd size patch fixed the VZ view on 26.0/18.x.
//
// iOS 27 routes the paravirt display's present through the PARALLEL `_virt_Swap*`
// family instead. `_virt_SwapEnd` performs no userclient call: it invokes an
// in-process callback and hands the composited IOSurface to a virtual-display
// consumer. Those frames never enter the kernel userclient, so the paravirt GPU
// never scans out and the host VZ window stays black — the guest still
// composites (the GUI is visible over the in-guest TrollVNC capturer) and
// AppleParavirtGPU's scheduler sits idle.
//
// What is rewritten
// -----------------
// The public `_IOMobileFramebufferSwap*` entry points are thin dispatch
// trampolines that tail-call a per-connection function pointer. On iOS 27 the
// capture display has no kernel userclient port, while the paravirtual primary
// display does. The patch therefore replaces each trampoline with:
//
//     cbz   x0, <fail>
//     ldr   w16, [x0, #0x14]       ; IOConnect port (zero for display 2)
//     cbnz  w16, _kern_Swap<Name>
//     b     _virt_Swap<Name>
//
// x16 is an intra-procedure-call scratch register, so the public ABI arguments
// remain untouched on either direct branch. The port offset is anchored by the
// `_kern_Swap*` implementations, which all pass `[x0,#0x14]` to the external
// method call.
//
// Companion kernel patch: `KernelCustomFirmwarePatcher.patchIomfbSwapEndVariableSize` /
// `…HandlerSize`, which make the 26.4 userclient accept iOS 27's native 0x6e0
// SwapEnd struct (26.x sent 0x588). Both halves are required together — forcing
// kern without the kernel size-accept makes method 5 return
// `kIOReturnBadArgument`.
//
// Entry-point addresses and both siblings are resolved by name through
// `DyldSharedCacheSymbolResolver` (export trie and cache symbols). Capstone
// verifies the trampoline's typed operands; ARM64Encoder produces the four
// replacement instructions. The connection layout's port offset is 0x14 on
// the verified cache. Modified pages are re-attested through the chunk span log.
//
// Classify the complete candidate set before writing, and require Begin, End,
// and SetLayer coverage. Unlike the historical unconditional patch, only
// operations with both kern and virt siblings participate. Real-cache tests
// verify conditional routing, preserved null handling, dry-run and idempotence.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// Routes public swap trampolines to kern or virt according to the connection.
public enum DyldSharedCacheIOMFBForceKernPatcher {
    /// The image that carries the public entry points and their siblings.
    public static let imagePath =
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

    /// Prefix of the public entry points. Everything after it names the swap
    /// operation: `_IOMobileFramebufferSwapEnd` → `End`.
    public static let publicPrefix = "_IOMobileFramebufferSwap"

    /// Prefix of the kernel-path siblings. `End` → `_kern_SwapEnd`.
    public static let kernPrefix = "_kern_Swap"
    public static let virtPrefix = "_virt_Swap"

    /// The present transaction the render server drives. Discovery finds
    /// whatever the cache has, but these three must come out covered or the
    /// patch is not meaningful: a half-forced swap path is incoherent — some
    /// calls reaching the kernel userclient, some staying in-process — and
    /// shipping it is worse than not patching at all.
    public static let requiredSuffixes: [String] = ["SwapBegin", "SwapEnd", "SwapSetLayer"]

    /// Record group name, matching `records.set_group("iomfb_force_kern")`.
    public static let recordGroup = "dyld-boot-iomfb_force_kern"

    /// Where diagnostics go when the caller does not say. Mirrors the
    /// reference's `print`, so the two runs can be diffed line by line.
    public static let stdoutLog: @Sendable (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    // MARK: - Model

    /// A public entry point with its kernel and in-process implementations.
    public struct EntryPoint: Sendable, Hashable {
        /// The swap operation, spelled as the reference spells it in a record
        /// ID: `SwapEnd`, not `End`.
        public let suffix: String
        public let publicName: String
        public let publicAddress: UInt64
        public let kernName: String
        public let kernAddress: UInt64
        public let virtName: String
        public let virtAddress: UInt64
    }

    /// What was decided about one entry point.
    public enum Disposition: String, Sendable {
        /// A thin trampoline rewritten to the conditional four-instruction form.
        case forced
        /// Already `b _kern_Swap<Name>` — a previous run did it.
        case alreadyForced
        /// Already conditional on the per-connection kernel port.
        case alreadyConditional
        /// Not a thin dispatch trampoline; left on whatever path it had.
        case notATrampoline
    }

    /// One entry point and its disposition.
    public struct Site: Sendable {
        public let entry: EntryPoint
        public let disposition: Disposition
        /// The first instruction as it was found, e.g. `cbz x0, #0x22ac0c1c0`.
        public let originalDisassembly: String
        public let failureAddress: UInt64
    }

    /// What one run did.
    public struct Outcome: Sendable {
        /// Every discovered pair, in the order they were considered.
        public let sites: [Site]
        /// One record per site written, for the Python/Swift record comparison.
        public let records: [PatchRecord]
        /// The re-attestation pass, or `nil` when nothing was written.
        public let reattestation: DyldSharedCacheReattestation?

        public var forced: [Site] {
            sites.filter { $0.disposition == .forced }
        }

        public var alreadyForced: [Site] {
            sites.filter { $0.disposition == .alreadyForced }
        }

        public var alreadyConditional: [Site] {
            sites.filter { $0.disposition == .alreadyConditional }
        }

        public var notTrampolines: [Site] {
            sites.filter { $0.disposition == .notATrampoline }
        }

        /// How many 4-byte sites this run put on disk. The reference returns
        /// exactly this number.
        public var writtenSiteCount: Int {
            forced.count
        }

        /// Suffixes now on the kern path, whether this run did it or a previous
        /// one did.
        public var coveredSuffixes: Set<String> {
            Set(sites.filter { $0.disposition != .notATrampoline }.map(\.entry.suffix))
        }
    }

    // MARK: - Entry points

    /// Force-kern the cache under `chunksDirectory`.
    ///
    /// - Returns: the outcome, whose `writtenSiteCount` is what the reference
    ///   returns.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Outcome {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, captureUndo: captureUndo)
        defer {
            if captureUndo, let undo = chunks.takeUndoLog() {
                onUndo?(undo)
            }
        }
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        return try patch(chunks: chunks, resolver: resolver, dryRun: dryRun, log: log)
    }

    /// Force-kern a cache that is already open.
    ///
    /// Re-attestation consumes `chunks.recordedWrites`, so anything written
    /// through this chunk set earlier in the same session is re-attested here
    /// too. That is the intended direction: over-attesting a page costs one
    /// SHA-256, under-attesting one is a page fault the guest dies on.
    @discardableResult
    public static func patch(
        chunks: DyldSharedCacheChunkSet,
        resolver: DyldSharedCacheSymbolResolver,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Outcome {
        log?("  [.] \(chunks.chunkURLs.count) chunk(s), \(chunks.mappings.count) mapping(s)")

        // `_kern_Swap*` are stripped local symbols, so without the `.symbols`
        // side file discovery would find zero pairs and report it as "this
        // cache has no such functions".
        try resolver.requireLocalSymbols()

        let disassembler = ARM64Disassembler()
        let entries = try discoverEntryPoints(resolver: resolver)

        // Classify everything before writing anything: the required-coverage
        // check below has to be able to refuse while the cache is still clean.
        var sites: [Site] = []
        for entry in entries {
            try sites.append(classify(entry, chunks: chunks, disassembler: disassembler))
        }

        let covered = Set(sites.filter { $0.disposition != .notATrampoline }.map(\.entry.suffix))
        let missing = requiredSuffixes.filter { !covered.contains($0) }
        guard missing.isEmpty else {
            let forcible = sites.filter { $0.disposition == .forced }.map(\.entry.suffix).sorted()
            let already = sites.filter { $0.disposition == .alreadyForced }.map(\.entry.suffix).sorted()
            throw PatcherError.patchSiteNotFound(
                "force-kern did not cover required entrypoints \(missing) "
                    + "(forcible: \(forcible); already forced: \(already))",
            )
        }

        for site in sites {
            switch site.disposition {
            case .alreadyForced:
                log?("      [=] \(site.entry.publicName) already -> conditional kern/virt dispatch (idempotent)")
            case .alreadyConditional:
                log?("      [=] \(site.entry.publicName) already -> conditional kern/virt dispatch (idempotent)")
            case .notATrampoline:
                log?("      [=] \(site.entry.publicName) not a thin trampoline; leaving on virt path")
            case .forced:
                log?(
                    "      [+] \(site.entry.publicName) @ 0x\(hex(site.entry.publicAddress)): "
                        + "'\(site.originalDisassembly)' -> 'b \(site.entry.kernName)' "
                        + "(0x\(hex(site.entry.kernAddress))) when port != 0, "
                        + "virt otherwise (0x\(hex(site.entry.virtAddress)))",
                )
            }
        }

        let toWrite = sites.filter { $0.disposition == .forced }
        guard !dryRun else {
            log?("  [.] dry-run: would force \(toWrite.count) entrypoint(s); nothing written")
            return Outcome(sites: sites, records: [], reattestation: nil)
        }

        var records: [PatchRecord] = []
        for site in toWrite {
            try records.append(force(site, chunks: chunks))
        }

        var reattestation: DyldSharedCacheReattestation?
        if records.isEmpty {
            log?(
                "  [=] all \(sites.count { $0.disposition == .alreadyForced || $0.disposition == .alreadyConditional }) entrypoint(s) "
                    + "already conditional; nothing to patch/re-attest",
            )
        } else {
            log?("  [.] re-attesting the pages \(records.count) write(s) dirtied...")
            let result = try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: log)
            guard result.isFullyAttested else {
                throw PatcherError.patchVerificationFailed(
                    "re-attestation skipped \(result.skipped.count) page(s): "
                        + result.skipped.map(\.description).joined(separator: "; "),
                )
            }
            reattestation = result
            try verify(toWrite, chunks: chunks, disassembler: disassembler)
        }

        let forcedCount = toWrite.count
        let alreadyCount = sites.count {
            $0.disposition == .alreadyForced || $0.disposition == .alreadyConditional
        }
        log?(
            "  [+] IOMFB force-kern complete: \(forcedCount) newly forced, "
                + "\(alreadyCount) already conditional",
        )
        return Outcome(sites: sites, records: records, reattestation: reattestation)
    }

    // MARK: - Discovery

    /// Every `_IOMobileFramebufferSwap*` in the image that has a `_kern_Swap*`
    /// sibling, sorted by suffix.
    ///
    /// The set is discovered rather than listed: which swap operations exist,
    /// and which of them kept a kern implementation, is a property of the cache
    /// being patched and changes between OS versions.
    public static func discoverEntryPoints(
        resolver: DyldSharedCacheSymbolResolver,
    ) throws -> [EntryPoint] {
        let all = try resolver.symbols(inImage: imagePath)
        let publicEntries = try resolver.symbols(inImage: imagePath, withPrefix: publicPrefix)

        var entries: [EntryPoint] = []
        for (publicName, publicAddress) in publicEntries {
            let suffix = "Swap" + publicName.dropFirst(publicPrefix.count)
            let kernName = kernPrefix + publicName.dropFirst(publicPrefix.count)
            let virtName = virtPrefix + publicName.dropFirst(publicPrefix.count)
            guard let kern = all[kernName], let virt = all[virtName] else { continue }
            entries.append(
                EntryPoint(
                    suffix: suffix,
                    publicName: publicName,
                    publicAddress: publicAddress,
                    kernName: kernName,
                    kernAddress: kern.address,
                    virtName: virtName,
                    virtAddress: virt.address,
                ),
            )
        }
        entries.sort { ($0.suffix, $0.publicName) < ($1.suffix, $1.publicName) }
        return entries
    }

    // MARK: - Classification

    private static func classify(
        _ entry: EntryPoint,
        chunks: DyldSharedCacheChunkSet,
        disassembler: ARM64Disassembler,
    ) throws -> Site {
        let instructions = try disassembler.disassemble(
            chunks.bytesAtVMA(entry.publicAddress, length: 4 * 4),
            at: entry.publicAddress,
            count: 4,
        )
        let first = instructions.first
        let text = first.map { "\($0.mnemonic) \($0.operandString)" } ?? "<undecodable>"

        // Idempotent: accept both the historical unconditional form and the
        // new conditional form while upgrading an already patched cache.
        if let first, first.mnemonic == "b",
           let target = immediate(first, at: 0), UInt64(bitPattern: target) == entry.kernAddress
        {
            return Site(
                entry: entry, disposition: .forced, originalDisassembly: text,
                failureAddress: entry.publicAddress + 16,
            )
        }

        if isConditionalDispatch(instructions, entry: entry) {
            return Site(
                entry: entry, disposition: .alreadyConditional, originalDisassembly: text,
                failureAddress: immediate(instructions[0], at: 1).map(UInt64.init(bitPattern:))
                    ?? entry.publicAddress + 16,
            )
        }

        let disposition: Disposition =
            isDispatchTrampoline(instructions) ? .forced : .notATrampoline
        return Site(
            entry: entry, disposition: disposition, originalDisassembly: text,
            failureAddress: immediate(instructions[0], at: 1).map(UInt64.init(bitPattern:))
                ?? entry.publicAddress + 16,
        )
    }

    private static func isConditionalDispatch(
        _ instructions: [ARM64Instruction], entry: EntryPoint,
    ) -> Bool {
        guard instructions.count >= 4,
              instructions[0].mnemonic == "cbz",
              register(instructions[0], at: 0) == .x(0),
              instructions[1].mnemonic == "ldr",
              register(instructions[1], at: 0) == .w(16),
              let memory = memory(instructions[1]), memory.base == .x(0),
              memory.index == .invalid, memory.disp == 0x14,
              instructions[2].mnemonic == "cbnz",
              register(instructions[2], at: 0) == .w(16),
              let kernTarget = firstImmediate(instructions[2]),
              UInt64(bitPattern: kernTarget) == entry.kernAddress,
              instructions[3].mnemonic == "b",
              let virtTarget = firstImmediate(instructions[3]),
              UInt64(bitPattern: virtTarget) == entry.virtAddress
        else { return false }
        return true
    }

    /// True iff the four instructions are
    /// `cbz x0, … ; ldr xN, [x0, #imm] ; cbz xN, … ; braaz xN`.
    ///
    /// Matched on typed decoded operands rather than on the operand text: the
    /// base register of the load, the register the fp lands in and the register
    /// the tail-call branches through are compared as register identities, so
    /// `x1` cannot match the `x10` that a prefix test on the printed string
    /// would accept.
    public static func isDispatchTrampoline(_ instructions: [ARM64Instruction]) -> Bool {
        guard instructions.count >= 4 else { return false }
        let (check, load, guardBranch, tailCall) =
            (instructions[0], instructions[1], instructions[2], instructions[3])

        // cbz x0, <fail> — the connection pointer.
        guard check.mnemonic == "cbz", register(check, at: 0) == .x(0) else {
            return false
        }

        // ldr xN, [x0, #slot] — the connection's swap fp. Plain base+displacement
        // only: an indexed load is reading something else.
        guard load.mnemonic == "ldr",
              let scratch = register(load, at: 0),
              let memory = memory(load),
              memory.base == .x(0),
              memory.index == .invalid,
              memory.disp != 0
        else { return false }

        // cbz xN, <fail> — the fp's own null check.
        guard guardBranch.mnemonic == "cbz", register(guardBranch, at: 0) == scratch else {
            return false
        }

        // braaz/braa/br xN — the tail-call itself, signed or not.
        guard ["braaz", "braa", "br"].contains(tailCall.mnemonic),
              register(tailCall, at: 0) == scratch
        else { return false }

        return true
    }

    // MARK: - Writing

    private static func force(_ site: Site, chunks: DyldSharedCacheChunkSet) throws -> PatchRecord {
        let entry = site.entry
        guard let portLoad = ARM64Encoder.encodeLdrWUnsignedOffset(rt: 16, rn: 0, offset: 0x14),
              let nullBranch = ARM64Encoder.encodeCompareBranch(
                  nonzero: false, register: 0,
                  from: Int(entry.publicAddress), to: Int(site.failureAddress), width64: true,
              ),
              let kernBranch = ARM64Encoder.encodeCompareBranch(
                  nonzero: true, register: 16,
                  from: Int(entry.publicAddress + 8), to: Int(entry.kernAddress),
              ),
              let virtBranch = ARM64Encoder.encodeB(
                  from: Int(entry.publicAddress + 12), to: Int(entry.virtAddress),
              ), portLoad.count == 4, kernBranch.count == 4, virtBranch.count == 4
        else {
            throw PatcherError.patchVerificationFailed(
                "cannot encode conditional IOMFB dispatch for \(entry.publicName) "
                    + "for \(entry.publicName)",
            )
        }

        var patched = Data()
        patched.append(nullBranch)
        patched.append(portLoad)
        patched.append(kernBranch)
        patched.append(virtBranch)
        let span = DyldSharedCacheWriteSpan(vma: entry.publicAddress, length: 16)
        let (chunkURL, range) = try chunks.fileRange(of: span)
        let original = try chunks.bytesAtVMA(entry.publicAddress, length: 16)
        try chunks.write(at: entry.publicAddress, patched)

        return PatchRecord(
            patchID: "\(recordGroup).\(entry.suffix)",
            component: chunkURL.lastPathComponent,
            fileOffset: range.lowerBound,
            virtualAddress: entry.publicAddress,
            originalBytes: original,
            patchedBytes: patched,
            beforeDisasm: site.originalDisassembly,
            afterDisasm: "cbz x0, fail; ldr w16, [x0,#0x14]; cbnz w16, #0x\(hex(entry.kernAddress).lowercased()); b #0x\(hex(entry.virtAddress).lowercased())",
            description: "\(entry.publicName) conditional kern/virt dispatch",
        )
    }

    /// Re-read every site after re-attestation and confirm it decodes as a
    /// branch, which is what the reference's post-write verify checks.
    private static func verify(
        _ sites: [Site],
        chunks: DyldSharedCacheChunkSet,
        disassembler: ARM64Disassembler,
    ) throws {
        for site in sites where site.disposition == .forced {
            let address = site.entry.publicAddress
            let data = try chunks.bytesAtVMA(address, length: 16)
            let instructions = disassembler.disassemble(data, at: address, count: 4)
            guard isConditionalDispatch(instructions, entry: site.entry)
            else {
                let bytes = data.map { String(format: "%02x", $0) }.joined()
                throw PatcherError.patchVerificationFailed(
                    "post-write verify failed at 0x\(hex(address)) for \(site.entry.publicName): "
                        + " bytes=\(bytes)"
                        + " insns=" + instructions.map(\.description).joined(separator: "; "),
                )
            }
        }
    }

    // MARK: - Typed operand access

    private static func register(_ instruction: ARM64Instruction, at index: Int) -> ARM64Register? {
        guard let operands = instruction.detail?.operands, index < operands.count,
              operands[index].type == .register
        else { return nil }
        return operands[index].reg
    }

    private static func immediate(_ instruction: ARM64Instruction, at index: Int) -> Int64? {
        guard let operands = instruction.detail?.operands, index < operands.count,
              operands[index].type == .immediate
        else { return nil }
        return operands[index].imm
    }

    private static func firstImmediate(_ instruction: ARM64Instruction) -> Int64? {
        instruction.detail?.operands.first(where: { $0.type == .immediate })?.imm
    }

    private static func memory(_ instruction: ARM64Instruction) -> ARM64MemoryOperand? {
        guard let operands = instruction.detail?.operands,
              let operand = operands.first(where: { $0.type == .memory })
        else { return nil }
        return operand.mem
    }

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
