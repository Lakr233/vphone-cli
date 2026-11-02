import Foundation
import MachO
import VPhonePatchKit

/// Describes one private COW stub detour; the on-disk cache is not modified.
/// The native bridge translates IOSurfaceRoot's widened 26.1 replies to 20G81.
public enum DyldSharedCacheIOS16SurfaceAdapter {
    public static let image = "/System/Library/Frameworks/IOSurface.framework/IOSurface"

    public static func metadata(directory: URL) throws -> Data {
        try prepare(directory: directory, image: image, anchorName: "_IOSurfaceCreate",
                    entryName: "_IOSurfaceClientCreateChild", methodName: "_IOConnectCallMethod", surface: true)
    }

    public static func swapMetadata(directory: URL) throws -> Data {
        try prepare(directory: directory,
                    image: "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                    anchorName: "_IOMobileFramebufferSwapEnd", entryName: "_kern_SwapEnd",
                    methodName: "_IOConnectCallStructMethod", surface: false)
    }

    private static func prepare(directory: URL, image: String, anchorName: String,
                                entryName: String, methodName: String, surface: Bool) throws -> Data {
        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        let anchor = try resolver.address(of: anchorName, inImage: image)
        let create = try resolver.address(of: entryName, inImage: image)
        let method = try resolver.address(of: methodName, inImage: "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit")
        let decoder = ARM64Disassembler()
        let body = decoder.disassemble(try chunks.readAtVMA(create, length: 512), at: create)
        guard body.contains(where: {
            $0.mnemonic == "mov" && $0.detail?.operands.first?.reg.name == (surface ? "w8" : "w3") &&
            (surface ? [Int64(0xA68)] : [Int64(0x46C), Int64(0x560)]).contains($0.detail?.operands.last?.imm ?? -1)
        }) else { throw PatcherError.patchSiteNotFound("IOSurface: legacy lock-result size not found") }
        var candidates = Set<UInt64>()
        for call in body where call.mnemonic == "bl" {
            guard let operand = call.detail?.operands.first, operand.type == .immediate else { continue }
            let target = UInt64(bitPattern: operand.imm)
            let stub = decoder.disassemble(try chunks.readAtVMA(target, length: 16), at: target)
            guard stub.count == 4, stub[0].mnemonic == "adrp", stub[1].mnemonic == "add",
                  stub[2].mnemonic == "br", stub[3].mnemonic == "brk",
                  let page = stub[0].detail?.operands, page.count == 2,
                  page[0].reg.name == "x16", page[1].type == .immediate,
                  let add = stub[1].detail?.operands, add.count == 3,
                  add[0].reg.name == "x16", add[1].reg.name == "x16", add[2].type == .immediate,
                  stub[2].detail?.operands.first?.reg.name == "x16",
                  UInt64(bitPattern: page[1].imm) + UInt64(add[2].imm) == method else { continue }
            candidates.insert(target)
        }
        guard candidates.count == 1, let stub = candidates.first,
              let load = ARM64Encoder.encodeLdrXLiteral(rt: 16, from: 0, to: 8),
              let branch = ARM64Encoder.encodeBR(rn: 16)
        else { throw PatcherError.patchSiteNotFound("IOSurface: unique direct IOKit transport stub not found") }

        // Bind the metadata to the exact framework UUID, not a global cache slide.
        let header = try resolver.headerAddress(ofImage: image)
        let commands = try chunks.readAtVMA(header, length: 0x4000)
        func word(_ offset: Int) -> UInt32 { commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
        guard word(0) == MH_MAGIC_64, word(20) <= 0x4000 - 32 else {
            throw PatcherError.patchVerificationFailed("IOSurface load-command bounds")
        }
        var uuid: Data?
        var cursor = 32
        let end = cursor + Int(word(20))
        for _ in 0..<word(16) {
            guard cursor + 8 <= end else { throw PatcherError.patchVerificationFailed("IOSurface command header") }
            let size = Int(word(cursor + 4))
            guard size >= 8, cursor + size <= end else { throw PatcherError.patchVerificationFailed("IOSurface command size") }
            if word(cursor) == LC_UUID, size == 24 { uuid = commands.subdata(in: cursor + 8..<cursor + 24) }
            cursor += size
        }
        guard let uuid else { throw PatcherError.patchVerificationFailed("IOSurface UUID missing") }
        var result = Data("VPIS16\u{1}\0".utf8) // eight-byte versioned header
        var displacement = (Int64(stub) - Int64(anchor)).littleEndian
        withUnsafeBytes(of: &displacement) { result.append(contentsOf: $0) }
        result.append(try chunks.readAtVMA(stub, length: 16))
        result.append(load); result.append(branch); result.append(uuid)
        return result
    }
}
