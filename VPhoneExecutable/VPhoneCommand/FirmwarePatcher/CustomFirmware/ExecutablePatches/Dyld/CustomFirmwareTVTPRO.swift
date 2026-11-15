import Foundation
import MachOKit
import VPhoneCoreKit
import VPhonePatchKit

/// Apple dyld enables TPRO mappings from kernel Apple parameters, while its
/// hardware writable scopes are compiled only for arm64e (common/Defines.h).
/// This opt-in plain-arm64 TV compatibility patch makes the two parameter lookups miss.
/// Page-in linking, chained/ObjC fixups and later DATA_CONST protection remain
/// intact. Both dyld images must be changed and reverted by the caller.
public enum CustomFirmwareTVTPRO {
    public static let patchID = "system-dyld-exp-tv_tpro"
    public static let stdoutLog: @Sendable (String) -> Void = { VPhoneConsole.shared.line($0) }
    public enum Outcome: String, Sendable { case patched, wouldPatch, alreadyPatched }
    public struct Site: Sendable {
        public let key: String
        public let virtualAddress: UInt64
        public let fileOffset: Int
        public let originalBytes: Data
    }
    public struct Report: Sendable {
        public let outcome: Outcome
        public let sites: [Site]
        public let records: [PatchRecord]
    }

    static let keys = ["dyld_hw_tpro", "dyld_hw_tpro_pagers"]
    static let process = "__ZN5dyld413ProcessConfig7ProcessC2EPKNS_10KernelArgsERNS_15SyscallDelegateERN3lsl9AllocatorE"
    static let stack = "__ZNK5dyld413ProcessConfig7Process16defaultTproStackEv"
    static let cacheConstructor = "__ZN5dyld413ProcessConfig9DyldCacheC2ERNS0_7ProcessERKNS0_8SecurityERKNS0_7LoggingERNS_15SyscallDelegateERN3lsl9AllocatorERKS0_"
    static let getenv = "__simple_getenv"
    static let replacement = Data("vphn".utf8)

    // MARK: - Standalone dyld

    @discardableResult
    public static func patchStandalone(
        fileAt url: URL, dryRun: Bool = false, log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        var data = try Data(contentsOf: url)
        let original = data
        let report = try patchStandalone(&data, dryRun: dryRun, log: log)
        if data != original { try data.write(to: url) }
        return report
    }

    @discardableResult
    public static func patchStandalone(
        _ data: inout Data, reattest: Bool = true, dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        let input = Data(data)
        try validateImageHeader(input)
        let sections = MachOParser.parseSections(from: input)
        let segments = MachOParser.parseSegments(from: input)
        func offset(_ address: UInt64, _ count: Int) throws -> Int {
            for segment in segments where address >= segment.vmAddr {
                let delta = address - segment.vmAddr
                guard delta < segment.vmSize, delta <= segment.fileSize,
                      UInt64(count) <= segment.fileSize - delta,
                      segment.fileOffset <= UInt64(input.count),
                      delta <= UInt64(input.count) - segment.fileOffset,
                      UInt64(count) <= UInt64(input.count) - segment.fileOffset - delta else { continue }
                return Int(segment.fileOffset + delta)
            }
            throw PatcherError.invalidFormat("TV TPRO discovery extends outside file-backed segments")
        }
        let symbols = try definedSymbols(input)
        let discovered = try discover(sections: sections, symbols: symbols) { address, count in
            let start = try offset(address, count)
            return input.subdata(in: start ..< start + count)
        }
        let sites = try discovered.map { item in
            Site(key: item.key, virtualAddress: item.address, fileOffset: try offset(item.address, 4), originalBytes: item.bytes)
        }
        let pending = sites.filter { $0.originalBytes != replacement }
        logSites(sites, log: log)
        guard !pending.isEmpty else { return Report(outcome: .alreadyPatched, sites: sites, records: []) }
        if dryRun { return Report(outcome: .wouldPatch, sites: sites, records: []) }
        var output = input
        for site in pending { output.replaceSubrange(site.fileOffset ..< site.fileOffset + 4, with: replacement) }
        if reattest {
            _ = try CustomFirmwareMachOCodeSignature.reattest(
                &output, modifiedOffsets: pending.flatMap { [$0.fileOffset, $0.fileOffset + 3] },
            )
        }
        data = output
        return Report(outcome: .patched, sites: sites,
                      records: pending.map { record($0, component: "dyld", suffix: "standalone") })
    }

