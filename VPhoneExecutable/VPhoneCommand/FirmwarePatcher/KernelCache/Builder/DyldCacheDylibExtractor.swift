// DyldCacheDylibExtractor.swift — Turn a dylib inside a dyld shared cache into a standalone, loadable one.
//
// kmutil only gathers a link's inputs; the kernel collection is built by
// `libKernelCollectionBuilder.dylib` (dyld's AppCacheBuilder), which lives only
// in the shared cache. Put on disk as a dylib of its own and named in
// `DYLD_LIBRARY_PATH`, dyld loads it in place of the host's cached copy, so the
// kmutil of another macOS links with that macOS's builder on this Mac.
//
// What changes, for an arm64e image without ObjC, Swift metadata, unwind info
// or TLVs (the builder has none of them, which is checked):
//   * every segment is copied out, keeping its address modulo 4 KiB, the ADRP
//     granule, so only the ADRP page deltas move and `:lo12:` offsets hold;
//   * each slide-info pointer becomes a chained fixup (`DYLD_CHAINED_PTR_ARM64E`)
//     with its PAC key, address diversity and discriminator: a rebase into the
//     image, or a bind to the symbol a dependent exports at the target
//     (re-exports followed);
//   * branches to other images or into the cache's stub islands go to new
//     arm64e auth stubs; ADRP+LDR/ADD pairs reaching the cache's coalesced GOTs
//     or another image directly go to new GOT slots. The cache drops split-seg
//     info, so the users of an ADRP are found by a forward scan of its basic block;
//   * `__LINKEDIT` is rebuilt (chained fixups, export trie, function starts,
//     symbols with the locals the cache keeps, indirect symbols), the in-cache
//     flag cleared, and the result is signed ad hoc.

import Foundation
import VPhonePatchKit

final class DyldCacheDylibExtractor {
    struct PointerSchema: Hashable {
        var auth: Bool
        /// 0 IA, 2 DA (the slide info knows these two).
        var key: UInt8
        var addressDiversity: Bool
        var diversity: UInt16

        static let plain = PointerSchema(auth: false, key: 0, addressDiversity: false, diversity: 0)
        /// An `__auth_got` slot a stub branches through: IA, address-diversified, 0.
        static let stub = PointerSchema(auth: true, key: 0, addressDiversity: true, diversity: 0)
    }

    /// A symbol of a dependent: its ordinal, name, and the offset from it.
    struct Import: Hashable {
        let ordinal: Int
        let name: String
        let addend: Int64
    }

    struct Slot: Hashable {
        let target: Import
        let schema: PointerSchema
    }

    enum Fixup {
        case rebase(target: UInt64, schema: PointerSchema, high8: UInt8)
        case bind(target: Import, schema: PointerSchema, high8: UInt8)
    }

    enum CodeEdit {
        case adrpInternal(pc: UInt64, instruction: UInt32, target: UInt64)
        case branchInternal(pc: UInt64, instruction: UInt32, target: UInt64)
        case branchStub(pc: UInt64, instruction: UInt32, target: Import)
        case adrpSlots(pc: UInt64, instruction: UInt32, slots: [Slot])
        case loadSlot(pc: UInt64, instruction: UInt32, slot: Slot)
        case addSlot(pc: UInt64, instruction: UInt32, slot: Slot)
        case addToLoad(pc: UInt64, instruction: UInt32, slot: Slot)
    }

    static let pageSize: UInt64 = 0x4000
    static let inCacheFlag: UInt32 = 0x8000_0000

    let cache: DyldSharedCache
    let image: DyldCacheImage
    private(set) var warnings: [String] = []
    private(set) var statistics: [String: Int] = [:]

    private var symbols: [UInt64: (ordinal: Int, name: String)] = [:]
    private var symbolAddresses: [UInt64] = []
    private var segments: [DyldCacheImage.Segment] = []
    private var imports: [Import: Int] = [:]
    private var slots: [Slot: Int] = [:]
    private var stubs: [Import: Int] = [:]
    private var dataFixups: [UInt64: Fixup] = [:]
    private var codeEdits: [CodeEdit] = []
    private var stubBase: UInt64 = 0
    private var slotBase: UInt64 = 0
    private var linkeditOffset: UInt64 = 0
    private var bytes: [UInt8] = []
    private var fixups: [UInt64: Fixup] = [:]
    /// `__unwind_info` personality entries: where each is, and the slot it names.
    private var personalities: [(offset: UInt64, target: PersonalityTarget)] = []

    enum PersonalityTarget {
        case own(UInt64)
        case slot(Slot)
    }

    init(cache: DyldSharedCache, path: String) throws {
        self.cache = cache
        guard let image = try cache.image(path) else {
            throw PatcherError.fileNotFound("\(path) in the dyld shared cache \(cache.path.path)")
        }
        self.image = image
        try buildSymbolMap()
    }

    /// Extracts `path` from the cache at `cache` into `output`, signed ad hoc.
    @discardableResult
    static func extract(cache: URL, path: String, to output: URL) throws -> DyldCacheDylibExtractor {
        let extractor = try DyldCacheDylibExtractor(cache: DyldSharedCache(path: cache), path: path)
        try extractor.analyze()
        extractor.layout()
        try extractor.build()
        try extractor.write(to: output)
        return extractor
    }

    private func count(_ key: String) {
        statistics[key, default: 0] += 1
    }

    // MARK: - Symbols of the dependents

    private func reach(_ image: DyldCacheImage, _ name: String, depth: Int = 0) throws -> UInt64? {
        guard depth <= 8, let export = try image.export(name) else { return nil }
        if export.flags & 0x8 != 0 {
            let index = Int(export.value) - 1
            guard image.dependencies.indices.contains(index), let dependency = try cache.image(image.dependencies[index].path) else { return nil }
            return try reach(dependency, export.importName.flatMap { $0.isEmpty ? nil : $0 } ?? name, depth: depth + 1)
        }
        if export.flags & 3 == 2 {
            return nil
        }
        return image.address + export.value
    }

