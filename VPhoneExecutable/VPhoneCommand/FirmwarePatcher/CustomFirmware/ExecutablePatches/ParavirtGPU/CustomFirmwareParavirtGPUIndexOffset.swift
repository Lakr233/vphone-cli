// CustomFirmwareParavirtGPUIndexOffset.swift — send every indexed draw with 64-bit offsets.
//
// What the driver does. `AppleParavirtGPUMetalIOGPUFamily`, the guest Metal
// driver `fw prepare` copies out of the cloudOS image, serialises each draw for
// the host's ParavirtualizedGraphics task. Every direct
// `-[PGSerializerRenderCommandEncoder drawIndexedPrimitives:…]` has two
// encodings: a compact command whose fields are 16 bits wide and a full one with
// 64-bit fields. It takes the compact one when
//
//     (indexCount | indexBufferOffset | instanceCount | baseVertex | baseInstance) >> 16 == 0
//
// and then writes `[indexBuffer parentResourceOffset] + indexBufferOffset`
// into a 16-bit field:
//
//     bl   objc_msgSend$parentResourceOffset
//     add  w8, w0, w22
//     strh w8, [x26, #0xa]                                  <- truncates
//
// `parentResourceOffset` is a buffer's offset inside the `MTLHeap` it was
// carved from, and the size test never looked at it. An index buffer 64 KiB or
// more into a heap is therefore read from `(heapOffset + indexBufferOffset) mod
// 65536`: another mesh's indices. Unity keeps mesh index buffers in heaps, so
// its games draw every such mesh with the right vertices and the wrong
// triangles — spikes, stretched faces, a full-screen quad drawn as one
// triangle. Vertex buffers are bound through 64-bit offsets and are not
// affected; neither is the indirect variant, which only has a 64-bit form.
// `Research/Guest/gpu_acceleration.md` ("Heap Index Buffers") has the
// measurements.
//
// The patch. The branch that picks the compact command becomes an
// unconditional `b` to the full command, in each of the three methods (the
// `baseVertex:baseInstance:` one has two such branches, one per host feature
// path). The full commands are the ones the driver already sends whenever a
// value does not fit in 16 bits, so the host accepts them; the cost is 12 to 28
// bytes more per indexed draw in the command stream.
//
// Finding the sites. Each compact command is set up as
//
//     cbz/cbnz <reg>, <full>   ; mov w2, #<size> ; mov w3, #<command> ; …
//
// and the `mov w2`/`mov w3` pair is unique in `__TEXT,__text`: it names the
// command. The word before the pair must be the selecting `cbz`/`cbnz`, and its
// target must begin with the full command's own `mov w2`/`mov w3` pair. Nothing
// is written unless every site resolves that way. A site whose word is already a
// `b` to that target is this patch's own output and is left alone, so a re-run
// writes nothing.
//
// The command numbers come from the cloudOS 26.4 (23E5207q) driver, the only
// cloudOS release that carries the `vphone600ap` identity a guest boots from
// (`Documents/en/firmware/compatibility.md`). A driver laid out differently fails to
// resolve and is refused unchanged.

import Foundation
import VPhonePatchKit

public enum CustomFirmwareParavirtGPUIndexOffset {
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    /// One compact-command selection: the command it avoids and the one it
    /// takes instead. Sizes are the bytes `getCommandBytes:forCommand:` reserves.
    public struct Site: Sendable, Equatable {
        public let method: String
        public let compactSize: UInt32
        public let compactCommand: UInt32
        public let fullSize: UInt32
        public let fullCommand: UInt32
    }

    public static let sites: [Site] = [
        Site(method: "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:",
             compactSize: 0x0C, compactCommand: 0x07, fullSize: 0x18, fullCommand: 0x06),
        Site(method: "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:",
             compactSize: 0x10, compactCommand: 0x09, fullSize: 0x20, fullCommand: 0x08),
        Site(method: "drawIndexedPrimitives:…:instanceCount:baseVertex:baseInstance: (correct base vertex)",
             compactSize: 0x14, compactCommand: 0x1D, fullSize: 0x30, fullCommand: 0x1C),
        Site(method: "drawIndexedPrimitives:…:instanceCount:baseVertex:baseInstance:",
             compactSize: 0x14, compactCommand: 0x0B, fullSize: 0x30, fullCommand: 0x0A),
    ]

    public enum SiteState: Sendable, Equatable {
        case patched
        case alreadyPatched
    }

    public struct ResolvedSite: Sendable, Equatable {
        public let site: Site
        /// File offset of the selecting branch.
        public let fileOffset: Int
        /// File offset of the full command's setup, the branch target.
        public let targetFileOffset: Int
        public let state: SiteState
    }

    public struct Report: Sendable, Equatable {
        public let sites: [ResolvedSite]
        public var sitesWritten: Int {
            sites.count(where: { $0.state == .patched })
        }
    }

