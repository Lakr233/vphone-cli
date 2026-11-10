import CryptoKit
import Darwin
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
import VPhoneSign

@Suite("TXM missing profile compatibility")
struct TXMMissingProfileTests {
    static var signedApp: String? { ProcessInfo.processInfo.environment["VPHONE_PROFILE_APP"] }

    struct Image: Sendable {
        let version: String, hash: String
        let category: Int, validator: Int, check: Int, finalizer: Int, getter: Int
        var path: String? {
            let suffix = version == "26.4" ? "" : "_" + version.replacingOccurrences(of: ".", with: "_")
            return ProcessInfo.processInfo.environment["VPHONE_REMAP_TXM" + suffix]
        }
        var error: Int { check + 0x84 }
    }

    static let images: [Image] = [
        .init(version: "26.1", hash: "ec68dc5a1ec77d8399365f7164e0384539c75e06ed9555f793ce5ff34a9c1db6",
              category: 0xa1, validator: 0x2e124, check: 0x30cc4, finalizer: 0x319e0, getter: 0x31cb8),
        .init(version: "26.2", hash: "17e401fd6c1b07f026acc43509eabfc87c96d3673b86165d1d3af53dc5026b6d",
              category: 0xa1, validator: 0x2e144, check: 0x30ce4, finalizer: 0x31a00, getter: 0x31cd8),
        .init(version: "26.3", hash: "62f40b9cd32a2a035899a925d51f2573bb603db216fc5405a3d9ad48b180a1d2",
              category: 0xa1, validator: 0x2e144, check: 0x30ce4, finalizer: 0x31a00, getter: 0x31cd8),
        .init(version: "26.4", hash: "819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1",
              category: 0x101, validator: 0x2e7b0, check: 0x31348, finalizer: 0x32088, getter: 0x32360),
    ]
    static var availableImages: [Image] { images.filter { $0.path != nil } }

    // Original profile validator and finalizer from TXM 187.100.3, SHA-256
    // 819861b6...929ebfbc1. Relative positions preserve the finalizer's BL.
    // Relocated fragments test discovery only; native execution uses a hashed
    // complete image. No private App/profile/certificate fixture is checked in.
    static let fragments: [(Int, String)] = [
        (0, """
        7f2303d5ffc300d1f44f01a9fd7b02a9fd830091ff0700f9088440f9480300b4
        f30300aa001840f9611e40f9e22300917ffaff97748640f9e00313aa45feff97
        e10300aae00314aa81f3ff971f1c1872e1010054608640f9e10740f9b8f3ff97
        1f1c187241010054610a51a9608640f9e9f3ff971f1c1872c81480520001801a
        03000014c05482522000a072fd7b42a9f44f41a9ffc30091ff0f5fd6
        """),
        (0xd40, """
        7f2303d5f44fbea9fd7b01a9fd43009114044439f4000034f30300aa08084439
        e8000034608086524000a0724e00001460a080522000a0724b000014600240f9
        e10314aad5feff971f1c1872c1080054600240f9e10314aab6feff971f1c1872
        21080054e00313aae10314aa7efeff971f1c187281070054e00313aae10314aa
        47feff971f1c1872e1060054e00313aae10314aa19feff971f1c187241060054
        e00313aaedfdff971f1c1872c1050054e00313aacafdff971f1c187241050054
        e00313aaa1fdff971f1c1872c1040054602080528000a0729f0e00714c010054
        9f060071800200549f0a0071a00200549f0e007181030054e00313aa98fcff97
        15000014881a00511f150071a2000054e00313aae10314aa4cfdff970e000014
        9f120071400100549f160071800100540d000014e00313aa22fdff9706000014
        e00313aac6fcff9703000014e00313aa5cfcff971f1c187261000054740a0439
        60008052fd7b41a9f44fc2a8ff0f5fd6
        """),
    ]

