// DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher.swift — Keep the render
// server's framebuffer in the panel's native orientation.
//
// Why
// ---
// `CA::OGL::MetalContext::get_surface` has two ways to present a rotated
// interface. A device with framebuffer compression always renders into a
// panel-native framebuffer and rotates the content itself. Without compression
// it can instead create the framebuffer texture rotated
// (`-[MTLTextureDescriptor setRotation:3]`) whenever the display orientation is
// landscape. Real iPads report compression and never take the second path; the
// paravirtual GPU does not, so an iPad guest in landscape scans out of a
// rotated texture.
//
// On the paravirtual GPU that rotated texture drops CAShapeLayer path coverage
// from every layer that is not itself rotated with the interface. The guest's
// own snapshot is correct; only the scanout loses it. The visible casualty is
// the iPad mouse pointer: pointeruid draws its arrow as a backdrop masked by a
// shape layer in a portrait-fixed window, so in landscape the host shows no
// pointer at all.
//
// What is rewritten
// -----------------
// After `bl _CADeviceUseFramebufferCompression` and the display check, the
// function reads the WindowServer surface flags and branches to the rotated
// path:
//
//     ldrb  wN, [xS, #flags]
//     tbnz  wN, #2, rotated          ; rotated: ldrh w, [x0, #orientation]
//                                   ;          and  w, w, #0xfd ; cmp w, #1
//
// The `tbnz` becomes a `nop`, so the fall-through takes the compression path
// (rotation 0). A surface that was already rotated is finalized and recreated
// by that path on its next frame. The display orientation itself is left
// alone: backboardd's hit testing still reads it.
//
// Discovery is anchored on names (`get_surface` is a local symbol, the
// compression query an export) and on decoded operands: the branch must follow
// the compression call within the function, and its target must test the
// display orientation for landscape. Exactly one site may match.

import Foundation
import VPhonePatchKit

public enum DyldSharedCacheQuartzCoreUnrotatedFramebufferPatcher {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Site: Sendable, Equatable {
        public let address: UInt64
        public let before: Data
        public let replacement: Data
        public let alreadyPatched: Bool
    }

    static let imagePath = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"
    static let getSurfaceSymbol = "__ZN2CA3OGL12MetalContext11get_surfaceEPNS_12WindowServer7SurfaceEb"
    static let compressionSymbol = "_CADeviceUseFramebufferCompression"

    /// How far after the compression call the surface-flag branch may sit.
    static let searchWindow = 24
    /// Upper bound on the function body read when the next symbol is far away.
    static let maximumFunctionBytes = 0x2000

    // MARK: - Entry points

    public static func discover(in chunks: DyldSharedCacheChunkSet) throws -> Site {
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        try resolver.requireLocalSymbols()
        let symbols = try resolver.symbols(inImage: imagePath)
        guard let function = symbols[getSurfaceSymbol]?.address else {
            throw Failure(description: "QuartzCore has no \(getSurfaceSymbol)")
        }
        guard let compression = symbols[compressionSymbol]?.address else {
            throw Failure(description: "QuartzCore has no \(compressionSymbol)")
        }
        let next = symbols.values.map(\.address).filter { $0 > function }.min()
        let length = Int(min(next.map { $0 - function } ?? UInt64(maximumFunctionBytes),
                             UInt64(maximumFunctionBytes)))
        guard length >= 64, length % 4 == 0 else {
            throw Failure(description: "get_surface body has an unexpected length \(length)")
        }
        let code = ARM64Disassembler().disassemble(
            try chunks.readAtVMA(function, length: length), at: function,
        )
        return try uniqueSite(findSites(in: code, compression: compression))
    }