    /// Every address `image` and what it re-exports name, the first name kept.
    private func collect(_ image: DyldCacheImage?, seen: inout Set<String>) throws -> [(UInt64, String)] {
        guard let image, seen.insert(image.path).inserted else { return [] }
        var out: [(UInt64, String)] = []
        var have = Set<UInt64>()
        for (name, export) in try image.exports() {
            let address: UInt64?
            if export.flags & 0x8 != 0 {
                address = try reach(image, name)
            } else if export.flags & 3 == 2 {
                continue
            } else {
                address = image.address + export.value
            }
            if let address, have.insert(address).inserted {
                out.append((address, name))
            }
        }
        for dependency in image.dependencies where dependency.command == DyldCacheImage.reexportDylib {
            for (address, name) in try collect(cache.image(dependency.path), seen: &seen) where have.insert(address).inserted {
                out.append((address, name))
            }
        }
        return out
    }

    private func buildSymbolMap() throws {
        for (index, dependency) in image.dependencies.enumerated() {
            guard let dependent = try cache.image(dependency.path) else {
                warnings.append("dependent not in the cache: \(dependency.path)")
                continue
            }
            var seen = Set<String>()
            for (address, name) in try collect(dependent, seen: &seen) where symbols[address] == nil {
                symbols[address] = (index + 1, name)
            }
        }
        symbolAddresses = symbols.keys.sorted()
    }