    /// Patch the driver binary at `url` in place. The file is rewritten only
    /// when a site changes.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(&data, log: log)
        if report.sitesWritten > 0 {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form. `data` is left untouched unless every site resolves.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }
        let resolved = try resolve(in: data)
        for item in resolved {
            switch item.state {
            case .patched:
                guard let branch = ARM64Encoder.encodeB(from: item.fileOffset, to: item.targetFileOffset) else {
                    throw PatcherError.patchVerificationFailed(
                        "\(item.site.method) — cannot encode b from 0x\(hex(item.fileOffset)) to 0x\(hex(item.targetFileOffset))",
                    )
                }
                data.replaceSubrange(item.fileOffset ..< item.fileOffset + 4, with: branch)
                log?("  [+] 0x\(hex(item.fileOffset)): \(item.site.method) — compact command 0x\(hex(item.site.compactCommand)) -> b to full command 0x\(hex(item.site.fullCommand))")
            case .alreadyPatched:
                log?("  [·] 0x\(hex(item.fileOffset)): \(item.site.method) — already sends the full command")
            }
        }
        return Report(sites: resolved)
    }

    /// Resolve every site, or throw without having changed anything.
    public static func resolve(in data: Data) throws -> [ResolvedSite] {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("not a 64-bit Mach-O with a __TEXT,__text section")
        }
        let start = Int(text.fileOffset)
        let end = start + Int(text.size)
        guard start >= 0, end <= data.count, start < end else {
            throw PatcherError.invalidFormat("__TEXT,__text lies outside the file")
        }
        return try sites.map { try resolve($0, in: data, text: start ..< end) }
    }

    static func resolve(_ site: Site, in data: Data, text: Range<Int>) throws -> ResolvedSite {
        let setups = offsets(of: setup(size: site.compactSize, command: site.compactCommand), in: data, range: text)
        guard setups.count == 1, let setupOffset = setups.first else {
            throw PatcherError.patchSiteNotFound(
                "\(site.method) — expected one compact command 0x\(hex(site.compactCommand)) setup in __text, found \(setups.count); this is not the cloudOS 26.4 (23E5207q) driver",
            )
        }
        let branchOffset = setupOffset - 4
        guard branchOffset >= text.lowerBound else {
            throw PatcherError.patchSiteNotFound("\(site.method) — compact command setup starts __text")
        }
        let word = data.loadLE(UInt32.self, at: branchOffset)
        let state: SiteState
        let displacement: Int
        if let compareBranch = compareBranchDisplacement(word) {
            state = .patched
            displacement = compareBranch
        } else if let branch = branchDisplacement(word) {
            state = .alreadyPatched
            displacement = branch
        } else {
            throw PatcherError.patchSiteNotFound(
                "\(site.method) — 0x\(hex(branchOffset)) holds 0x\(hex(word)), not the cbz/cbnz that picks the compact command",
            )
        }
        let target = branchOffset + displacement
        let full = setup(size: site.fullSize, command: site.fullCommand)
        guard text.contains(target), target + full.count <= text.upperBound,
              data[target ..< target + full.count] == full
        else {
            throw PatcherError.patchVerificationFailed(
                "\(site.method) — the branch at 0x\(hex(branchOffset)) does not lead to the full command 0x\(hex(site.fullCommand))",
            )
        }
        return ResolvedSite(site: site, fileOffset: branchOffset, targetFileOffset: target, state: state)
    }

    // MARK: - Encoding

    /// `mov w2, #size ; mov w3, #command` — the arguments of
    /// `getCommandBytes:forCommand:`.
    static func setup(size: UInt32, command: UInt32) -> Data {
        movz(register: 2, immediate: size) + movz(register: 3, immediate: command)
    }

    static func movz(register: UInt32, immediate: UInt32) -> Data {
        ARM64.encodeU32(0x5280_0000 | (immediate & 0xFFFF) << 5 | register)
    }

    /// The byte displacement of a `cbz`/`cbnz` (32- or 64-bit), or nil.
    static func compareBranchDisplacement(_ word: UInt32) -> Int? {
        guard word & 0x7E00_0000 == 0x3400_0000 else { return nil }
        let imm19 = Int32(bitPattern: (word >> 5 & 0x7FFFF) << 13) >> 13
        return Int(imm19) * 4
    }

    /// The byte displacement of an unconditional `b`, or nil.
    static func branchDisplacement(_ word: UInt32) -> Int? {
        guard word & 0xFC00_0000 == 0x1400_0000 else { return nil }
        let imm26 = Int32(bitPattern: (word & 0x03FF_FFFF) << 6) >> 6
        return Int(imm26) * 4
    }

    /// Every 4-byte-aligned offset in `range` where `needle` starts.
    static func offsets(of needle: Data, in data: Data, range: Range<Int>) -> [Int] {
        var hits: [Int] = []
        var offset = range.lowerBound
        while offset + needle.count <= range.upperBound {
            if data[offset ..< offset + needle.count] == needle {
                hits.append(offset)
            }
            offset += 4
        }
        return hits
    }

    static func hex(_ value: some BinaryInteger) -> String {
        String(value, radix: 16)
    }
}
