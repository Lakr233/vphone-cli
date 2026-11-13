// SEPResearchBoardPatcher.swift — The research board's SEP firmware, as vphone600's.
//
// A cloudOS without vphone600 components restores the research board's SEP
// firmware. Its SEPD differs from vphone600's in one operation the guest
// needs: vresearch101 gives operation 0x31 a handler of its own, which replies
// with a constant, where vphone600 sends it to the handler operation 0x12 and
// several others share, which zeroes the reply. Compared on the 26.4 beta
// (23E5207q), which carries both. The patch points 0x31's switch table entry
// at 0x12's.
//
// The firmware stores each app in two parts (text, then data), located by the
// root argument object that follows the "Built by legion2P" banner: an app's
// name field sits 0x78 bytes after the offsets and sizes of its two parts
// (0x80 from cloudOS 27, whose entries gained a field before the name). The
// distance whose first part is a Mach-O is the one used.
//
// The switch table lies in `__text`. From cloudOS 26.4 on, SEPD's FIPS self
// test checks an HMAC-SHA256 of `__text` with an all-zero key, stored in
// `__TEXT,__fipspost_hmac` (both stock 26.4 SEPDs match that), so the HMAC is
// recomputed after the write. Earlier SEPDs have no such section.

import CryptoKit
import Foundation
import VPhonePatchKit

public final class SEPResearchBoardPatcher: BufferedPatcher {
    public let component = "sep"
    public let verbose: Bool
    public var gate: VPhonePatchGate = .unrestricted

    let buffer: BinaryBuffer
    var patches: [PatchRecord] = []

    /// The operation redirected, and the one whose handler it takes.
    static let redirectedOperation = 0x31
    static let sharedOperation = 0x12

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    public var patchedData: Data {
        buffer.data
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        let patchID = FirmwareResearchBoardPatchSet.sepDispatch
        let app = try Self.application(named: "SEPD", in: buffer.data)
        // Both rebased, so offsets into the app start at 0.
        var sepd = Data(buffer.data[app.part1]) + Data(buffer.data[app.part2])
        let sections = MachOParser.parseSections(from: sepd)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("SEP: SEPD has no __TEXT,__text")
        }

        let table = try Self.dispatchTable(in: sepd, text: text)
        guard table.count > Self.redirectedOperation else {
            throw PatcherError.patchSiteNotFound("SEP: SEPD dispatches \(table.count) operations, fewer than \(Self.redirectedOperation + 1)")
        }
        let site = table.offset + Self.redirectedOperation * 4
        let original = Data(sepd[site ..< site + 4])
        let replacement = Data(sepd[table.offset + Self.sharedOperation * 4 ..< table.offset + Self.sharedOperation * 4 + 4])
        // vphone600's SEPD, or one patched before.
        guard original != replacement, gateAllows(patchID) else { return [] }
        sepd.replaceSubrange(site ..< site + 4, with: replacement)

        patches.append(PatchRecord(
            patchID: patchID + ".table",
            component: component,
            fileOffset: app.imageOffset(of: site),
            virtualAddress: text.address + UInt64(site - Int(text.fileOffset)),
            originalBytes: original,
            patchedBytes: replacement,
            description: String(format: "SEPD operation 0x%x takes the handler of 0x%x, as on vphone600", Self.redirectedOperation, Self.sharedOperation),
        ))