    /// An address in another image as a dependent's symbol (plus an offset).
    private func resolve(_ address: UInt64, _ what: @autoclosure () -> String) throws -> Import {
        if let symbol = symbols[address] {
            return Import(ordinal: symbol.ordinal, name: symbol.name, addend: 0)
        }
        var low = 0
        var high = symbolAddresses.count
        while low < high {
            let middle = (low + high) / 2
            if symbolAddresses[middle] <= address {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low > 0, address - symbolAddresses[low - 1] < 0x10000 {
            let base = symbolAddresses[low - 1]
            let symbol = symbols[base]!
            warnings.append(String(format: "%@ 0x%llx resolved as %@+0x%llx", what(), address, symbol.name, address - base))
            return Import(ordinal: symbol.ordinal, name: symbol.name, addend: Int64(address - base))
        }
        throw PatcherError.invalidFormat(String(format: "%@: target 0x%llx is no symbol a dependent of %@ exports", what(), address, image.path))
    }

    // MARK: - Addresses

    private func ownSegment(_ address: UInt64, endInclusive: Bool = false) -> DyldCacheImage.Segment? {
        segments.first { $0.address <= address && address < $0.address + $0.size || endInclusive && address == $0.address + $0.size }
    }

    private func coveringSegment(_ address: UInt64) -> DyldCacheImage.Segment? {
        segments.first { $0.coverStart <= address && address < $0.coverEnd }
    }

    /// An image address as an offset in the standalone dylib.
    private func map(_ address: UInt64) throws -> UInt64 {
        guard let segment = ownSegment(address, endInclusive: true) ?? coveringSegment(address) else {
            throw PatcherError.invalidFormat(String(format: "0x%llx is not in %@", address, image.path))
        }
        return segment.newOffset + (address - segment.coverStart)
    }

    private func inStubSection(_ address: UInt64) -> Bool {
        segments.contains { $0.sections.contains { $0.flags & 0xFF == 8 && $0.address <= address && address < $0.address + $0.size } }
    }

    /// Follows the cache's stub islands and stubs to the final target.
    private func followStub(_ start: UInt64) throws -> UInt64 {
        var address = start
        for _ in 0 ..< 4 {
            if let segment = ownSegment(address), segment.name == "__TEXT", !inStubSection(address) {
                return address
            }
            guard let words = try? cache.read(address, 16) else {
                return address
            }
            let w0 = words.le32(0), w1 = words.le32(4), w2 = words.le32(8)
            if w0 & 0x9F00_001F == 0x9000_0010, w1 & 0xFFC0_03FF == 0x9100_0210, w2 == 0xD61F_0200 {
                address = A64.adrpTarget(w0, pc: address) + UInt64((w1 >> 10) & 0xFFF)
                continue
            }
            if w0 & 0x9F00_001F == 0x9000_0011, w1 & 0xFFC0_03FF == 0x9100_0231, w2 == 0xF940_0230 {
                let got = A64.adrpTarget(w0, pc: address) + UInt64((w1 >> 10) & 0xFFF)
                guard let pointer = try cache.pointer(at: got) else {
                    throw PatcherError.invalidFormat(String(format: "stub at 0x%llx: its GOT slot 0x%llx holds no pointer", address, got))
                }
                address = pointer.target
                continue
            }
            if w0 & 0x9F00_001F == 0x9000_0010, w1 & 0xFFC0_03FF == 0xF940_0210, w2 == 0xD61F_0200 {
                let got = A64.adrpTarget(w0, pc: address) + UInt64((w1 >> 10) & 0xFFF) * 8
                guard let pointer = try cache.pointer(at: got) else {
                    throw PatcherError.invalidFormat(String(format: "stub at 0x%llx: its GOT slot 0x%llx holds no pointer", address, got))
                }
                address = pointer.target
                continue
            }
            return address
        }
        return address
    }

    // MARK: - Analysis

    @discardableResult
    private func importIndex(_ target: Import) -> Import {
        if imports[target] == nil {
            imports[target] = imports.count
        }
        return target
    }

    private func slot(_ target: Import, _ schema: PointerSchema) -> Slot {
        importIndex(target)
        let slot = Slot(target: target, schema: schema)
        if slots[slot] == nil {
            slots[slot] = slots.count
        }
        return slot
    }

    private func stub(_ target: Import) -> Import {
        _ = slot(target, .stub)
        if stubs[target] == nil {
            stubs[target] = stubs.count
        }
        return target
    }

    func analyze() throws {
        guard image.cpuType == 0x0100_000C, image.cpuSubtype & 0xFF == 2 else {
            throw PatcherError.invalidFormat("\(image.path) is not arm64e")
        }
        for (command, _) in image.loadCommands where command == 0x2C /* LC_ENCRYPTION_INFO_64 */ || command == 0x8000_0034 /* chained fixups */ {
            throw PatcherError.invalidFormat("\(image.path) carries load command 0x\(String(command, radix: 16)), which a cached image should not")
        }
        let unsupported = ["__objc_imageinfo", "__swift5_types", "__eh_frame", "__thread_vars"]
        for segment in image.segments {
            for section in segment.sections where unsupported.contains(section.name) && section.size > 0 {
                throw PatcherError.invalidFormat("\(image.path) has \(section.segment),\(section.name), which the extractor does not rebuild")
            }
        }
        segments = image.segments.filter { $0.name != "__LINKEDIT" }
        for segment in segments {
            segment.coverStart = segment.address & ~0xFFF
            segment.coverEnd = segment.coverStart + Self.align(segment.address + segment.size - segment.coverStart, Self.pageSize)
        }
        guard let first = segments.first, first.name == "__TEXT", first.address == image.address else {
            throw PatcherError.invalidFormat("\(image.path) does not start with __TEXT")
        }
        // Data pointers.
        for segment in segments where segment.name != "__TEXT" {
            for (address, pointer) in try cache.pointers(in: segment.address ..< segment.address + segment.size) {
                if ownSegment(pointer.target, endInclusive: true) != nil {
                    dataFixups[address] = .rebase(target: pointer.target, schema: pointer.schema, high8: pointer.high8)
                    count("rebase")
                } else {
                    if coveringSegment(pointer.target) != nil {
                        warnings.append(String(format: "pointer at 0x%llx targets 0x%llx, in its own pages but outside a segment", address, pointer.target))
                    }
                    let target = try resolve(pointer.target, String(format: "pointer at 0x%llx", address))
                    importIndex(target)
                    dataFixups[address] = .bind(target: target, schema: pointer.schema, high8: pointer.high8)
                    count("bind")
                }
            }
        }
        try analyzeUnwindInfo()
        // Code.
        for segment in segments {
            for section in segment.sections where section.flags & 0x8000_0400 != 0 {
                try scan(section)
            }
        }
    }

    private func scan(_ section: DyldCacheImage.Section) throws {
        let base = section.address
        let code = try cache.read(base, Int(section.size))
        let count = code.count / 4
        let instructions = (0 ..< count).map { code.le32(4 * $0) }
        let text = segments[0]
        for k in 0 ..< count {
            let instruction = instructions[k]
            let pc = base + UInt64(4 * k)
            if A64.isBranch(instruction) {
                let target = A64.branchTarget(instruction, pc: pc)
                if text.address <= target, target < text.address + text.size {
                    continue
                }
                let final = try followStub(target)
                if ownSegment(final) != nil {
                    codeEdits.append(.branchInternal(pc: pc, instruction: instruction, target: final))
                    continue
                }
                let symbol = try stub(resolve(final, String(format: "branch at 0x%llx", pc)))
                codeEdits.append(.branchStub(pc: pc, instruction: instruction, target: symbol))
                self.count("branch->stub")
                continue
            }
            guard A64.isADRP(instruction) else { continue }
            let page = A64.adrpTarget(instruction, pc: pc)
            let register = A64.rd(instruction)
            var uses: [(pc: UInt64, instruction: UInt32, target: UInt64)] = []
            for j in k + 1 ..< min(count, k + 96) {
                let use = instructions[j]
                if A64.isAddImmediate64(use) || A64.isLoadStoreUnsignedImmediate(use), A64.rn(use) == register {
                    var offset = UInt64((use >> 10) & 0xFFF)
                    if A64.isLoadStoreUnsignedImmediate(use) {
                        offset <<= A64.loadStoreScale(use)
                    }
                    uses.append((base + UInt64(4 * j), use, page &+ offset))
                    if A64.destination(use) == register {
                        break
                    }
                    continue
                }
                if A64.destination(use) == register || A64.isTerminator(use) || A64.isCall(use) && register < 19 {
                    break
                }
            }
            let external = uses.filter { ownSegment($0.target, endInclusive: true) == nil }
            if external.isEmpty {
                let target = uses.first?.target ?? page
                guard ownSegment(target, endInclusive: true) != nil || coveringSegment(target) != nil else {
                    throw PatcherError.invalidFormat(String(format: "ADRP at 0x%llx reaches 0x%llx, outside the image, with no visible use", pc, page))
                }
                codeEdits.append(.adrpInternal(pc: pc, instruction: instruction, target: target))
                self.count("adrp internal")
                continue
            }
            guard external.count == uses.count else {
                throw PatcherError.invalidFormat(String(format: "ADRP at 0x%llx has uses both inside and outside the image", pc))
            }
            var used: [Slot] = []
            for use in uses {
                let pointer = try cache.pointer(at: use.target)
                let named = symbols[use.target] != nil
                if A64.isLoadX(use.instruction), let pointer, !named {
                    // A load from a (coalesced) GOT slot elsewhere in the cache: its own slot, same schema.
                    let slot = try slot(resolve(pointer.target, String(format: "GOT 0x%llx (ldr at 0x%llx)", use.target, use.pc)), pointer.schema)
                    codeEdits.append(.loadSlot(pc: use.pc, instruction: use.instruction, slot: slot))
                    self.count("ldr GOT->own slot")
                    used.append(slot)
                } else if A64.isAddImmediate64(use.instruction), let pointer, !named {
                    // The address of a GOT slot (a stub's adrp/add/ldr/braa): its own slot, same schema.
                    let slot = try slot(resolve(pointer.target, String(format: "GOT 0x%llx (add at 0x%llx)", use.target, use.pc)), pointer.schema)
                    codeEdits.append(.addSlot(pc: use.pc, instruction: use.instruction, slot: slot))
                    self.count("add GOT addr->own slot")
                    used.append(slot)
                } else if A64.isAddImmediate64(use.instruction) {
                    // A GOT load the cache builder turned into adrp/add of the target: a load from a slot.
                    let slot = try slot(resolve(use.target, String(format: "add at 0x%llx", use.pc)), .plain)
                    codeEdits.append(.addToLoad(pc: use.pc, instruction: use.instruction, slot: slot))
                    self.count("add target->ldr slot")
                    used.append(slot)
                } else {
                    throw PatcherError.invalidFormat(String(format: "unsupported access at 0x%llx (%08x) to 0x%llx outside the image", use.pc, use.instruction, use.target))
                }
            }
            codeEdits.append(.adrpSlots(pc: pc, instruction: instruction, slots: used))
        }
    }

    /// `__unwind_info` keeps image offsets. Those into `__TEXT` (functions,
    /// LSDAs) hold, since `__TEXT` keeps its place; a personality names a GOT
    /// slot, often a coalesced one in another image, which becomes a slot of
    /// its own. The LSDAs' type tables may only hold catch-alls: a typed catch
    /// would name a GOT slot too, and is refused.
    private func analyzeUnwindInfo() throws {
        guard let section = segments.flatMap(\.sections).first(where: { $0.name == "__unwind_info" && $0.size > 0 }) else { return }
        let info = try cache.read(section.address, Int(section.size))
        let personalityOffset = Int(info.le32(12))
        let personalityCount = Int(info.le32(16))
        let indexOffset = Int(info.le32(20))
        let indexCount = Int(info.le32(24))
        for index in 0 ..< personalityCount {
            let entry = section.address + UInt64(personalityOffset + 4 * index)
            let slotAddress = image.address + UInt64(info.le32(personalityOffset + 4 * index))
            if ownSegment(slotAddress) != nil {
                personalities.append((entry, .own(slotAddress)))
                continue
            }
            guard let pointer = try cache.pointer(at: slotAddress) else {
                throw PatcherError.invalidFormat(String(format: "personality %d of %@ names 0x%llx, which holds no pointer", index, image.path, slotAddress))
            }
            let slot = try slot(resolve(pointer.target, String(format: "personality %d", index)), pointer.schema)
            personalities.append((entry, .slot(slot)))
        }
        guard indexCount > 0 else { return }
        let first = Int(info.le32(indexOffset + 8))
        let last = Int(info.le32(indexOffset + 12 * (indexCount - 1) + 8))
        for entry in stride(from: first, to: last, by: 8) {
            try checkLSDA(image.address + UInt64(info.le32(entry + 4)))
        }
    }

    private func checkLSDA(_ address: UInt64) throws {
        let bytes = [UInt8](try cache.read(address, 4096))
        func sleb(_ cursor: inout Int) -> Int64 {
            var result: Int64 = 0
            var shift: Int64 = 0
            while true {
                let byte = bytes[cursor]
                cursor += 1
                result |= Int64(byte & 0x7F) << shift
                shift += 7
                if byte < 0x80 {
                    return byte & 0x40 != 0 ? result - (1 << shift) : result
                }
            }
        }
        var cursor = 0
        guard bytes[cursor] == 0xFF else {
            throw PatcherError.invalidFormat(String(format: "LSDA at 0x%llx has a landing pad base", address))
        }
        cursor += 1
        let typeEncoding = bytes[cursor]
        cursor += 1
        guard typeEncoding != 0xFF else { return }
        let typeOffset = Int(try ULEB.read(bytes, &cursor))
        let typeBase = cursor + typeOffset
        let callSiteEncoding = bytes[cursor]
        cursor += 1
        let callSiteEnd = Int(try ULEB.read(bytes, &cursor)) + cursor
        var actions = Set<Int>()
        while cursor < callSiteEnd {
            for _ in 0 ..< 3 {
                if callSiteEncoding == 0x01 {
                    _ = try ULEB.read(bytes, &cursor)
                } else if callSiteEncoding == 0x03 || callSiteEncoding == 0x0B {
                    cursor += 4
                } else {
                    throw PatcherError.invalidFormat(String(format: "LSDA at 0x%llx: call site encoding 0x%02x", address, callSiteEncoding))
                }
            }
            let action = Int(try ULEB.read(bytes, &cursor))
            if action > 0 {
                actions.insert(action)
            }
        }
        var types: Int64 = 0
        for action in actions {
            var record = callSiteEnd + action - 1
            while true {
                var at = record
                let filter = sleb(&at)
                let next = at
                var after = next
                let displacement = sleb(&after)
                types = max(types, filter)
                if displacement == 0 {
                    break
                }
                record = next + Int(displacement)
            }
        }
        guard types > 0 else { return }
        guard typeEncoding == 0x9B else {
            throw PatcherError.invalidFormat(String(format: "LSDA at 0x%llx: type encoding 0x%02x", address, typeEncoding))
        }
        for index in 1 ... Int(types) {
            let entry = typeBase - 4 * index
            let value = bytes[entry ..< entry + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            guard value == 0 else {
                throw PatcherError.invalidFormat(String(format: "LSDA at 0x%llx catches a type; its type table is not rebuilt", address))
            }
        }
    }

    // MARK: - Layout

    static func align(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
        (value + alignment - 1) & ~(alignment - 1)
    }

    func layout() {
        var cursor: UInt64 = 0
        let got = ["__AUTH_CONST", "__DATA_CONST", "__AUTH", "__DATA"].lazy.compactMap { name in self.segments.first { $0.name == name } }.first
        for segment in segments {
            segment.newOffset = cursor
            var size = segment.coverEnd - segment.coverStart
            if segment.name == "__TEXT", !stubs.isEmpty {
                let start = Self.align(segment.address + segment.size, 16) - segment.coverStart
                stubBase = cursor + start
                size = Self.align(start + 16 * UInt64(stubs.count), Self.pageSize)
            }
            if segment === got, !slots.isEmpty {
                let start = Self.align(segment.address + segment.size - segment.coverStart, 0x1000)
                slotBase = cursor + start
                size = Self.align(start + 8 * UInt64(slots.count), Self.pageSize)
            }
            segment.newSize = size
            cursor += size
        }
        linkeditOffset = cursor
    }

    private func slotAddress(_ slot: Slot) -> UInt64 {
        slotBase + 8 * UInt64(slots[slot]!)
    }

    private func stubAddress(_ target: Import) -> UInt64 {
        stubBase + 16 * UInt64(stubs[target]!)
    }

    // MARK: - Emit

    private func put32(_ offset: UInt64, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(Int(offset) ..< Int(offset) + 4, with: $0) }
    }

    private func put64(_ offset: UInt64, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(Int(offset) ..< Int(offset) + 8, with: $0) }
    }

    func build() throws {
        guard slots.count * 8 <= 0x1000 else {
            throw PatcherError.invalidFormat("\(image.path) needs \(slots.count) GOT slots, more than one page holds")
        }
        bytes = [UInt8](repeating: 0, count: Int(linkeditOffset))
        for segment in segments {
            let source = try cache.read(segment.address, Int(segment.size))
            let offset = Int(segment.newOffset + (segment.address - segment.coverStart))
            bytes.replaceSubrange(offset ..< offset + source.count, with: source)
        }
        for edit in codeEdits {
            switch edit {
            case let .adrpInternal(pc, instruction, target):
                let at = try map(pc)
                try put32(at, A64.encodeADRP(instruction, pc: at, target: map(target)))
            case let .branchInternal(pc, instruction, target):
                let at = try map(pc)
                try put32(at, A64.encodeBranch(instruction, pc: at, target: map(target)))
            case let .branchStub(pc, instruction, target):
                let at = try map(pc)
                try put32(at, A64.encodeBranch(instruction, pc: at, target: stubAddress(target)))
            case let .adrpSlots(pc, instruction, used):
                let pages = Set(used.map { slotAddress($0) & ~0xFFF })
                guard pages.count == 1, let page = pages.first else {
                    throw PatcherError.invalidFormat(String(format: "ADRP at 0x%llx needs slots on several pages", pc))
                }
                let at = try map(pc)
                try put32(at, A64.encodeADRP(instruction, pc: at, target: page))
            case let .loadSlot(pc, instruction, slot):
                try put32(map(pc), instruction & ~(0xFFF << 10) | UInt32(((slotAddress(slot) & 0xFFF) >> 3) << 10))
            case let .addSlot(pc, instruction, slot):
                try put32(map(pc), instruction & ~(0xFFF << 10) | UInt32((slotAddress(slot) & 0xFFF) << 10))
            case let .addToLoad(pc, instruction, slot):
                try put32(map(pc), 0xF940_0000 | UInt32(((slotAddress(slot) & 0xFFF) >> 3) << 10) | A64.rn(instruction) << 5 | A64.rd(instruction))
            }
        }
        // adrp x17, slot@page; add x17, x17, slot@pageoff; ldr x16, [x17]; braa x16, x17
        for target in stubs.keys {
            let stub = stubAddress(target)
            let got = slotAddress(Slot(target: target, schema: .stub))
            try put32(stub, A64.encodeADRP(0x9000_0011, pc: stub, target: got))
            put32(stub + 4, 0x9100_0231 | UInt32((got & 0xFFF) << 10))
            put32(stub + 8, 0xF940_0230)
            put32(stub + 12, 0xD71F_0A11)
        }
        for (address, fixup) in dataFixups {
            switch fixup {
            case let .rebase(target, schema, high8):
                try fixups[map(address)] = .rebase(target: map(target), schema: schema, high8: high8)
            case .bind:
                try fixups[map(address)] = fixup
            }
        }
        for (offset, target) in personalities {
            let value: UInt64 = switch target {
            case let .own(address): try map(address)
            case let .slot(slot): slotAddress(slot)
            }
            try put32(map(offset), UInt32(value))
        }
        for (slot, index) in slots {
            fixups[slotBase + 8 * UInt64(index)] = .bind(target: slot.target, schema: slot.schema, high8: 0)
        }
        statistics["fixups"] = fixups.count
    }

    /// `LC_DYLD_CHAINED_FIXUPS`: one chain per page, imports with addends.
    private func chainedFixups() throws -> [UInt8] {
        var segmentStarts: [(offset: UInt64, starts: [UInt16])?] = []
        let sortedLocations = fixups.keys.sorted()
        for segment in segments {
            let locations = sortedLocations.filter { segment.newOffset <= $0 && $0 < segment.newOffset + segment.newSize }
            guard !locations.isEmpty else {
                segmentStarts.append(nil)
                continue
            }
            var starts = [UInt16](repeating: 0xFFFF, count: Int(segment.newSize / Self.pageSize))
            var byPage: [Int: [UInt64]] = [:]
            for location in locations {
                byPage[Int((location - segment.newOffset) / Self.pageSize), default: []].append(location)
            }
            for (page, list) in byPage {
                starts[page] = UInt16(list[0] - segment.newOffset - UInt64(page) * Self.pageSize)
                for (index, location) in list.enumerated() {
                    let next = index + 1 < list.count ? (list[index + 1] - location) / 8 : 0
                    guard next < 2048, location & 7 == 0 else {
                        throw PatcherError.invalidFormat(String(format: "fixup at 0x%llx cannot be chained", location))
                    }
                    var value: UInt64
                    switch fixups[location]! {
                    case let .rebase(target, schema, high8):
                        value = schema.auth
                            ? target | UInt64(schema.diversity) << 32 | (schema.addressDiversity ? 1 : 0) << 48 | UInt64(schema.key) << 49 | next << 51 | 1 << 63
                            : target | UInt64(high8) << 43 | next << 51
                    case let .bind(target, schema, _):
                        let ordinal = UInt64(imports[target]!)
                        value = schema.auth
                            ? ordinal | UInt64(schema.diversity) << 32 | (schema.addressDiversity ? 1 : 0) << 48 | UInt64(schema.key) << 49 | next << 51 | 1 << 62 | 1 << 63
                            : ordinal | next << 51 | 1 << 62
                    }
                    put64(location, value)
                }
            }
            segmentStarts.append((segment.newOffset, starts))
        }
        let segmentCount = segments.count + 1
        var startsInImage = Bytes()
        startsInImage.u32(UInt32(segmentCount))
        startsInImage.zeros(4 * segmentCount)
        for (index, entry) in segmentStarts.enumerated() {
            guard let entry else { continue }
            startsInImage.pad(to: 8)
            startsInImage.set32(4 + 4 * index, UInt32(startsInImage.count))
            var body = Bytes()
            body.u32(0) // size, below
            body.u16(UInt16(Self.pageSize))
            body.u16(1) // DYLD_CHAINED_PTR_ARM64E
            body.u64(entry.offset)
            body.u32(0) // max_valid_pointer
            body.u16(UInt16(entry.starts.count))
            for start in entry.starts {
                body.u16(start)
            }
            body.set32(0, UInt32(body.count))
            startsInImage.append(body.bytes)
        }
        var names = Bytes()
        names.append([0])
        var table = Bytes()
        for (target, _) in imports.sorted(by: { $0.value < $1.value }) {
            let nameOffset = names.count
            names.append(Array(target.name.utf8) + [0])
            guard target.ordinal < 240, nameOffset < 1 << 23 else {
                throw PatcherError.invalidFormat("import \(target.name) does not fit DYLD_CHAINED_IMPORT_ADDEND")
            }
            table.u32(UInt32(target.ordinal) | UInt32(nameOffset) << 9)
            table.u32(UInt32(bitPattern: Int32(truncatingIfNeeded: target.addend)))
        }
        let startsOffset = Int(Self.align(28, 8))
        let importsOffset = Int(Self.align(UInt64(startsOffset + startsInImage.count), 4))
        let symbolsOffset = importsOffset + table.count
        var blob = Bytes()
        for value in [0, startsOffset, importsOffset, symbolsOffset, imports.count, 2, 0] {
            blob.u32(UInt32(value))
        }
        blob.pad(to: startsOffset)
        blob.append(startsInImage.bytes)
        blob.pad(to: importsOffset)
        blob.append(table.bytes)
        blob.append(names.bytes)
        blob.pad(to: 8)
        return blob.bytes
    }

    private func exportTrie() throws -> [UInt8] {
        var entries: [ExportTrie.Entry] = []
        for (name, export) in try image.exports().sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
            if export.flags & 0x8 != 0 {
                entries.append(.init(name: name, flags: export.flags, value: export.value, other: nil, importName: export.importName))
            } else if export.flags & 3 == 2 {
                entries.append(.init(name: name, flags: export.flags, value: export.value, other: export.other, importName: nil))
            } else if export.flags & 0x10 != 0 {
                try entries.append(.init(name: name, flags: export.flags, value: map(image.address + export.value), other: map(image.address + (export.other ?? 0)), importName: nil))
            } else {
                try entries.append(.init(name: name, flags: export.flags, value: map(image.address + export.value), other: export.other, importName: nil))
            }
        }
        return ExportTrie.build(entries)
    }

