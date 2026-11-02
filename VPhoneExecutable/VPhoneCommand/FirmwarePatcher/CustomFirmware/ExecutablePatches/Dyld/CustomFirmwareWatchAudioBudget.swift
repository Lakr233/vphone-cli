// CustomFirmwareWatchAudioBudget.swift — let MediaExperience treat a watch VM as virtual.
//
// A watch VM has no ApplePPM, so Playback-category audio fails the MediaExperience
// power budget. MediaExperience already skips the budget for a virtual device, but
// `_CMSMDeviceState_UpdateDeviceClass` sets that flag only for two legacy
// `MGGetProductType` tokens and never asks MobileGestalt `IsVirtualDevice`, so a VM
// misses it. This NOPs the first token-mismatch branch so the classifier falls into
// its existing set-virtual block: one instruction, with the second comparison and
// the flag stores kept as anchors. watchOS 26.4 / 23T240 only; disassembly in
// `Research/Guest/watch_audio.md`.

import Foundation
import MachOKit
import VPhonePatchKit

/// Selects MediaExperience's existing virtual-device budget policy on a watch VM.
public enum CustomFirmwareWatchAudioBudget {
    public static let patchID = "filesystem-exp-watch_audio"
    public static let imagePath = "/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience"
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    static func supports(_ version: VPhoneVersion?) -> Bool {
        version?.major == 26 && version?.minor == 4
    }

    static let classifier = "_CMSMDeviceState_UpdateDeviceClass"
    static let getter = "_CMSMDeviceState_IsAVirtualDevice"
    static let consumers = ["_cmsmSystemSoundNeedsMediaBudget", "_CMSUtility_DoesSessionNeedAudioBudget"]

    /// The two legacy VM product tokens `_CMSMDeviceState_UpdateDeviceClass`
    /// compares `MGGetProductType` against, in the `mov w8, #lo` / `movk w8,
    /// #hi, lsl #16` halves the comparison is built from. 23T240: `0xfc319ad9`
    /// at the first comparison, `0x71c6787b` at the second. Read from
    /// `_CMSMDeviceState_UpdateDeviceClass` at `0x189a34620`; both must still
    /// be present or the classifier is not the one that was reviewed.
    static let legacyProductTokenHalves: [[Int64]] = [[0x9AD9, 0xFC31], [0x787B, 0x71C6]]

    public enum Outcome: String, Sendable { case patched, wouldPatch, alreadyPatched }

    public struct Site: Sendable {
        public let address: UInt64
        public let original: Data
        public var alreadyPatched: Bool { original == ARM64.nop }
    }

    public struct Report: Sendable {
        public let outcome: Outcome
        public let site: Site
        public let records: [PatchRecord]
    }

    // MARK: - Cache patch

    @discardableResult
    public static func patchCache(
        in chunks: DyldSharedCacheChunkSet, dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        let symbols = try imageSymbols(in: chunks)
        let site = try discover(symbols: symbols) { try chunks.bytesAtVMA($0, length: $1) }
        
        log?("  [.] MediaExperience VM classification at 0x\(String(site.address, radix: 16))\(site.alreadyPatched ? " (already patched)" : "")")

        if site.alreadyPatched { return Report(outcome: .alreadyPatched, site: site, records: []) }
        let span = DyldSharedCacheWriteSpan(vma: site.address, length: 4)

        let preview = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: [span], dryRun: true, log: nil)
        guard preview.isFullyAttested else {
            throw PatcherError.patchVerificationFailed("Watch audio budget: cache signature does not cover the patch")
        }

        if dryRun { return Report(outcome: .wouldPatch, site: site, records: []) }
        let location = try chunks.fileRange(of: span)
        _ = try chunks.write(at: site.address, ARM64.nop)