    // MARK: - Native cache twin

    @discardableResult
    public static func patchCache(
        in chunks: DyldSharedCacheChunkSet, dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        let handle = try FileHandle(forReadingFrom: chunks.mainCacheURL)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: MemoryLayout<DyldCacheHeader.Layout>.size) ?? Data()
        guard head.count == MemoryLayout<DyldCacheHeader.Layout>.size,
              String(data: head.prefix(16).prefix { $0 != 0 }, encoding: .ascii) == "dyld_v1   arm64"
        else { throw PatcherError.invalidFormat("TV TPRO probe requires a complete native arm64 cache header") }
        let cache = try DyldCache(url: chunks.mainCacheURL)
        guard cache.header.platform == .tvOS, !cache.header.isSimulator,
              let constructor = try chunks.resolveLocalSymbol(process),
              chunks.mapping(forVMA: constructor)?.isExecutable == true,
              let imageAddress = try chunks.findMachOHeaderBefore(constructor),
              imageAddress >= cache.header.sharedRegionStart
        else { throw PatcherError.invalidFormat("TV TPRO probe requires native TVOS cache dyld") }
        let imageHead = try chunks.bytesAtVMA(imageAddress, length: 32)
        let commandSize = Int(imageHead.loadLE(UInt32.self, at: 20))
        guard commandSize <= 64 * 1024 else { throw PatcherError.invalidFormat("TV dyld load commands are too large") }
        let image = try chunks.bytesAtVMA(imageAddress, length: 32 + commandSize)
        try validateImageHeader(image)
        let table = try chunks.localSymbolTable()
        guard let entry = table.entry(forDylibOffset: imageAddress - cache.header.sharedRegionStart) else {
            throw PatcherError.patchSiteNotFound("TV dyld has no image-local symbol bounds")
        }
        let symbols = table.symbols(in: entry)
        let discovered = try discover(sections: MachOParser.parseSections(from: image), symbols: symbols) { address, count in
            try chunks.bytesAtVMA(address, length: count)
        }
        let sites = try discovered.map { item -> Site in
            let span = DyldSharedCacheWriteSpan(vma: item.address, length: 4)
            let translated = try chunks.fileRange(of: span)
            return Site(key: item.key, virtualAddress: item.address, fileOffset: translated.range.lowerBound, originalBytes: item.bytes)
        }
        let pending = sites.filter { $0.originalBytes != replacement }
        logSites(sites, log: log)
        guard !pending.isEmpty else { return Report(outcome: .alreadyPatched, sites: sites, records: []) }
        if dryRun { return Report(outcome: .wouldPatch, sites: sites, records: []) }
        let spans = pending.map { DyldSharedCacheWriteSpan(vma: $0.virtualAddress, length: 4) }
        // Admission precedes every write, including all pages' signature slots.
        let preview = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, dryRun: true, log: nil)
        guard preview.isFullyAttested else { throw PatcherError.patchVerificationFailed("TV TPRO keys lack covering cache signatures") }
        var records: [PatchRecord] = []
        for site in pending {
            let location = try chunks.fileRange(of: DyldSharedCacheWriteSpan(vma: site.virtualAddress, length: 4))
            _ = try chunks.write(at: site.virtualAddress, replacement)
            records.append(record(site, component: location.chunkURL.lastPathComponent, suffix: "cache"))
        }
        let attestation = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: spans, log: log)
        guard attestation.isFullyAttested else { throw PatcherError.patchVerificationFailed("TV TPRO key writes were not fully re-attested") }
        return Report(outcome: .patched, sites: sites, records: records)
    }

    // MARK: - Source-backed keys and getenv call sites

    struct Discovered { let key: String; let address: UInt64; let bytes: Data }

    static func discover(
        sections: [String: MachOSectionInfo], symbols: [String: UInt64],
        read: (UInt64, Int) throws -> Data,
    ) throws -> [Discovered] {
        guard let strings = sections["__TEXT,__cstring"], strings.size > 0, strings.size <= 1_048_576,
              let text = sections["__TEXT,__text"], text.size > 0,
              text.address <= UInt64.max - text.size,
              strings.address <= UInt64.max - strings.size,
              let getenvAddress = symbols[getenv], getenvAddress >= text.address,
              getenvAddress - text.address < text.size
        else { throw PatcherError.invalidFormat("TV dyld discovery sections or getenv symbol are absent") }
        let bytes = try read(strings.address, Int(strings.size))
        var sites: [Discovered] = []
        for key in keys {
            let renamed = "vphn" + key.dropFirst(4)
            var matches: [Int] = []
            for value in [key, renamed] {
                let needle = Data((value + "\0").utf8)
                var cursor = 0
                while cursor < bytes.count, let range = bytes.range(of: needle, in: cursor ..< bytes.count) {
                    if range.lowerBound == 0 || bytes[range.lowerBound - 1] == 0 { matches.append(range.lowerBound) }
                    cursor = range.lowerBound + 1
                }
            }
            guard matches.count == 1, let offset = matches.first else {
                throw PatcherError.patchSiteNotFound("TV dyld requires one exact original or renamed \(key) C string")
            }
            sites.append(Discovered(key: key, address: strings.address + UInt64(offset), bytes: bytes.subdata(in: offset ..< offset + 4)))
        }
        let required = [(process, keys), (stack, [keys[0]]), (cacheConstructor, [keys[1]])]
        for (name, wanted) in required {
            guard let start = symbols[name], start >= text.address, start - text.address < text.size,
                  let end = symbols.values.filter({ $0 > start && $0 <= text.address + text.size }).min(),
                  end - start <= 64 * 1024
            else { throw PatcherError.patchSiteNotFound("TV dyld requires exact bounded \(name)") }
            let instructions = ARM64Disassembler().disassemble(try read(start, Int(end - start)), at: start)
            guard instructions.allSatisfy({ $0.isDecoded && $0.size == 4 }) else {
                throw PatcherError.patchSiteNotFound("TV dyld TPRO lookup function does not decode completely")
            }
            for key in wanted {
                let address = sites.first { $0.key == key }!.address
                var matches = 0
                for index in instructions.indices where index + 3 < instructions.count {
                    let a = instructions[index], b = instructions[index + 1], call = instructions[index + 2], result = instructions[index + 3]
                    let ao = a.detail?.operands ?? [], bo = b.detail?.operands ?? [], co = call.detail?.operands ?? []
                    guard a.mnemonic == "adrp", ao.count == 2, ao[0].type == .register, ao[0].reg == .x(1),
                          ao[1].type == .immediate, ao[1].imm >= 0,
                          b.mnemonic == "add", bo.count == 3, bo[0].type == .register, bo[0].reg == .x(1),
                          bo[1].type == .register, bo[1].reg == .x(1), bo[2].type == .immediate, bo[2].imm >= 0,
                          UInt64(ao[1].imm) <= UInt64.max - UInt64(bo[2].imm),
                          UInt64(ao[1].imm) + UInt64(bo[2].imm) == address,
                          call.mnemonic == "bl", co.count == 1, co[0].type == .immediate,
                          co[0].imm >= 0, UInt64(co[0].imm) == getenvAddress
                    else { continue }
                    let ro = result.detail?.operands ?? []
                    if result.mnemonic == "cmp", ro.count == 2, ro[0].type == .register, ro[0].reg == .x(0),
                       ro[1].type == .immediate, ro[1].imm == 0, index + 4 < instructions.count,
                       instructions[index + 4].mnemonic == "cset", instructions[index + 4].detail?.conditionCode == .ne {
                        matches += 1
                    } else if result.mnemonic == "cbz", ro.count == 2, ro[0].type == .register, ro[0].reg == .x(0) {
                        matches += 1
                    }
                }
                guard matches == 1 else { throw PatcherError.patchSiteNotFound("TV dyld \(name) must read \(key) through getenv and test presence") }
            }
        }
        return sites
    }

    static func validateImageHeader(_ data: Data) throws {
        // mach_header_64: CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, MH_DYLINKER.
        guard data.count >= 32, data.loadLE(UInt32.self, at: 0) == 0xFEED_FACF,
              data.loadLE(UInt32.self, at: 4) == 0x0100_000C,
              data.loadLE(UInt32.self, at: 8) & 0x00FF_FFFF == 0,
              data.loadLE(UInt32.self, at: 12) == 7
        else { throw PatcherError.invalidFormat("TV dyld probe requires a native arm64 MH_DYLINKER") }
        let size = Int(data.loadLE(UInt32.self, at: 20))
        guard size <= data.count - 32 else { throw PatcherError.invalidFormat("Truncated TV dyld load commands") }
        let end = 32 + size
        var offset = 32
        var platforms: [UInt32] = []
        for _ in 0 ..< data.loadLE(UInt32.self, at: 16) {
            guard offset <= end - 8 else { throw PatcherError.invalidFormat("Truncated TV dyld load command") }
            let command = data.loadLE(UInt32.self, at: offset)
            let length = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard length >= 8, length <= end - offset else { throw PatcherError.invalidFormat("Invalid TV dyld load command size") }
            if command == 0x32 { // LC_BUILD_VERSION
                guard length >= 24 else { throw PatcherError.invalidFormat("Truncated TV dyld build version") }
                platforms.append(data.loadLE(UInt32.self, at: offset + 8))
            }
            offset += length
        }
        guard offset == end, platforms == [3] else { throw PatcherError.invalidFormat("TV dyld probe requires one TVOS build version") }
    }

    static func definedSymbols(_ data: Data) throws -> [String: UInt64] {
        guard let table = MachOParser.parseSymtab(from: data), table.symoff <= data.count,
              table.nsyms <= (data.count - table.symoff) / 16, table.stroff <= data.count,
              table.strsize <= data.count - table.stroff
        else { throw PatcherError.invalidFormat("TV dyld has no complete symbol table") }
        var symbols: [String: UInt64] = [:]
        for index in 0 ..< table.nsyms {
            let entry = table.symoff + index * 16
            guard data[entry + 4] & 0xE0 == 0, data[entry + 4] & 0x0E == 0x0E, data[entry + 5] != 0 else { continue }
            let stringIndex = Int(data.loadLE(UInt32.self, at: entry))
            guard stringIndex < table.strsize else { continue }
            let start = table.stroff + stringIndex
            guard let end = data[start ..< table.stroff + table.strsize].firstIndex(of: 0),
                  let name = String(data: data[start ..< end], encoding: .utf8) else { continue }
            let value = data.loadLE(UInt64.self, at: entry + 8)
            if [process, stack, cacheConstructor, getenv].contains(name), symbols[name] != nil {
                throw PatcherError.invalidFormat("Ambiguous TV dyld TPRO symbol \(name)")
            }
            symbols[name] = value
        }
        return symbols
    }

    static func logSites(_ sites: [Site], log: ((String) -> Void)?) {
        for site in sites {
            log?("  [.] TV dyld \(site.key) key at 0x\(String(site.virtualAddress, radix: 16)): \(String(decoding: site.originalBytes, as: UTF8.self)) -> vphn")
        }
    }
    static func record(_ site: Site, component: String, suffix: String) -> PatchRecord {
        PatchRecord(patchID: "\(patchID).\(suffix).\(site.key)", component: component,
                    fileOffset: site.fileOffset, virtualAddress: site.virtualAddress,
                    originalBytes: site.originalBytes, patchedBytes: replacement,
                    description: "Disable the plain-arm64 TV dyld hardware TPRO parameter lookup")
    }
}