    private func symbolTable() throws -> (nlist: [UInt8], count: UInt32, indirect: [UInt8], indirectCount: UInt32, strings: [UInt8]) {
        guard let symtab = image.symtab, let dysymtab = image.dysymtab else {
            throw PatcherError.invalidFormat("\(image.path) has no symbol table")
        }
        let count = Int(symtab[1])
        let list = try image.linkedit(symtab[0], UInt32(16 * count))
        let stringsAddress = try image.linkeditAddress(symtab[2])
        var strings = Bytes()
        strings.append([0x20, 0])
        var out = Bytes()
        for index in 0 ..< count {
            let entry = 16 * index
            let stringIndex = list.le32(entry)
            let type = list[list.startIndex + entry + 4]
            let section = list[list.startIndex + entry + 5]
            let description = list.le16(entry + 6)
            var value = list.le64(entry + 8)
            let name = try readCString(stringsAddress + UInt64(stringIndex))
            let nameOffset = strings.count
            strings.append(name + [0])
            if type & 0x0E == 0x0E, type & 0xE0 == 0 {
                do {
                    value = try map(value)
                } catch {
                    warnings.append(String(format: "symbol %@ at 0x%llx is not in the image", String(decoding: name, as: UTF8.self), value))
                }
            }
            out.u32(UInt32(nameOffset))
            out.append([type, section])
            out.u16(description)
            out.u64(value)
        }
        strings.pad(to: 8)
        let indirect = dysymtab[13] > 0 ? [UInt8](try image.linkedit(dysymtab[12], 4 * dysymtab[13])) : []
        return (out.bytes, UInt32(count), indirect, dysymtab[13], strings.bytes)
    }