    public static func patch(in chunks: DyldSharedCacheChunkSet, dryRun: Bool = false) throws -> Site {
        let site = try discover(in: chunks)
        guard !dryRun else { return site }
        let span = DyldSharedCacheWriteSpan(vma: site.address, length: 4)
        let preview = try DyldSharedCacheCodeSignature.reattest(
            in: chunks, modifiedSpans: [span], dryRun: true, log: nil,
        )
        guard preview.isFullyAttested, preview.pagesAttested == 1 else {
            throw Failure(description: "cannot attest the QuartzCore get_surface page")
        }
        if !site.alreadyPatched { try chunks.write(at: site.address, site.replacement) }
        let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: [span])
        guard result.isFullyAttested, result.pagesAttested == 1,
              try chunks.readAtVMA(site.address, length: 4) == site.replacement
        else { throw Failure(description: "QuartzCore get_surface page verification failed") }
        return site
    }

    static func uniqueSite(_ sites: [Site]) throws -> Site {
        guard sites.count == 1, let site = sites.first else {
            throw Failure(description: "QuartzCore rotated-framebuffer gate missing or ambiguous (\(sites.count) matches)")
        }
        return site
    }

    // MARK: - Matching

    /// Every `ldrb wN, [xS, #imm]; tbnz wN, #2, rotated` within `searchWindow`
    /// instructions after a direct call to the compression query, where
    /// `rotated` tests the display orientation for landscape. A `nop` in the
    /// branch slot is the patched form; it is admitted only when the function
    /// still contains the orientation test and nothing branches to it.
    static func findSites(in code: [ARM64Instruction], compression: UInt64) -> [Site] {
        let byAddress = Dictionary(code.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let orientationTests = code.indices.filter { isOrientationTest(code, at: $0) }.map { code[$0].address }
        let branchTargets = Set(code.compactMap { branchTarget($0) })

        var sites: [Site] = []
        for (index, call) in code.enumerated() where call.mnemonic == "bl" {
            guard immediate(call, 0) == compression else { continue }
            let window = code[(index + 1) ..< min(code.count, index + 1 + searchWindow)]
                .prefix { !$0.isReturn }
            for load in window where isFlagByteLoad(load) {
                guard !sites.contains(where: { $0.address == load.address + 4 }) else { continue }
                guard let gate = byAddress[load.address + 4], let flag = register(load, 0) else { continue }
                if gate.mnemonic == "tbnz" {
                    guard register(gate, 0) == flag, immediate(gate, 1) == 2,
                          let target = immediate(gate, 2), orientationTests.contains(target)
                    else { continue }
                    sites.append(Site(address: gate.address, before: Data(gate.bytes),
                                      replacement: ARM64.nop, alreadyPatched: false))
                } else if gate.mnemonic == "nop" {
                    guard orientationTests.count == 1, let test = orientationTests.first,
                          !branchTargets.contains(test)
                    else { continue }
                    sites.append(Site(address: gate.address, before: Data(gate.bytes),
                                      replacement: ARM64.nop, alreadyPatched: true))
                }
            }
        }
        return sites
    }

    /// `ldrb wN, [xS, #imm]` with a plain positive displacement.
    static func isFlagByteLoad(_ instruction: ARM64Instruction) -> Bool {
        guard instruction.mnemonic == "ldrb", let operands = instruction.detail?.operands,
              operands.count == 2, operands[0].type == .register,
              operands[1].type == .memory, operands[1].mem.index == .invalid,
              operands[1].mem.disp > 0
        else { return false }
        return true
    }

    /// `ldrh wA, [x0, #imm]; mov wB, #0xfd; and wA, wA, wB; cmp wA, #1` — the
    /// display orientation folded to landscape (1 or 3).
    static func isOrientationTest(_ code: [ARM64Instruction], at index: Int) -> Bool {
        guard index + 3 < code.count else { return false }
        let (load, mask, and, compare) = (code[index], code[index + 1], code[index + 2], code[index + 3])
        guard load.mnemonic == "ldrh", let value = register(load, 0),
              let memory = load.detail?.operands.first(where: { $0.type == .memory })?.mem,
              memory.base == .x(0), memory.index == .invalid, memory.disp > 0,
              mask.mnemonic == "mov", let maskRegister = register(mask, 0), immediate(mask, 1) == 0xFD,
              and.mnemonic == "and", register(and, 0) == value, register(and, 1) == value,
              register(and, 2) == maskRegister,
              compare.mnemonic == "cmp", register(compare, 0) == value, immediate(compare, 1) == 1
        else { return false }
        return true
    }

    // MARK: - Typed operand access

    static func register(_ instruction: ARM64Instruction, _ index: Int) -> ARM64Register? {
        guard let operands = instruction.detail?.operands, operands.indices.contains(index),
              operands[index].type == .register
        else { return nil }
        return operands[index].reg
    }

    static func immediate(_ instruction: ARM64Instruction, _ index: Int) -> UInt64? {
        guard let operands = instruction.detail?.operands, operands.indices.contains(index),
              operands[index].type == .immediate, operands[index].imm >= 0
        else { return nil }
        return UInt64(operands[index].imm)
    }

    /// The immediate target of a direct conditional or unconditional branch.
    static func branchTarget(_ instruction: ARM64Instruction) -> UInt64? {
        switch instruction.mnemonic {
        case "b", "cbz", "cbnz", "tbz", "tbnz":
            instruction.detail?.operands.last(where: { $0.type == .immediate })
                .flatMap { $0.imm > 0 ? UInt64($0.imm) : nil }
        default:
            instruction.mnemonic.hasPrefix("b.")
                ? instruction.detail?.operands.last(where: { $0.type == .immediate })
                .flatMap { $0.imm > 0 ? UInt64($0.imm) : nil }
                : nil
        }
    }
}
