// KernelCollectionStubCalls.swift — Branch straight to a kext's imports, as Apple's iOS 26 collections do.
//
// The kmutil of macOS 27 keeps every kext's `__auth_stubs` when it links a
// collection (Apple's own iOS 27 kernelcaches keep them too), so a call to
// another image runs `BL stub` → `ADRP/ADD x17` (the `__auth_got` slot) →
// `LDR x16, [x17]` → `BRAA x16, x17`. Apple's iOS 26 collections, and the kmutil
// of macOS 26, branch to the target directly, and the kernel patches look for
// those branches (a `BL _panic` next to a panic string, a call to a known
// function). On a mix linked by macOS 27 they would miss, and the guest panics
// on the seal the CFW install breaks.
//
// `directCalls` rewrites each B/BL that lands on a stub to land on the stub's
// target, read from its `__auth_got` slot, which leaves the stubs unreferenced,
// and seals corecrypto's code again for its FIPS self test. A collection whose
// kexts call each other directly comes back unchanged.

import CryptoKit
import Foundation
import VPhonePatchKit

enum KernelCollectionStubCalls {
    struct Result {
        var payload: Data
        /// Stubs whose target was resolved.
        var stubs = 0
        /// Branches retargeted from a stub to its target.
        var branches = 0
        /// Images whose FIPS seal was computed again over their new code.
        var resealed = 0
    }

    /// corecrypto's power-on self test checks `__TEXT,__fips_hmacs` against an
    /// HMAC-SHA256, keyed with the single byte 0, of its linked `__text`; the
    /// builder writes it last. Rewriting a branch there needs a new seal, or the
    /// kernel panics with "FIPS Kernel POST Failed". The existing seal must
    /// match the code before anything changes, so a different scheme is refused
    /// rather than overwritten.
    struct FIPSSeal {
        let seal: Int
        let text: Range<Int>

        init?(image: KDKImage, in collection: KDKKernelCollection, bytes: [UInt8]) throws {
            guard let hmacs = image.sections.first(where: { $0.segmentName == "__TEXT" && $0.name == "__fips_hmacs" }) else { return nil }
            guard let text = image.sections.first(where: { $0.segmentName == "__TEXT" && $0.name == "__text" })
                ?? image.sections.first(where: { $0.segmentName == "__TEXT_EXEC" && $0.name == "__text" }),
                hmacs.size >= 32
            else {
                throw PatcherError.invalidFormat("\(image.identifier) has __fips_hmacs but no __text to seal")
            }
            seal = try Int(collection.offset(of: hmacs.address))
            let start = try Int(collection.offset(of: text.address))
            self.text = start ..< start + Int(text.size)
            try collection.bytes.check(seal, 32)
            try collection.bytes.check(start, Int(text.size))
            guard Array(bytes[seal ..< seal + 32]) == Self.hmac(bytes[self.text]) else {
                throw PatcherError.invalidFormat("\(image.identifier)'s FIPS seal is not HMAC-SHA256 of its __text; its calls through stubs cannot be rewritten")
            }
        }

        func reseal(_ bytes: inout [UInt8]) {
            bytes.replaceSubrange(seal ..< seal + 32, with: Self.hmac(bytes[text]))
        }

        static func hmac(_ code: ArraySlice<UInt8>) -> [UInt8] {
            Array(HMAC<SHA256>.authenticationCode(for: code, using: SymmetricKey(data: [UInt8(0)])))
        }
    }

    static let stubSize: UInt64 = 16
    /// DYLD_CHAINED_PTR_64_KERNEL_CACHE.
    static let kernelCachePointerFormat: UInt16 = 8

    static func directCalls(in payload: Data) throws -> Result {
        let collection = try KDKKernelCollection(payload)
        var result = Result(payload: payload)
        let images = try collection.entries.map { try collection.image($0.identifier) }
        let stubSections = images.flatMap { image in
            image.sections.filter { $0.segmentName == "__TEXT_EXEC" && $0.name == "__auth_stubs" && $0.size > 0 }
        }
        guard !stubSections.isEmpty else { return result }
        try checkPointerFormat(collection)

        var targets: [UInt64: UInt64] = [:]
        for section in stubSections {
            guard section.size % stubSize == 0 else {
                throw PatcherError.invalidFormat("__auth_stubs at 0x\(String(section.address, radix: 16)) is not a whole number of stubs")
            }
            var stub = section.address
            while stub < section.address + section.size {
                targets[stub] = try target(ofStub: stub, in: collection)
                stub += stubSize
            }
        }
        result.stubs = targets.count

        var bytes = [UInt8](payload)
        for image in images {
            let seal = try FIPSSeal(image: image, in: collection, bytes: bytes)
            let before = result.branches
            for section in image.sections where isCode(section) {
                let start = try Int(collection.offset(of: section.address))
                try collection.bytes.check(start, Int(section.size))
                var pc = section.address
                while pc + 4 <= section.address + section.size {
                    let offset = start + Int(pc - section.address)
                    let word = bytes.le(UInt32.self, offset)
                    if ARM64Inst.isBorBL(word),
                       let stub = KDKInstruction.branch(word, pc),
                       let target = targets[stub]
                    {
                        let from = Int(bitPattern: UInt(pc)), to = Int(bitPattern: UInt(target))
                        let encoded = ARM64Inst.isBL(word) ? ARM64Encoder.encodeBL(from: from, to: to) : ARM64Encoder.encodeB(from: from, to: to)
                        guard let encoded else {
                            throw PatcherError.invalidFormat("the call at 0x\(String(pc, radix: 16)) cannot reach 0x\(String(target, radix: 16)) directly")
                        }
                        bytes.replaceSubrange(offset ..< offset + 4, with: encoded)
                        result.branches += 1
                    }
                    pc += 4
                }
            }
            if result.branches > before, let seal {
                seal.reseal(&bytes)
                result.resealed += 1
            }
        }
        result.payload = Data(bytes)
        return result
    }