        if let hmac = sections["__TEXT,__fipspost_hmac"] {
            guard hmac.size == 32 else {
                throw PatcherError.invalidFormat("SEP: SEPD's __fipspost_hmac is \(hmac.size) bytes, not an HMAC-SHA256")
            }
            let textBytes = sepd[Int(text.fileOffset) ..< Int(text.fileOffset) + Int(text.size)]
            let code = Data(HMAC<SHA256>.authenticationCode(for: textBytes, using: SymmetricKey(data: Data(count: 32))))
            let offset = Int(hmac.fileOffset)
            patches.append(PatchRecord(
                patchID: patchID + ".fips_hmac",
                component: component,
                fileOffset: app.imageOffset(of: offset),
                virtualAddress: hmac.address,
                originalBytes: Data(sepd[offset ..< offset + 32]),
                patchedBytes: code,
                description: "SEPD FIPS HMAC of the patched __text",
            ))
        }
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            _ = try findAll()
        }
        for record in patches {
            buffer.data.replaceSubrange(record.fileOffset ..< record.fileOffset + record.patchedBytes.count, with: record.patchedBytes)
            if verbose {
                print(String(format: "  0x%06X: %@ → %@  [%@]", record.fileOffset, record.originalBytes.hex, record.patchedBytes.hex, record.patchID))
            }
        }
        return patches.count
    }

    // MARK: - Application Layout

    struct Application {
        let part1: Range<Int>
        let part2: Range<Int>

        /// Where a byte of the app, counted from the start of part 1, lies in the
        /// firmware image.
        func imageOffset(of offset: Int) -> Int {
            offset < part1.count ? part1.lowerBound + offset : part2.lowerBound + offset - part1.count
        }
    }

    /// How far before an app's name its part offsets lie: before cloudOS 27, then from 27 on.
    static let entryDistances = [0x78, 0x80]
    static let machOMagic64: UInt32 = 0xFEED_FACF

    /// `image` is indexed from 0, as a ``BinaryBuffer``'s data is.
    static func application(named name: String, in image: Data) throws -> Application {
        guard let banner = image.range(of: Data("Built by legion2P".utf8)),
              let field = image.range(of: Data(name.utf8), in: banner.lowerBound ..< min(banner.lowerBound + 0x1000, image.endIndex))
        else {
            throw PatcherError.patchSiteNotFound("SEP: no \(name) in the root argument object")
        }
        for distance in entryDistances {
            let entry = field.lowerBound - distance
            guard entry >= 0 else { continue }
            func value(_ slot: Int) -> Int {
                Int(image.loadLE(UInt32.self, at: entry + slot * 8))
            }
            let part1 = value(0) ..< value(0) + value(1)
            let part2 = value(2) ..< value(2) + value(3)
            guard part1.count >= 4, part1.upperBound <= image.count, part2.upperBound <= image.count,
                  image.loadLE(UInt32.self, at: part1.lowerBound) == machOMagic64
            else { continue }
            return Application(part1: part1, part2: part2)
        }
        throw PatcherError.invalidFormat("SEP: \(name)'s entry has no parts starting with a Mach-O header")
    }

    // MARK: - Dispatch Table

    /// The one bounds-checked switch in `__text` that covers the redirected
    /// operation: where its table of 32-bit offsets lies in the app, and how
    /// many entries it has.
    ///
    ///     cmp   xI, #bound
    ///     csel  xI, xI, xzr, ls
    ///     adrp  xB, page ; add xB, xB, #offset    (adr xB, table ; nop before 18.5)
    ///     ldrsw xL, [xB, xI, lsl #2]
    ///     adr   xA, base
    ///     add   xT, xA, xL
    ///     br    xT
    static func dispatchTable(in app: Data, text: MachOSectionInfo) throws -> (offset: Int, count: Int) {
        let start = Int(text.fileOffset)
        let instructions = ARM64Disassembler().disassemble(Data(app[start ..< start + Int(text.size)]), at: text.address)
        var found: [(offset: Int, count: Int)] = []
        for end in instructions.indices where end >= 7 && instructions[end].mnemonic == "br" {
            let window = Array(instructions[end - 7 ... end])
            let c = window.map { $0.detail?.operands ?? [] }
            guard c[7].count == 1,
                  window[6].mnemonic == "add", c[6].count == 3, c[6][0].reg == c[7][0].reg,
                  window[5].mnemonic == "adr", c[5].count == 2, c[5][0].reg == c[6][1].reg,
                  window[4].mnemonic == "ldrsw", c[4].count == 2, c[4][0].reg == c[6][2].reg,
                  c[4][1].type == .memory, c[4][1].shift.type == .lsl, c[4][1].shift.amount == 2,
                  window[1].mnemonic == "csel", window[1].detail?.conditionCode == .ls, c[1].count == 3,
                  c[1][0].reg == c[4][1].mem.index, c[1][1].reg == c[1][0].reg, c[1][2].reg == .xzr,
                  window[0].mnemonic == "cmp", c[0].count == 2, c[0][0].reg == c[1][0].reg,
                  c[0][1].type == .immediate, c[0][1].imm >= redirectedOperation, c[0][1].imm < 0x100,
                  let table = tableAddress(window[2], window[3], base: c[4][1].mem.base)
            else { continue }
            let offset = Int(table) - Int(text.address) + start
            let count = Int(c[0][1].imm) + 1
            guard offset >= start, offset + count * 4 <= start + Int(text.size) else { continue }
            found.append((offset, count))
        }
        guard found.count == 1, let table = found.first else {
            throw PatcherError.patchSiteNotFound("SEP: \(found.count) SEPD dispatch tables cover operation 0x\(String(redirectedOperation, radix: 16)), expected one")
        }
        return table
    }

    /// The table address `first` and `second` put into `base`: `adrp` + `add`,
    /// or `adr` + `nop` where the linker relaxed the pair.
    private static func tableAddress(_ first: ARM64Instruction, _ second: ARM64Instruction, base: ARM64Register) -> UInt64? {
        let a = first.detail?.operands ?? []
        let b = second.detail?.operands ?? []
        if first.mnemonic == "adrp", a.count == 2, a[0].reg == base, a[1].type == .immediate,
           second.mnemonic == "add", b.count == 3, b[0].reg == base, b[1].reg == base,
           b[2].type == .immediate, b[2].shift.amount == 0
        {
            return UInt64(bitPattern: a[1].imm &+ b[2].imm)
        }
        if first.mnemonic == "adr", a.count == 2, a[0].reg == base, a[1].type == .immediate,
           second.mnemonic == "nop"
        {
            return UInt64(bitPattern: a[1].imm)
        }
        return nil
    }
}