    private func readCString(_ address: UInt64) throws -> [UInt8] {
        var out: [UInt8] = []
        var cursor = address
        while true {
            let chunk = try cache.read(cursor, 256)
            if let end = chunk.firstIndex(of: 0) {
                out += chunk[chunk.startIndex ..< end]
                return out
            }
            out += chunk
            cursor += 256
        }
    }

    private func linkeditBlob(_ command: UInt32) throws -> [UInt8]? {
        guard let body = image.loadCommands.first(where: { $0.command == command })?.body else { return nil }
        let size = body.le32(12)
        return size > 0 ? [UInt8](try image.linkedit(body.le32(8), size)) : []
    }

    func write(to output: URL) throws {
        let chains = try chainedFixups()
        let exports = try exportTrie()
        let functionStarts = try linkeditBlob(0x26)
        let dataInCode = try linkeditBlob(0x29)
        let symbols = try symbolTable()
        var linkedit = Bytes()
        var offsets: [String: (UInt32, UInt32)] = [:]
        func put(_ name: String, _ blob: [UInt8]) {
            linkedit.pad(to: 8)
            offsets[name] = (UInt32(linkeditOffset) + UInt32(linkedit.count), UInt32(blob.count))
            linkedit.append(blob)
        }
        put("chains", chains)
        put("exports", exports)
        if let functionStarts { put("starts", functionStarts) }
        if let dataInCode { put("dic", dataInCode) }
        put("symtab", symbols.nlist)
        put("indirect", symbols.indirect)
        put("strings", symbols.strings)
        linkedit.pad(to: 16)

        var commands = Bytes()
        var commandCount: UInt32 = 0
        for (command, original) in image.loadCommands {
            var body = Bytes(original)
            switch command {
            case DyldCacheImage.segment64:
                let name = original.cStringLE(at: 8, limit: 16)
                if name == "__LINKEDIT" {
                    body.set64(24, linkeditOffset)
                    body.set64(32, Self.align(UInt64(linkedit.count), Self.pageSize))
                    body.set64(40, linkeditOffset)
                    body.set64(48, UInt64(linkedit.count))
                    body.set32(56, 1)
                    body.set32(60, 1)
                } else {
                    guard let segment = segments.first(where: { $0.name == name }) else {
                        throw PatcherError.invalidFormat("segment \(name) is missing")
                    }
                    body.set64(24, segment.newOffset)
                    body.set64(32, segment.newSize)
                    body.set64(40, segment.newOffset)
                    body.set64(48, segment.newSize)
                    let protection: UInt32 = name == "__TEXT" ? 5 : 3
                    body.set32(56, protection)
                    body.set32(60, protection)
                    var flags = original.le32(68)
                    if name == "__DATA_CONST" || name == "__AUTH_CONST" {
                        flags |= 0x10 // SG_READ_ONLY
                    }
                    body.set32(68, flags)
                    for index in 0 ..< Int(original.le32(64)) {
                        let base = 72 + 80 * index
                        let address = original.le64(base + 32)
                        let size = original.le64(base + 40)
                        let type = original.le32(base + 64) & 0xFF
                        let alignment = UInt64(1) << original.le32(base + 52)
                        var mapped = try map(address)
                        if size == 0, mapped % alignment != 0 {
                            // Empty sections keep the cache's packed, unaligned address.
                            mapped = Self.align(mapped, alignment)
                        }
                        body.set64(base + 32, mapped)
                        body.set32(base + 48, [1, 0xC, 0x12].contains(type) ? 0 : UInt32(mapped))
                    }
                }
                commands.append(body.bytes)
                commandCount += 1
                if name == "__LINKEDIT" {
                    commands.u32(0x8000_0034)
                    commands.u32(16)
                    commands.u32(offsets["chains"]!.0)
                    commands.u32(offsets["chains"]!.1)
                    commandCount += 1
                }
            case DyldCacheImage.exportsTrie:
                commands.u32s([command, 16, offsets["exports"]!.0, offsets["exports"]!.1])
                commandCount += 1
            case DyldCacheImage.dyldInfoOnly:
                commands.u32s([command, 48, 0, 0, 0, 0, 0, 0, 0, 0, offsets["exports"]!.0, offsets["exports"]!.1])
                commandCount += 1
            case 0x26:
                commands.u32s([command, 16, offsets["starts"]!.0, offsets["starts"]!.1])
                commandCount += 1
            case 0x29:
                commands.u32s([command, 16, offsets["dic"]!.0, offsets["dic"]!.1])
                commandCount += 1
            case DyldCacheImage.symtab:
                commands.u32s([command, 24, offsets["symtab"]!.0, symbols.count, offsets["strings"]!.0, UInt32(symbols.strings.count)])
                commandCount += 1
            case DyldCacheImage.dysymtab:
                var values = image.dysymtab!
                values[12] = symbols.indirectCount > 0 ? offsets["indirect"]!.0 : 0
                for index in [6, 7, 8, 9, 10, 11, 14, 15, 16, 17] {
                    values[index] = 0
                }
                commands.u32s([command, 80] + values)
                commandCount += 1
            case 0x1E, 0x2E, 0x1D, 0x8000_001C:
                // Split-seg info, linker optimization hints, the signature, the cache's dyld-env: dropped.
                continue
            default:
                commands.append(body.bytes)
                commandCount += 1
            }
        }
        let firstSection = segments.flatMap(\.sections).map(\.address).min() ?? image.address
        let room = try Int(map(firstSection)) - 32
        guard commands.count + 16 <= room else {
            throw PatcherError.invalidFormat("the load commands of \(image.path) need \(commands.count + 16) bytes; the header has \(room)")
        }
        var header = Bytes()
        header.u32s([0xFEED_FACF, image.cpuType, image.cpuSubtype, image.fileType, commandCount, UInt32(commands.count), image.flags & ~Self.inCacheFlag, 0])
        bytes.replaceSubrange(0 ..< 32 + commands.count, with: header.bytes + commands.bytes)
        bytes.replaceSubrange(32 + commands.count ..< 32 + room, with: [UInt8](repeating: 0, count: room - commands.count))
        try Data(bytes + linkedit.bytes).write(to: output)
    }