    // Original 26.1 (23B85) functions, relative to 0x30cc4. The 26.2/26.3
    // functions are byte-identical at +0x20 in their separately hashed images.
    static let cloudOS26_1Fragments: [(Int, String)] = [
        (0, """
        7f2303d5ffc300d1f44f01a9fd7b02a9fd830091ff0700f9085440f9480300b4
        f30300aa001840f9611e40f9e223009181faff97745640f9e00313aa40feff97
        e10300aae00314aa79f3ff971f1c1872e1010054605640f9e10740f9b1f3ff97
        1f1c18724101005460864aa9625e40f9e3f3ff971f1c1872c81480520001801a
        03000014c05482522000a072fd7b42a9f44f41a9ffc30091ff0f5fd6
        """),
        (0xd1c, """
        7f2303d5f44fbea9fd7b01a9fd43009114844239f4000034f30300aa08884239
        e8000034608086524000a0724e00001460a080522000a0724b000014600240f9
        e10314aadcfeff971f1c1872c1080054600240f9e10314aabdfeff971f1c1872
        21080054e00313aae10314aa85feff971f1c187281070054e00313aae10314aa
        4efeff971f1c1872e1060054e00313aae10314aa20feff971f1c187241060054
        e00313aaf4fdff971f1c1872c1050054e00313aad1fdff971f1c187241050054
        e00313aaa8fdff971f1c1872c1040054602080528000a0729f0e00714c010054
        9f060071800200549f0a0071a00200549f0e007181030054e00313aaa1fcff97
        15000014881a00511f150071a2000054e00313aae10314aa55fdff970e000014
        9f120071400100549f160071800100540d000014e00313aa2bfdff9706000014
        e00313aacffcff9703000014e00313aa65fcff971f1c187261000054748a0239
        60008052fd7b41a9f44fc2a8ff0f5fd6
        """),
    ]