        let signed = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: [span], log: log)
        guard signed.isFullyAttested else {
            throw PatcherError.patchVerificationFailed("Watch audio budget: cache re-attestation failed")
        }

        let record = PatchRecord(
            patchID: "\(patchID).budget_device_class", component: location.chunkURL.lastPathComponent,
            fileOffset: location.range.lowerBound, virtualAddress: site.address,
            originalBytes: site.original, patchedBytes: ARM64.nop,
            description: "Select MediaExperience's virtual-device audio budget policy",
        )

        return Report(outcome: .patched, site: site, records: [record])
    }

    /// All required names are private local symbols; restrict lookup to this image's table entry
    static func imageSymbols(in chunks: DyldSharedCacheChunkSet) throws -> [String: UInt64] {
        let cache = try DyldCache(url: chunks.mainCacheURL)
        guard cache.header.platform == .watchOS, !cache.header.isSimulator,
              let images = cache.imageInfos else {
            throw PatcherError.invalidFormat("Watch audio budget requires a native watchOS cache")
        }

        let matches = images.filter { $0.path(in: cache) == imagePath }
        guard matches.count == 1, let image = matches.first,
              image.address >= cache.header.sharedRegionStart else {
            throw PatcherError.patchSiteNotFound("Watch audio budget: missing unique MediaExperience image")
        }

        let table = try chunks.localSymbolTable()
        guard let entry = table.entry(forDylibOffset: image.address - cache.header.sharedRegionStart) else {
            throw PatcherError.patchSiteNotFound("Watch audio budget: MediaExperience local symbols are missing")
        }

        let symbols = table.symbols(in: entry)
        for name in [classifier, getter] + consumers {
            guard let address = symbols[name], chunks.mapping(forVMA: address)?.isExecutable == true else {
                throw PatcherError.patchSiteNotFound("Watch audio budget: missing executable \(name) in MediaExperience")
            }
        }

        return symbols
    }

    // MARK: - Discovery

    static func discover(symbols: [String: UInt64], read: (UInt64, Int) throws -> Data) throws -> Site {
        func fail() -> PatcherError { .patchSiteNotFound("Watch audio budget: unexpected VM-classification control flow") }

        guard let start = symbols[classifier], let get = symbols[getter], get > start, get - start < 4096 else { throw fail() }

        let decoder = ARM64Disassembler()
        let body = try read(start, Int(get - start))
        let code = decoder.disassemble(body, at: start)
        let flag = try virtualFlagAddress(getter: get, read: read)
        try validateBudgetConsumers(symbols: symbols, getter: get, read: read)
        var sites: [Site] = []

        for i in code.indices where i >= 3 && i + 1 < code.count {
            let compare = code[i], gate = code[i + 1]
            guard compare.mnemonic == "cmp", let args = compare.detail?.operands, args.count == 2,
                  args[0].reg == .x(0), args[1].reg == .x(8),
                  gate.mnemonic == "b.ne" || gate.mnemonic == "nop" else { continue }

            // Both legacy product-token comparisons must remain present, in order.
            let prefix = code[max(0, i - 5)..<i]
            let halves = productTokenHalves(in: prefix)

            guard sites.count < legacyProductTokenHalves.count else { throw fail() }
            guard halves == legacyProductTokenHalves[sites.count],
                  prefix.contains(where: { $0.mnemonic == "bl" }) else { throw fail() }
            guard let store = flagStore(in: code, after: i, flag: flag) else { throw fail() }

            if gate.mnemonic != "nop" {
                guard gate.detail?.conditionCode == .ne, let destination = gate.detail?.operands.first,
                      destination.type == .immediate, destination.imm == Int64(store.address + 4) else { throw fail() }
            }

            let offset = Int(gate.address - start)
            sites.append(Site(address: gate.address, original: body.subdata(in: offset..<offset + 4)))
        }

        guard sites.count == 2, !sites[1].alreadyPatched else { throw fail() }
        return sites[0]
    }

    // MARK: - Classifier anchors

    static func virtualFlagAddress(getter: UInt64, read: (UInt64, Int) throws -> Data) throws -> UInt64 {
        let accessor = ARM64Disassembler().disassemble(try read(getter, 12), at: getter)

        guard accessor.count == 3, accessor[0].mnemonic == "adrp", accessor[1].mnemonic == "ldrb",
              accessor[2].mnemonic == "ret",
              let page = accessor[0].detail?.operands, page.count == 2, page[1].imm >= 0,
              let load = accessor[1].detail?.operands, load.count == 2,
              load[0].reg == .w(0), load[1].type == .memory, load[1].mem.base == page[0].reg,
              load[1].mem.disp >= 0 else {
            throw PatcherError.patchSiteNotFound("Watch audio budget: unexpected virtual-device getter")
        }

        return UInt64(page[1].imm) + UInt64(load[1].mem.disp)
    }

    static func validateBudgetConsumers(
        symbols: [String: UInt64], getter: UInt64, read: (UInt64, Int) throws -> Data
    ) throws {
        for name in consumers {
            guard let address = symbols[name] else {
                throw PatcherError.patchSiteNotFound("Watch audio budget: missing budget consumer check")
            }

            let calls = ARM64Disassembler().disassemble(try read(address, 64), at: address).filter {
                $0.mnemonic == "bl" && $0.detail?.operands.first?.imm == Int64(getter)
            }

            guard calls.count == 1 else {
                throw PatcherError.patchSiteNotFound("Watch audio budget: missing budget consumer check")
            }
        }
    }

    static func productTokenHalves(in code: ArraySlice<ARM64Instruction>) -> [Int64] {
        let halves = code.compactMap { instruction -> Int64? in
            guard ["mov", "movk"].contains(instruction.mnemonic),
                  let operands = instruction.detail?.operands, operands.count == 2,
                  operands[0].type == .register, operands[0].reg == .w(8),
                  operands[1].type == .immediate else { return nil }

            if instruction.mnemonic == "movk" {
                guard operands[1].shift.type == .lsl, operands[1].shift.amount == 16 else { return nil }
            } else {
                guard operands[1].shift.amount == 0 else { return nil }
            }

            return operands[1].imm
        }

        return Array(halves.suffix(2))
    }

    static func flagStore(in code: [ARM64Instruction], after compare: Int, flag: UInt64) -> ARM64Instruction? {
        let tail = (compare + 2)..<min(code.count, compare + 19)
        for index in tail {
            let store = code[index]

            guard store.mnemonic == "strb",
                  let operands = store.detail?.operands, operands.count == 2,
                  operands[0].type == .register, operands[0].reg == .w(8),
                  operands[1].type == .memory, operands[1].mem.disp >= 0,
                  code[index - 1].mnemonic == "mov",
                  let value = code[index - 1].detail?.operands, value.count == 2,
                  value[0].reg == .w(8), value[1].type == .immediate, value[1].imm == 1,
                  let page = code[..<compare].last(where: {
                      $0.mnemonic == "adrp" && $0.detail?.operands.first?.reg == operands[1].mem.base
                  }), let pageOperands = page.detail?.operands, pageOperands.count == 2,
                  pageOperands[1].type == .immediate, pageOperands[1].imm >= 0
            else { continue }

            if UInt64(pageOperands[1].imm) + UInt64(operands[1].mem.disp) == flag { return store }
        }

        return nil
    }

}