    var summary: String {
        let counts = statistics.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "\(imports.count) imports, \(stubs.count) stubs, \(slots.count) GOT slots; \(counts)"
    }
}

// MARK: - Export trie

enum ExportTrie {
    struct Entry {
        let name: String
        let flags: UInt64
        let value: UInt64
        let other: UInt64?
        let importName: String?
    }

    private final class Node {
        var terminal: Entry?
        var children: [(edge: [UInt8], node: Node)] = []
        var offset = 0
    }

    /// Builds a trie of `entries`, which must be sorted by name.
    static func build(_ entries: [Entry]) -> [UInt8] {
        let items = entries.map { (Array($0.name.utf8), $0) }
        let root = make(items[...], prefix: 0)
        var nodes: [Node] = []
        func walk(_ node: Node) {
            nodes.append(node)
            for child in node.children {
                walk(child.node)
            }
        }
        walk(root)
        var changed = true
        while changed {
            changed = false
            var offset = 0
            for node in nodes {
                if node.offset != offset {
                    node.offset = offset
                    changed = true
                }
                let terminal = terminalBytes(node.terminal)
                var size = ULEB.encode(UInt64(terminal.count)).count + terminal.count + 1
                for child in node.children {
                    size += child.edge.count + 1 + ULEB.encode(UInt64(child.node.offset)).count
                }
                offset += size
            }
        }
        var out: [UInt8] = []
        for node in nodes {
            let terminal = terminalBytes(node.terminal)
            out += ULEB.encode(UInt64(terminal.count)) + terminal + [UInt8(node.children.count)]
            for child in node.children {
                out += child.edge + [0] + ULEB.encode(UInt64(child.node.offset))
            }
        }
        while out.count % 8 != 0 {
            out.append(0)
        }
        return out
    }