    /// Instructions other than the stubs: regular sections marked as code.
    static func isCode(_ section: KDKMachO.Section) -> Bool {
        let pureInstructions: UInt32 = 0x8000_0000
        return section.size > 0 && section.type == 0 && section.flags & pureInstructions != 0
    }

    /// The function an auth stub branches to: `ADRP x17, slot@PAGE`,
    /// `ADD x17, x17, slot@PAGEOFF`, `LDR x16, [x17]`, `BRAA x16, x17`, with
    /// `slot` an `__auth_got` pointer into this collection.
    static func target(ofStub stub: UInt64, in collection: KDKKernelCollection) throws -> UInt64 {
        let offset = try Int(collection.offset(of: stub))
        let words = try (0 ..< 4).map { try collection.bytes.u32(offset + $0 * 4) }
        let x16: UInt32 = 16, x17: UInt32 = 17
        guard ARM64Inst.isADRP(words[0]), ARM64Inst.rd(words[0]) == x17,
              words[1] & 0xFFC0_0000 == 0x9100_0000, ARM64Inst.rd(words[1]) == x17, ARM64Inst.rn(words[1]) == x17,
              ARM64Inst.isLDRImm64(words[2]), ARM64Inst.rd(words[2]) == x16, ARM64Inst.rn(words[2]) == x17,
              ARM64Inst.addSubImm12(words[2]) == 0,
              let braa = ARM64Encoder.encodeBRAA(rn: x16, rm: x17), words[3] == braa.loadLE(UInt32.self, at: 0)
        else {
            throw PatcherError.invalidFormat("the auth stub at 0x\(String(stub, radix: 16)) is not ADRP/ADD x17, LDR x16, BRAA")
        }
        let slot = KDKInstruction.adrp(words[0], stub) + UInt64(ARM64Inst.addSubImm12(words[1]))
        let raw = try collection.bytes.u64(Int(collection.offset(of: slot)))
        // target:30 cacheLevel:2 diversity:16 addrDiv:1 key:2 next:12 isAuth:1
        guard (raw >> 30) & 3 == 0 else {
            throw PatcherError.invalidFormat("the auth stub at 0x\(String(stub, radix: 16)) imports from another collection")
        }
        let target = collection.baseAddress + (raw & 0x3FFF_FFFF)
        // iOS 27 kexts also import the kernel's `__bootcode` (strcmp), in __TEXT_BOOT_EXEC.
        guard collection.segments.contains(where: { ["__TEXT_EXEC", "__TEXT_BOOT_EXEC"].contains($0.name) && $0.contains(target) }) else {
            throw PatcherError.invalidFormat("the auth stub at 0x\(String(stub, radix: 16)) points outside the collection's code (0x\(String(target, radix: 16)))")
        }
        return target
    }

    /// Every chain start of the collection is DYLD_CHAINED_PTR_64_KERNEL_CACHE,
    /// the only format `target(ofStub:)` decodes.
    static func checkPointerFormat(_ collection: KDKKernelCollection) throws {
        guard let load = collection.commands.first(where: { $0.command == KDKMachO.lcDyldChainedFixups }) else {
            throw PatcherError.invalidFormat("the linked collection has auth stubs but no chained fixups")
        }
        let base = Int(load.bytes.le(UInt32.self, 8))
        let startsInImage = try base + Int(collection.bytes.u32(base + 4))
        let segments = try Int(collection.bytes.u32(startsInImage))
        for index in 0 ..< segments {
            let relative = try Int(collection.bytes.u32(startsInImage + 4 + index * 4))
            guard relative != 0 else { continue }
            let format = try collection.bytes.u16(startsInImage + relative + 6)
            guard format == kernelCachePointerFormat else {
                throw PatcherError.invalidFormat("the linked collection uses chained pointer format \(format), not the kernel cache's")
            }
        }
    }
}