    private func fixture(starts: [Int] = [0x400], legacy: Bool = false) throws -> Data {
        var image = Data(repeating: 0, count: (starts.max() ?? 0x400) + 0x1000)
        func u32(_ offset: Int, _ value: UInt32) {
            image.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value))
        }
        func u64(_ offset: Int, _ value: UInt64) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { image.replaceSubrange(offset ..< offset + 8, with: $0) }
        }
        u32(0, 0xfeedfacf)
        u32(4, 0x0100000c)
        u32(8, 2)
        u32(12, 2)
        u32(16, 1)
        u32(20, 72)
        u32(32, 0x19)
        u32(36, 72)
        image.replaceSubrange(40 ..< 51, with: Data("__TEXT_EXEC\0".utf8))
        u64(56, 0x400)
        u64(64, UInt64(image.count - 0x400))
        u64(72, 0x400)
        u64(80, UInt64(image.count - 0x400))
        u32(88, 5)
        u32(92, 5)
        for start in starts {
            for (offset, string) in legacy ? Self.cloudOS26_1Fragments : Self.fragments {
                let hex = string.filter { !$0.isWhitespace }
                var bytes = Data()
                var cursor = hex.startIndex
                while cursor < hex.endIndex {
                    let end = hex.index(cursor, offsetBy: 2)
                    bytes.append(try #require(UInt8(hex[cursor ..< end], radix: 16)))
                    cursor = end
                }
                image.replaceSubrange(start + offset ..< start + offset + bytes.count, with: bytes)
            }
        }
        return image
    }

    private func locate(in image: Data, category: Int = 0x101) throws -> (site: Int, bytes: Data) {
        let patcher = TXMDevPatcher(data: image, verbose: false)
        let disasm = ARM64Disassembler()
        let code = MachOParser.parseSegments(from: image)
            .filter { $0.name == "__TEXT_EXEC" }
            .flatMap { disasm.disassemble(in: image, at: Int($0.fileOffset), count: Int($0.fileSize / 4)) }
        return try patcher.remapMissingProfileCompatibility(code, categoryOffset: Int64(category))
    }

    @Test(arguments: [0x400, 0x8400], [false, true])
    func locatesOnlyTheNullProfileExitAfterRelocation(start: Int, legacy: Bool) throws {
        let original = try fixture(starts: [start], legacy: legacy)
        let site = try locate(in: original, category: legacy ? 0xa1 : 0x101)
        #expect(site.site == start + 0x84)
        let expected = try #require(ARM64Encoder.encodeMovzW(rd: 0, imm16: 0xa6)) + ARM64.nop
        #expect(site.bytes == expected)
        // The profile validator must agree with the classifier's recovered ABI.
        #expect(throws: PatcherError.self) { try locate(in: original, category: legacy ? 0x101 : 0xa1) }
    }

    @Test
    func missingAmbiguousOrChangedControlFlowEmitsNothing() throws {
        let original = try fixture()
        let mutations: [(Int, Data)] = [
            (0x418, try #require(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 0, offset: 0x110))),
            (0x41c, try #require(ARM64Encoder.encodeCompareBranch(nonzero: false, register: 8, from: 0x41c, to: 0x488, width64: true))),
            (0x488, try #require(ARM64Encoder.encodeMovkW(rd: 0, imm16: 1, shift: 0))),
            (0x47c, ARM64.nop), // native non-null success selection
            (0x500, try #require(ARM64Encoder.encodeB(from: 0x500, to: 0x484))), // an additional error predecessor
            (0x500, try #require(ARM64Encoder.encodeB(from: 0x500, to: 0x400))), // an additional tail caller
            (0x400 + 0xd40 + 0x120, try #require(ARM64Encoder.encodeCmpWImmediate(rn: 20, imm12: 5))),
            (0x400 + 0xd40 + 0x150, ARM64.nop), // finalizer call
            (0x400 + 0xd40 + 0x15c, try #require(ARM64Encoder.encodeStrBUnsignedOffset(rt: 20, rn: 19, offset: 0x101))),
        ]
        var inputs = [Data(), try fixture(starts: [0x400, 0x4400])]
        for (offset, bytes) in mutations {
            var changed = original
            changed.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
            inputs.append(changed)
        }
        for input in inputs {
            #expect(throws: PatcherError.self) { try locate(in: input) }
        }
    }

    private func fullImagePair(_ image: Image) throws -> (Data, Data) {
        let original = try Data(contentsOf: URL(fileURLWithPath: #require(image.path)))
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        try #require(digest == image.hash)
        let site = try locate(in: original, category: image.category)
        var patched = original
        patched.replaceSubrange(site.site ..< site.site + site.bytes.count, with: site.bytes)
        var expected = original
        expected.replaceSubrange(image.error ..< image.error + 8, with:
            try #require(ARM64Encoder.encodeMovzW(rd: 0, imm16: 0xa6)) + ARM64.nop)
        try #require(patched == expected) // hash + only reviewed bytes before native execution
        return (original, patched)
    }

    @Test(.enabled(if: !availableImages.isEmpty), arguments: availableImages)
    func suppliedImageRejectsPartialPlansAndRetainsPresentProfileChecks(image: Image) throws {
        let (original, patched) = try fullImagePair(image)
        var malformed = original
        malformed.replaceSubrange(image.error ..< image.error + 4, with: ARM64.nop)
        let incomplete = TXMDevPatcher(data: malformed, verbose: false)
        #expect(throws: PatcherError.self) { try incomplete.patchExecutableRemap() }
        #expect(incomplete.patches.isEmpty)
        #expect(throws: PatcherError.self) { try incomplete.findAll() }
        #expect(incomplete.patches.isEmpty)
        #expect(throws: PatcherError.self) { try incomplete.apply() }
        #expect(incomplete.patches.isEmpty)
        #expect(incomplete.patchedData == malformed)

        #if arch(arm64)
            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("VPhoneSignTestFixtures/Executables/hello-arm64")
            let signed = try VPhoneSigner.sign(Data(contentsOf: fixtureURL), options: .init(identifier: "profile-gate", style: .ldid))
            let blob = try superBlob(signed)
            // A CMS-less ldid CodeDirectory hits the earlier A1 hash-flags
            // rejection in pristine TXM. The isolated A6 patch must preserve
            // that result; the combined-plan test exercises ldid admission
            // with the existing hash-flags bypass enabled as well.
            try executeProfileValidation(image: original, layout: image, blob: blob, allowsMissing: false, earlierError: 0x130a1)
            try executeProfileValidation(image: patched, layout: image, blob: blob, allowsMissing: true, earlierError: 0x130a1)
        #endif
    }

    @Test(.enabled(if: !availableImages.isEmpty && signedApp != nil), arguments: availableImages)
    func suppliedCMSSignaturePassesTheControlledFinalizerWithoutChangingType(image: Image) throws {
        let (original, patched) = try fullImagePair(image)
        let signed = try Data(contentsOf: URL(fileURLWithPath: #require(Self.signedApp)))
        let blob = try superBlob(signed)
        let slots = (0 ..< Int(word(blob, 8, bigEndian: true))).map { 12 + $0 * 8 }
        try #require(slots.contains { word(blob, $0, bigEndian: true) == 0x10000 })
        #if arch(arm64)
            try executeProfileValidation(image: original, layout: image, blob: blob, allowsMissing: false)
            try executeProfileValidation(image: patched, layout: image, blob: blob, allowsMissing: true)
        #endif
    }

    private func word(_ data: Data, _ offset: Int, bigEndian: Bool = false) -> UInt32 {
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    private func superBlob(_ signed: Data) throws -> Data {
        try #require(signed.count >= 32 && word(signed, 0) == 0xfeedfacf)
        var cursor = 32
        for _ in 0 ..< word(signed, 16) {
            try #require(cursor + 16 <= signed.count)
            let size = Int(word(signed, cursor + 4))
            try #require(size >= 8 && cursor + size <= signed.count)
            if word(signed, cursor) == 0x1d {
                let offset = Int(word(signed, cursor + 8))
                let length = Int(word(signed, cursor + 12))
                try #require(length >= 12 && offset + length <= signed.count)
                return signed.subdata(in: offset ..< offset + length)
            }
            cursor += size
        }
        throw PatcherError.invalidFormat("Test input has no LC_CODE_SIGNATURE")
    }

    #if arch(arm64)
        private func executeProfileValidation(image: Data, layout: Image, blob: Data, allowsMissing: Bool, earlierError: UInt64? = nil) throws {
            let page = Int(getpagesize())
            let size = (image.count + page - 1) / page * page
            let executable = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
            try #require(executable != MAP_FAILED)
            defer { munmap(executable, size) }
            image.withUnsafeBytes { executable.copyMemory(from: $0.baseAddress!, byteCount: image.count) }
            try #require(mprotect(executable, size, PROT_READ | PROT_EXEC) == 0)
            sys_icache_invalidate(executable, size)
            typealias Check = @convention(c) (UnsafeMutableRawPointer) -> UInt64
            typealias Validate = @convention(c) (UnsafeRawPointer, UInt64, UnsafeMutableRawPointer?) -> UInt64
            typealias ReadType = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> UInt64
            let validate = unsafeBitCast(executable.advanced(by: layout.validator), to: Validate.self)
            let check = unsafeBitCast(executable.advanced(by: layout.check), to: Check.self)
            let finalize = unsafeBitCast(executable.advanced(by: layout.finalizer), to: Check.self)
            // The mapping-association handler calls this exact getter before
            // its type >= 6 full-segment and high-type main-alias restrictions.
            let mappingType = unsafeBitCast(executable.advanced(by: layout.getter), to: ReadType.self)

            let state = UnsafeMutableRawPointer.allocate(byteCount: 0x480, alignment: 16)
            defer { state.deallocate() }
            state.initializeMemory(as: UInt8.self, repeating: 0, count: 0x480)
            let policy = state.advanced(by: 0x60)
            let signature = state.advanced(by: 0x160)
            let invalidProfile = state.advanced(by: 0x280) // native profile trusted flag (+0x181) is clear
            policy.storeBytes(of: state, as: UnsafeMutableRawPointer.self)
            signature.storeBytes(of: policy, as: UnsafeMutableRawPointer.self)
            let slots = (0 ..< Int(word(blob, 8, bigEndian: true))).map { 12 + $0 * 8 }
            let cdSlot = try #require(slots.first { word(blob, $0, bigEndian: true) == 0 })
            let cd = Int(word(blob, cdSlot + 4, bigEndian: true))
            try #require(cd + 8 <= blob.count)
            let cdLength = UInt64(word(blob, cd + 4, bigEndian: true))
            try #require(cd + Int(cdLength) <= blob.count)
            try blob.withUnsafeBytes { raw in
                let base = try #require(raw.baseAddress)
                let length = UInt64(word(blob, 4, bigEndian: true))
                try #require(length <= UInt64(blob.count))
                try #require(validate(base, length, nil) & 0xff00 == 0)
                #expect(validate(base, length - 1, nil) & 0xff00 != 0)
                signature.storeBytes(of: base, toByteOffset: 0x18, as: UnsafeRawPointer.self)
                signature.storeBytes(of: length, toByteOffset: 0x20, as: UInt64.self)
                signature.storeBytes(of: UInt8(1), toByteOffset: 0x29, as: UInt8.self)
                signature.storeBytes(of: UInt8(1), toByteOffset: 0x2a, as: UInt8.self)
                signature.storeBytes(of: base.advanced(by: cd), toByteOffset: 0x30, as: UnsafeRawPointer.self)
                signature.storeBytes(of: cdLength, toByteOffset: 0x38, as: UInt64.self)
                #expect(check(signature) == (allowsMissing ? 0xa6 : 0x112a6))

                // Explicit type inputs isolate finalization, not CMS crypto or
                // the live VM's callback/profile-registration state.
                for type: UInt8 in [4, 5] {
                    signature.storeBytes(of: type, toByteOffset: layout.category, as: UInt8.self)
                    signature.storeBytes(of: UInt8(0), toByteOffset: layout.category + 1, as: UInt8.self)
                    let expected: UInt64 = earlierError ?? (allowsMissing || type == 5 ? 3 : 0x112a6)
                    let succeeds = expected & 0xff00 == 0
                    #expect(finalize(signature) == expected)
                    #expect(signature.load(fromByteOffset: layout.category, as: UInt8.self) == type)
                    #expect(signature.load(fromByteOffset: layout.category + 1, as: UInt8.self) == (succeeds ? type : 0))
                    var publishedType: UInt8 = 0xff
                    #expect(mappingType(signature, &publishedType) == 8)
                    #expect(publishedType == (succeeds ? type : 0))
                    if succeeds { #expect(publishedType < 6) }
                }

                signature.storeBytes(of: UInt8(4), toByteOffset: layout.category, as: UInt8.self)
                signature.storeBytes(of: UInt8(0), toByteOffset: layout.category + 1, as: UInt8.self)
                signature.storeBytes(of: invalidProfile, toByteOffset: layout.category + 7, as: UnsafeMutableRawPointer.self)
                #expect(check(signature) == 0x12225)
                #expect(finalize(signature) == (earlierError ?? 0x12225))
                #expect(signature.load(fromByteOffset: layout.category + 1, as: UInt8.self) == 0)

                // An earlier platform-only policy still rejects type 4 even
                // with no profile. The patch must not force selector 24 pass.
                signature.storeBytes(of: UInt64(0), toByteOffset: layout.category + 7, as: UInt64.self)
                state.storeBytes(of: UInt8(1), toByteOffset: 6, as: UInt8.self)
                #expect(finalize(signature) & 0xff00 != 0)
            }
        }
    #endif
}