    private static func make(_ items: ArraySlice<([UInt8], Entry)>, prefix: Int) -> Node {
        let node = Node()
        var rest: [([UInt8], Entry)] = []
        for item in items {
            if item.0.count == prefix {
                node.terminal = item.1
            } else {
                rest.append(item)
            }
        }
        var order: [UInt8] = []
        var groups: [UInt8: [([UInt8], Entry)]] = [:]
        for item in rest {
            let key = item.0[prefix]
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(item)
        }
        for key in order {
            let group = groups[key]!
            var common = Array(group[0].0[prefix...])
            for item in group.dropFirst() {
                let length = zip(common, item.0[prefix...]).prefix { $0 == $1 }.count
                common = Array(common.prefix(length))
            }
            node.children.append((common, make(group[...], prefix: prefix + common.count)))
        }
        return node
    }

    private static func terminalBytes(_ entry: Entry?) -> [UInt8] {
        guard let entry else { return [] }
        var out = ULEB.encode(entry.flags)
        if entry.flags & 0x8 != 0 {
            out += ULEB.encode(entry.value)
            if let name = entry.importName, name != entry.name {
                out += Array(name.utf8)
            }
            out.append(0)
        } else if entry.flags & 0x10 != 0 {
            out += ULEB.encode(entry.value) + ULEB.encode(entry.other ?? 0)
        } else {
            out += ULEB.encode(entry.value)
            if entry.flags & 0x20 != 0 {
                out += ULEB.encode(entry.other ?? 0)
            }
        }
        return out
    }
}

// MARK: - Bytes

struct Bytes {
    private(set) var bytes: [UInt8] = []

    init(_ data: Data = Data()) {
        bytes = [UInt8](data)
    }

    var count: Int { bytes.count }

    mutating func append(_ more: [UInt8]) { bytes += more }
    mutating func zeros(_ count: Int) { bytes += [UInt8](repeating: 0, count: count) }
    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 {
            bytes.append(0)
        }
    }

    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    mutating func u32s(_ values: [UInt32]) {
        for value in values {
            u32(value)
        }
    }

    mutating func set32(_ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset ..< offset + 4, with: $0) }
    }

    mutating func set64(_ offset: Int, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset ..< offset + 8, with: $0) }
    }
}

// MARK: - arm64

enum A64 {
    static func signExtend(_ value: UInt64, _ bits: Int) -> Int64 {
        let shift = 64 - bits
        return Int64(bitPattern: value << UInt64(shift)) >> Int64(shift)
    }

    static func isADRP(_ i: UInt32) -> Bool { i & 0x9F00_0000 == 0x9000_0000 }

    static func adrpTarget(_ i: UInt32, pc: UInt64) -> UInt64 {
        let immediate = UInt64((i >> 29) & 3) | UInt64((i >> 5) & 0x7FFFF) << 2
        return UInt64(bitPattern: Int64(bitPattern: pc & ~0xFFF) &+ signExtend(immediate, 21) << 12)
    }

    static func encodeADRP(_ i: UInt32, pc: UInt64, target: UInt64) throws -> UInt32 {
        let delta = (Int64(bitPattern: target & ~0xFFF) - Int64(bitPattern: pc & ~0xFFF)) >> 12
        guard -(1 << 20) <= delta, delta < 1 << 20 else {
            throw PatcherError.invalidFormat(String(format: "ADRP at 0x%llx cannot reach 0x%llx", pc, target))
        }
        let d = UInt32(truncatingIfNeeded: delta) & ((1 << 21) - 1)
        return i & 0x9F00_001F | (d & 3) << 29 | (d >> 2) << 5
    }

    static func isAddImmediate64(_ i: UInt32) -> Bool { i & 0xFFC0_0000 == 0x9100_0000 }
    static func isLoadStoreUnsignedImmediate(_ i: UInt32) -> Bool { i & 0x3B00_0000 == 0x3900_0000 }

    static func loadStoreScale(_ i: UInt32) -> UInt64 {
        let size = i >> 30
        let vector = (i >> 26) & 1
        let opc = (i >> 22) & 3
        if vector == 1, size == 0, opc >= 2 {
            return 4
        }
        return UInt64(size)
    }

    static func isLoadX(_ i: UInt32) -> Bool { i & 0xFFC0_0000 == 0xF940_0000 }
    static func isBranch(_ i: UInt32) -> Bool { i & 0x7C00_0000 == 0x1400_0000 }

    static func branchTarget(_ i: UInt32, pc: UInt64) -> UInt64 {
        UInt64(bitPattern: Int64(bitPattern: pc) &+ signExtend(UInt64(i & 0x3FF_FFFF), 26) << 2)
    }

    static func encodeBranch(_ i: UInt32, pc: UInt64, target: UInt64) throws -> UInt32 {
        let delta = (Int64(bitPattern: target) - Int64(bitPattern: pc)) >> 2
        guard -(1 << 25) <= delta, delta < 1 << 25 else {
            throw PatcherError.invalidFormat(String(format: "branch at 0x%llx cannot reach 0x%llx", pc, target))
        }
        return i & 0xFC00_0000 | UInt32(truncatingIfNeeded: delta) & 0x3FF_FFFF
    }

    static func rd(_ i: UInt32) -> UInt32 { i & 31 }
    static func rn(_ i: UInt32) -> UInt32 { (i >> 5) & 31 }

    /// The register an instruction writes, as far as the scan needs to know.
    static func destination(_ i: UInt32) -> UInt32? {
        if i & 0x1C00_0000 == 0x1400_0000 {
            return nil
        }
        if i & 0x0A00_0000 == 0x0800_0000 {
            let masked = i & 0x3B20_0C00
            if isLoadStoreUnsignedImmediate(i) || masked == 0x3800_0000 || masked == 0x3800_0400 || masked == 0x3800_0C00 || masked == 0x3820_0800 {
                return (i >> 22) & 3 != 0 ? rd(i) : nil
            }
            if i & 0x3A00_0000 == 0x2800_0000 {
                return (i >> 22) & 1 != 0 ? rd(i) : nil
            }
            return nil
        }
        return rd(i)
    }

    static func isTerminator(_ i: UInt32) -> Bool {
        if i & 0xFC00_0000 == 0x1400_0000 { return true }
        if i & 0xFE1F_FC1F == 0xD61F_0000 || i & 0xFFFF_FC1F == 0xD65F_0000 { return true }
        if i & 0xFEFF_F800 == 0xD61F_0800 || i & 0xFFFF_FBFF == 0xD65F_0BFF { return true }
        if i & 0xFF00_0000 == 0xD700_0000, [0, 8].contains((i >> 21) & 0xF) { return true }
        return false
    }

    static func isCall(_ i: UInt32) -> Bool {
        i & 0xFC00_0000 == 0x9400_0000 || i & 0xFFFF_FC1F == 0xD63F_0000 || i & 0xFEFF_F800 == 0xD63F_0800
    }
}
