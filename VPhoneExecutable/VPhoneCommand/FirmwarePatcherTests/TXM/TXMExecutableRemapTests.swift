import CryptoKit
import Darwin
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit
import VPhoneSign

@Suite("TXM native classification for remapping")
struct TXMExecutableRemapTests {
    static var reference: String? { ProcessInfo.processInfo.environment["VPHONE_REMAP_TXM"] }
    static var reference26_1: String? { ProcessInfo.processInfo.environment["VPHONE_REMAP_TXM_26_1"] }

    // Unmodified functions from TXM 187.100.3, relative to its v2 cache search.
    // Retaining relative positions preserves direct calls and cold-block branches
    // when the fixture is relocated. External callees are not executed here.
    private static let fragments: [(Int, String)] = [
        (0x0, """
        7f2303d5ffc301d1fc6f01a9fa6702a9f85f03a9f65704a9f44f05a9fd7b06a9
        fd830191d38884525300a072081440b988040034f60301aaf50300aae20700f9
        190080521a050051186000911b03805234031a0b9c7e0153a81640b90805088b
        08f17dd30903088b100309ca1f264af2400000544914f9f29763bb9bff0218eb
        e22249fa42050054e00317aae10316aa82028052f4f9ff97800100346000f836
        99070011040000149f0a0071e30200549a0700513f031a6bc9fcff5413000014
        7342405111000014a81640b90805088b09f17dd30803098b100308ca1f264af2
        400000544814f9f2170100b4e90740f9a90000b4ff0208eba2010054e80740f9
        170500f9d3088052e00313aafd7b46a9f44f45a9f65744a9f85f43a9fa6742a9
        fc6f41a9ffc30191ff0f5fd620038052cae4ff97
        """),
        (0x4020, """
        7f2303d5ff4303d1fa6708a9f85f09a9f6570aa9f44f0ba9fd7b0ca9fd030391
        170040f900e4006fe00303ade00302ade00301adff7f01a9ff0700f9ff1f0039
        e8620391ff0208eba2150054f30301aaf40300aae80240f918294139e85a40f9
        a80000b4f1a394d211093fd7080000521801180a39608152d95bbf7235928452
        3500a072800643a9e21f0091030080d269feff97808641a93600a0522200a052
        23608152c35bbf72040080d226f9ff97e00100b4e3230091020080d260f9ff97
        e28f40a9e84e4339e083009101010012d6f3ff971f1c1872e0000054087c0853
        163c1012f50300aa480000148824805246000014808641a92307041102008052
        040080d210f9ff97c00100b4e203012a5f0002eb480f0054f60300aae0830091
        e10316aafff3ff971f1c187220010054f50300aa087c0853163c101233000014
        b54240115600a052884480522f000014823a40f95fc000f1280d0054e31f4039
        e08300918102019193f4ff97083c0853680100341f910071c1fdff54881a40f9
        1f0116ebc00000547600a05228658052353285527500a0721c000014e0830091
        e1630091ebf4ff97eb0240f96aa540a9680d40f9ec4e4339cc0000366c1940f9
        8a010aaa6c2d42a9890109aa680108aaeb0f40f97f010aeaa000005408008052
        16008052c9008052060000147f0109ea200200540800805216008052a9008052
        6902003935128052081d1853a91e0012c902092a2001082afd7b4ca9f44f4ba9
        f6574aa9f85f49a9fa6748a9ff430391ff0f5fd67f0108ea2001005488008052
        68020039e083009181420491b6f4ff970800805216008052ebffff1778020036
        e83a40f9312a88d211093fd70900018b100009ca1f264af2400000544914f9f2
        290100cb3f0009eba8030054e80300aae20301aae0830091e10308aa0ef4ff97
        1f1c187240020054355284529500a072e846433968010036e852433928010037
        080080521600805289aa40393f01007249018052aa0080524911891ac9ffff17
        9600a05248848052c8ffff17080080521600805269008052c2ffff1720038052
        4ed4ff97
        """),
        (0x4458, """
        7f2303d5ffc301d1fa6702a9f85f03a9f65704a9f44f05a9fd7b06a9fd830191
        f30301aaf40300aaff7f01a9960644f8ff0700f9c81240f9680000b5c80e40f9
        480400b4d7c24039ff020072e843009115119f9ab8feffd018e7149179008052
        c81240f9480000b5c80e40f900f35f38e10314aae20315aa31ca8fd211093fd7
        1f1c1872e100005497010036e0430091e123009185f0ff97e8234039e8000836
        180b0091390700f1c1fdff54003285524000a072070000140803403968020039
        0012805203000014001285522000a072fd7b46a9f44f45a9f65744a9f85f43a9
        fa6742a9ffc30191ff0f5fd6
        """),
        (0x52d0, """
        7f2303d5ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f30301aaf40300aa
        080040f9150140f9ff0700f9ff0700b9001840f9811e40f9e21300917df8ff97
        800643a9e2230091c2f8ff97e80740b97f1a0071a3000054a90640f9690000b4
        201480520900001408011f12e90740f93f0100f1e9079f1a3f05486b01010054
        201486522000a072fd7b43a9f44f42a9f65741a9ff030191ff0f5fd67f160071
        08feff54690600513f0500716800005488fdff350200001448fdff3420b48552
        4000a072f1ffff17
        """),
        (0x6770, """
        7f2303d5ff0302d1fa6703a9f85f04a9f65705a9f44f06a9fd7b07a9fdc30191
        f40301aaf30300aaff7f02a9ff3f0079ffff00a9e17f009119fdff97e17b0091
        e00314aa16fdff97e87f403968010034e87b403988010034fa2085521a01a072
        680240f9890240f91f0109eb000200545503103206000014f54084523500a072
        03000014f54084525500a072e00315aafd7b47a9f44f46a9f65745a9f85f44a9
        fa6743a9ff030291ff0f5fd6786643a9965e43a9e4430091e00318aae10319aa
        020080d2030080d2a4f3ff971f1c1872c1000054e843403988000037f5c08552
        7500a072eaffff17e4230091e00316aae10317aa020080d2030080d297f3ff97
        1f1c187261000054e823403968030037e87b40391f19007143010054f5008052
        1f1d007141fbff54e00313aae10314aa61ffff971f1c1872b502801ad4ffff17
        1f090071200200541f050071c102005461fefff021e83491e00313aa34feff97
        1f1c1872087686522800a072e90080523501881ac6ffff17e8c085526800a072
        15414011c2ffff17e00313aae10314aafefeff971f1c1872e80080521501801a
        bbffff17e97f40391f01096b82000054f5008652b500a072b5ffff17f5808452
        d500a072e2a30091e00318aae10319aa38f3ff97e2830091e00316aae10317aa
        34f3ff97e01740f920f5ffb4e11340f9c10000b421e0ff971f000071e8008052
        15019a1aa2ffff17b5424011a0ffff17
        """),
        (0x5820, """
        7f2303d5ffc300d1f44f01a9fd7b02a9fd830091f40300aa408080522000a072
        ff0f00b988a64039a80300368806443968000034004c401119000014f30301aa
        800643a9e233009126f7ff9781060491e00314aaf9faff971f1c187280010054
        880240f9084143392802003689aa403948018052a9000036e93340393f011f72
        a90080522801881a88060439730000b4880644396802003940008052fd7b42a9
        f44f41a9ffc30091ff0f5fd6e8334039e800083781060491e00314aad1f9ff97
        1f1c187240feff54f5ffff1781060491e00314aab5faff971f1c187280fdff54
        81060491e00314aa87faff971f1c1872e0fcff54880240f90845433968000036
        48018052e1ffff17404084526000a072e3ffff17
        """),
    ]

    // Unmodified functions from cloudOS 26.1 (23B85) TXM, relative to its v2
    // cache search at 0x2c164 (raw SHA-256 ec68dc5a1ec77d8399365f7164e0384539c75e06ed9555f793ce5ff34a9c1db6).
    private static let cloudOS26_1Fragments: [(Int, String)] = [
        (0x0, """
        7f2303d5ffc301d1fc6f01a9fa6702a9f85f03a9f65704a9f44f05a9fd7b06a9
        fd830191d38884525300a072081440b988040034f60301aaf50300aae20700f9
        190080521a050051186000911b03805234031a0b9c7e0153a81640b90805088b
        08f17dd30903088b100309ca1f264af2400000544914f9f29763bb9bff0218eb
        e22249fa42050054e00317aae10316aa820280529efaff97800100346000f836
        99070011040000149f0a0071e30200549a0700513f031a6bc9fcff5413000014
        7342405111000014a81640b90805088b09f17dd30803098b100308ca1f264af2
        400000544814f9f2170100b4e90740f9a90000b4ff0208eba2010054e80740f9
        170500f9d3088052e00313aafd7b46a9f44f45a9f65744a9f85f43a9fa6742a9
        fc6f41a9ffc30191ff0f5fd620038052f8e5ff97
        """),
        (0x3f88, """
        7f2303d5ff4303d1fa6708a9f85f09a9f6570aa9f44f0ba9fd7b0ca9fd030391
        170040f900e4006fe00303ade00302ade00301adff7f01a9ff0700f9ff1f0039
        e8420391ff0208eb82150054f30301aaf40300aae80240f918294139e85640f9
        a80000b4f1a394d211093fd7080000521801180a39608152d95bbf7235928452
        3500a072800643a9e21f0091030080d268feff97808641a93600a0522200a052
        23608152c35bbf72040080d22af9ff97e00100b4e3230091020080d266f9ff97
        e28f40a9e82e4339e083009101010012cef3ff971f1c1872e0000054087c0853
        163c1012f50300aa460000148824805244000014808641a92307041102008052
        040080d214f9ff97c00100b4e203012a5f0002eb280f0054f60300aae0830091
        e10316aa01f4ff971f1c187220010054f50300aa087c0853163c101231000014
        b54240115600a052884480522d00001481020191e31f4039e083009182028052
        9af4ff97083c0853680100341f91007101feff54881a40f91f0116ebc0000054
        7600a05228658052353285527500a0721c000014e0830091e1630091f2f4ff97
        e90240f9280540f92005c03dea2e4339aa0000362a1940f9480108aa2109c03d
        201ca04ee90f40f93f0108eaa00000540800805216008052c900805207000014
        0800669e3f0108ea200200540800805216008052a90080526902003935128052
        081d1853a91e0012c902092a2001082afd7b4ca9f44f4ba9f6574aa9f85f49a9
        fa6748a9ff430391ff0f5fd6083c184e3f0108ea200100548800805268020039
        81c20291e0830091bcf4ff970800805216008052eaffff1778020036e83640f9
        312a88d211093fd70900018b100009ca1f264af2400000544914f9f2290100cb
        3f0009eba8030054e80300aae20301aae0830091e10308aa14f4ff971f1c1872
        40020054355284529500a072e826433968010036e83243392801003708008052
        1600805289aa40393f01007249018052aa0080524911891ac8ffff179600a052
        48848052c7ffff17080080521600805269008052c1ffff1720038052a3d5ff97
        """),
        (0x43bc, """
        7f2303d5ffc301d1fa6702a9f85f03a9f65704a9f44f05a9fd7b06a9fd830191
        ff7f01a9160040f9ff0700f9c80e40f9e80300b4f30301aad7a24039ff020072
        e843009114119f9aa8feffd008613391180500911500019179008052c80e40f9
        00f35f38e10315aae20314aa31ca8fd211093fd71f1c1872e1000054f7010036
        e0430091e123009180f0ff97e823403948010836180b0091390700f101feff54
        003285524000a07207000014001285522000a072040000140803403968020039
        00128052fd7b46a9f44f45a9f65744a9f85f43a9fa6742a9ffc30191ff0f5fd6
        """),
        (0x5234, """
        7f2303d5ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f30301aaf40300aa
        080040f9150140f9ff0700f9ff0700b9001840f9811e40f9e213009181f8ff97
        800643a9e2230091c6f8ff97e80740b97f1a0071a3000054a90640f9690000b4
        201480520900001408011f12e90740f93f0100f1e9079f1a3f05486b01010054
        201486522000a072fd7b43a9f44f42a9f65741a9ff030191ff0f5fd67f160071
        08feff54690600513f0500716800005488fdff350200001448fdff3420b48552
        4000a072f1ffff17
        """),
        (0x575c, """
        7f2303d5ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f50300aa40808052
        2000a072ff0f00b9a8a64039c8030036a886423968000034004c40111a000014
        f30301aab4860291a00643a9e233009132f7ff97e00315aae10314aa01fbff97
        1f1c187280010054a80240f90821433948020036a9aa403948018052a9000036
        e93340393f011f72a90080522801881a88020039730000b48802403968020039
        40008052fd7b43a9f44f42a9f65741a9ff030191ff0f5fd6e8334039e8000837
        e00315aae10314aad9f9ff971f1c1872a1feff54f0ffff17e00315aae10314aa
        bcfaff971f1c187260fdff54e00315aae10314aa8efaff971f1c1872c0fcff54
        a80240f9082543396800003648018052e0ffff17404084526000a072e2ffff17
        """),
        (0x6724, """
        7f2303d5ff0302d1fa6703a9f85f04a9f65705a9f44f06a9fd7b07a9fdc30191
        f40301aaf30300aaff7f02a9ff3f0079ffff00a9e17f0091fefcff97e17b0091
        e00314aafbfcff97e87f403968010034e87b403988010034fa2085521a01a072
        680240f9890240f91f0109eb000200545503103206000014f54084523500a072
        03000014f54084525500a072e00315aafd7b47a9f44f46a9f65745a9f85f44a9
        fa6743a9ff030291ff0f5fd6786643a9965e43a9e4430091e00318aae10319aa
        020080d2030080d294f3ff971f1c1872c1000054e843403988000037f5c08552
        7500a072eaffff17e4230091e00316aae10317aa020080d2030080d287f3ff97
        1f1c187261000054e823403968030037e87b40391f19007143010054f5008052
        1f1d007141fbff54e00313aae10314aa61ffff971f1c1872b502801ad4ffff17
        1f090071200200541f050071c102005481feff9021e83691e00313aa24feff97
        1f1c1872087686522800a072e90080523501881ac6ffff17e8c085526800a072
        15414011c2ffff17e00313aae10314aafefeff971f1c1872e80080521501801a
        bbffff17e97f40391f01096b82000054f5008652b500a072b5ffff17f5808452
        d500a072e2a30091e00318aae10319aa28f3ff97e2830091e00316aae10317aa
        24f3ff97e01740f920f5ffb4e11340f9c10000b4dee0ff971f000071e8008052
        15019a1aa2ffff17b5424011a0ffff17
        """),
    ]

    private func fixture(start: Int = 0x400, fragments: [(Int, String)] = Self.fragments) throws -> Data {
        var image = Data(repeating: 0, count: start + 0x6980)
        func u32(_ offset: Int, _ value: UInt32) {
            image.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value))
        }
        func u64(_ offset: Int, _ value: UInt64) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { image.replaceSubrange(offset ..< offset + 8, with: $0) }
        }
        u32(0, 0xFEED_FACF)
        u32(4, 0x0100_000C)
        u32(8, 2)
        u32(12, 2)
        u32(16, 1)
        u32(20, 72)
        u32(32, 0x19)
        u32(36, 72)
        image.replaceSubrange(40 ..< 51, with: Data("__TEXT_EXEC\0".utf8))
        u64(56, UInt64(start))
        u64(64, UInt64(image.count - start))
        u64(72, UInt64(start))
        u64(80, UInt64(image.count - start))
        u32(88, 5)
        u32(92, 5)
        for (offset, string) in fragments {
            let hex = string.filter { !$0.isWhitespace }
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(try #require(UInt8(hex[index ..< next], radix: 16)))
                index = next
            }
            image.replaceSubrange(start + offset ..< start + offset + bytes.count, with: bytes)
        }
        return image
    }

    @Test(arguments: [0x400, 0x8400])
    func preservesRealLookupAndAllNativeTypeAssignments(start: Int) throws {
        let data = try fixture(start: start)
        let patcher = TXMDevPatcher(data: data, verbose: false)
        try patcher.patchExecutableRemap()
        #expect(patcher.patches.map(\.patchID) == [
            "txm-boot-trustcache_bypass", "txm-cfw-executable_remap.cms", "txm-cfw-executable_remap.adhoc", "txm-cfw-executable_remap.ldid", "txm-cfw-executable_remap.library",
        ])
        #expect(patcher.patches.map(\.fileOffset) == [start + 0x530c, start + 0x42d4, start + 0x591c, start + 0x40d0, start + 0x692c])
        let count = try patcher.apply()
        #expect(count == 5)
        var expected = data
        expected.replaceSubrange(start + 0x530c ..< start + 0x5310, with: ARM64.movX0_0)
        expected.replaceSubrange(start + 0x42d4 ..< start + 0x42d8, with: ARM64.nop)
        expected.replaceSubrange(start + 0x591c ..< start + 0x5920, with: ARM64.nop)
        expected.replaceSubrange(start + 0x40d0 ..< start + 0x40d4, with: try #require(ARM64Encoder.encodeCompareBranch(
            nonzero: false, register: 0, from: start + 0x40d0, to: start + 0x42d0, width64: true,
        )))
        expected.replaceSubrange(start + 0x692c ..< start + 0x6934, with:
            try #require(ARM64Encoder.encodeMovzW(rd: 21, imm16: 7))
                + #require(ARM64Encoder.encodeB(from: start + 0x6930, to: start + 0x67fc)))
        #expect(patcher.patchedData == expected)
        // In particular the real cdhash comparison, successful cache/CMS exits,
        // CS_ADHOC split, path marker, type assignments and CMS digest errors stay.
        let absent = try #require(ARM64Disassembler().disassembleOne(in: patcher.patchedData, at: start + 0x40d0))
        #expect(absent.mnemonic == "cbz")
        #expect(absent.detail?.operands.first?.reg == .x(0))
        #expect(absent.detail?.operands.last?.imm == Int64(start + 0x42d0))
        let legacy = TXMDevPatcher(data: data, verbose: false)
        try legacy.patchTrustcacheBypass()
        #expect(legacy.patches.map(\.fileOffset) == [start + 0x94])
        #expect(patcher.patchedData[start + 0x94 ..< start + 0x98] == data[start + 0x94 ..< start + 0x98])
    }

    @Test(arguments: [
        0x591c, // ad-hoc tolerance gate
        0x42d4, // CMS tolerance gate
        0x42dc, // second CMS restriction must remain
        0x42f8, // native path-dependent category selection
        0x58d0, // CS_ADHOC split before CMS
        0x530c, // alternate base bypass: no legacy fallback on failure
        0x40bc, // CMS slot selector
        0x40c4, // CMS wrapper magic
        0x40d0, // absent wrapper branch
        0x410c, // original missing-wrapper error exit
        0x6884, // library type-6 split
        0x68b0, // special type-2 path
        0x6914, // ordinary library category comparison
        0x6940, // first Team ID reader call
    ])
    func changedPolicyDoesNotEmitPartialRevision(offset: Int) throws {
        var data = try fixture()
        data.replaceSubrange(0x400 + offset ..< 0x404 + offset, with: ARM64.nop)
        let patcher = TXMDevPatcher(data: data, verbose: false)
        #expect(throws: PatcherError.self) { try patcher.patchExecutableRemap() }
        #expect(patcher.patches.isEmpty)
        #expect(patcher.patchedData == data)
    }

    @Test(arguments: [0x400, 0x8400])
    func cloudOS26_1CategoryPointerLayout(start: Int) throws {
        let data = try fixture(start: start, fragments: Self.cloudOS26_1Fragments)
        let patcher = TXMDevPatcher(data: data, verbose: false)
        try patcher.patchExecutableRemap()
        #expect(patcher.patches.map(\.patchID) == [
            "txm-boot-trustcache_bypass", "txm-cfw-executable_remap.cms", "txm-cfw-executable_remap.adhoc", "txm-cfw-executable_remap.ldid", "txm-cfw-executable_remap.library",
        ])
        #expect(patcher.patches.map(\.fileOffset) == [start + 0x5270, start + 0x4238, start + 0x5864, start + 0x4038, start + 0x68e0])
        #expect(try patcher.apply() == 5)
        var expected = data
        expected.replaceSubrange(start + 0x5270 ..< start + 0x5274, with: ARM64.movX0_0)
        expected.replaceSubrange(start + 0x4238 ..< start + 0x423c, with: ARM64.nop)
        expected.replaceSubrange(start + 0x5864 ..< start + 0x5868, with: ARM64.nop)
        expected.replaceSubrange(start + 0x4038 ..< start + 0x403c, with: try #require(ARM64Encoder.encodeCompareBranch(
            nonzero: false, register: 0, from: start + 0x4038, to: start + 0x4234, width64: true,
        )))
        expected.replaceSubrange(start + 0x68e0 ..< start + 0x68e8, with:
            try #require(ARM64Encoder.encodeMovzW(rd: 21, imm16: 7))
                + #require(ARM64Encoder.encodeB(from: start + 0x68e4, to: start + 0x67b0)))
        #expect(patcher.patchedData == expected)
        #expect(patcher.patchedData[start + 0x94 ..< start + 0x98] == data[start + 0x94 ..< start + 0x98])
    }

    // Raw cloudOS 26.1 TXM offsets; the fixture places 0x2c164 at 0x400.
    @Test(arguments: [
        0x31904, // category pointer derived from the signature state
        0x31914, 0x31918, // pre-check state and category arguments
        0x31950, // category store through the pointer
        0x31990, 0x31994, // inverted CMS result branch and its success branch
        0x3197c, // CS_ADHOC split
        0x319c8, 0x3039c, // ad-hoc and CMS tolerance gates
        0x303a4, 0x303c0, // CMS restriction and path-dependent category
        0x3019c, // absent-wrapper exit
        0x313d4, // alternate base bypass
        0x329a0, 0x329cc, 0x32a30, 0x32a58, // library category and Team ID policy
    ])
    func changedCloudOS26_1PolicyDoesNotEmitPartialRevision(offset: Int) throws {
        var data = try fixture(fragments: Self.cloudOS26_1Fragments)
        let site = 0x400 + offset - 0x2c164
        data.replaceSubrange(site ..< site + 4, with: ARM64.nop)
        let patcher = TXMDevPatcher(data: data, verbose: false)
        #expect(throws: PatcherError.self) { try patcher.patchExecutableRemap() }
        #expect(patcher.patches.isEmpty)
        #expect(patcher.patchedData == data)
    }

    @Test
    func redefinedCloudOS26_1CategoryPointerIsRejected() throws {
        var data = try fixture(fragments: Self.cloudOS26_1Fragments)
        // `ldrb w8, [x20]` in the output block becomes a write to the pointer.
        let site = 0x400 + 0x31958 - 0x2c164
        data.replaceSubrange(site ..< site + 4, with: try #require(ARM64Encoder.encodeMovzX(rd: 20, imm16: 0)))
        let patcher = TXMDevPatcher(data: data, verbose: false)
        #expect(throws: PatcherError.self) { try patcher.patchExecutableRemap() }
        #expect(patcher.patches.isEmpty)
    }

    @Test
    func missingOrAmbiguousPolicyCallbackIsRejected() throws {
        var ambiguous = try fixture()
        // Duplicate the pre-check, preserving its authentication and return codes.
        let duplicate = ambiguous[0x400 + 0x4458 ..< 0x400 + 0x4544]
        ambiguous.replaceSubrange(0x1400 ..< 0x1400 + duplicate.count, with: duplicate)
        for data in [Data(), ambiguous] {
            let patcher = TXMDevPatcher(data: data, verbose: false)
            #expect(throws: PatcherError.self) { try patcher.patchExecutableRemap() }
            #expect(patcher.patches.isEmpty)
        }
    }

    @Test
    func alreadyBypassedCacheComparisonRequiresPristineFirmware() throws {
        var data = try fixture()
        data.replaceSubrange(0x494 ..< 0x498, with: ARM64.movX0_0)
        let patcher = TXMDevPatcher(data: data, verbose: false)
        #expect(throws: PatcherError.self) { try patcher.patchExecutableRemap() }
        #expect(patcher.patches.isEmpty)
        #expect(patcher.patchedData == data)
    }

    @Test
    func disabledPatchDoesNotRequireThisTXMShape() throws {
        let patcher = TXMDevPatcher(data: Data(), verbose: false)
        patcher.gate = VPhonePatchGate(declared: [TXMDevPatcher.executableRemapID], enabled: [])
        try patcher.patchExecutableRemap()
        #expect(patcher.patches.isEmpty)
    }

    @Test
    func declarationCoversAllPathsWithoutVersionRestrictions() throws {
        let declaration = try #require(FirmwarePatchSetCatalog.allDeclarations.first {
            $0.identifier == TXMDevPatcher.executableRemapID
        })
        #expect(declaration.covers(recordIdentifier: TXMDevPatcher.executableRemapID + ".cms"))
        #expect(declaration.covers(recordIdentifier: TXMDevPatcher.executableRemapID + ".adhoc"))
        #expect(declaration.covers(recordIdentifier: TXMDevPatcher.executableRemapID + ".ldid"))
        #expect(declaration.covers(recordIdentifier: TXMDevPatcher.executableRemapID + ".library"))
        #expect(!declaration.bootEssential)
        #expect(declaration.applicability == .always)
        #expect(!FirmwarePatchSetCatalog.allDeclarations.contains { $0.identifier == "txm-boot-precheck_admission" })
        for iOSBase in [nil, "18.7.2", "26.6.1", "27.0.1"] as [String?] {
            for cloudOS in [nil, "26.1", "26.3", "26.4", "26.5"] as [String?] {
                for blocked in [false, true] {
                    var preset = FirmwarePatchSetCatalog.standardPreset
                    if blocked { preset.selection = preset.selection.blocking([TXMDevPatcher.executableRemapID]) }
                    let plan = try VPhonePatchPlan.resolve(
                        preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                        iOSBase: iOSBase.flatMap { VPhoneVersion($0) }, cloudOS: cloudOS.flatMap { VPhoneVersion($0) },
                    )
                    #expect(plan.isEnabled(TXMDevPatcher.executableRemapID) == !blocked)
                }
            }
        }
    }

    @Test(.enabled(if: reference != nil))
    func suppliedTXMPreservesAssociationAndFinalValidation() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.reference)))
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(sha256 == "819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1")
        func patcher(blocked: Bool, iOSBase: String = "26.6.1") throws -> TXMDevPatcher {
            var preset = FirmwarePatchSetCatalog.standardPreset
            if blocked { preset.selection = preset.selection.blocking([TXMDevPatcher.executableRemapID]) }
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(iOSBase), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(TXMDevPatcher.executableRemapID) == !blocked)
            let patcher = TXMDevPatcher(data: data, verbose: false)
            patcher.gate = VPhonePatchGate(plan: plan)
            try patcher.apply()
            #expect(patcher.patches.allSatisfy { !patcher.gate.isUndeclared(record: $0.patchID) })
            return patcher
        }
        let baseline = try patcher(blocked: true)
        let patched = try patcher(blocked: false)
        #expect(patched.patches.count == baseline.patches.count + 4)
        var expected = baseline.patchedData
        expected.replaceSubrange(0x2c7e8 ..< 0x2c7ec, with: data[0x2c7e8 ..< 0x2c7ec])
        expected.replaceSubrange(0x31a60 ..< 0x31a64, with: ARM64.movX0_0)
        expected.replaceSubrange(0x30a28 ..< 0x30a2c, with: ARM64.nop)
        expected.replaceSubrange(0x32070 ..< 0x32074, with: ARM64.nop)
        expected.replaceSubrange(0x30824 ..< 0x30828, with: try #require(ARM64Encoder.encodeCompareBranch(
            nonzero: false, register: 0, from: 0x30824, to: 0x30a24, width64: true,
        )))
        expected.replaceSubrange(0x33080 ..< 0x33088, with:
            try #require(ARM64Encoder.encodeMovzW(rd: 21, imm16: 7))
                + #require(ARM64Encoder.encodeB(from: 0x33084, to: 0x32f50)))
        #expect(patched.patchedData == expected)
        #expect(patched.patchedData[0x1eb10 ..< 0x1efe4] == data[0x1eb10 ..< 0x1efe4])
        #expect(patched.patchedData[0x32088 ..< 0x321f8] == data[0x32088 ..< 0x321f8])
        #expect(patched.patchedData[0x30bac ..< 0x30c98] == data[0x30bac ..< 0x30c98])

        // iOS 27 uses the same native pre-check and fallback as iOS 26.
        // Disabling this patch must not bring back the forced type-10 override.
        let baseline27 = try patcher(blocked: true, iOSBase: "27.0.1")
        let patched27 = try patcher(blocked: false, iOSBase: "27.0.1")
        #expect(baseline27.patchedData == baseline.patchedData)
        #expect(patched27.patchedData == patched.patchedData)

        #if arch(arm64)
            // Execute the actual parser/classifier, not a model of their result.
            // The hash above pins the code before it can become executable.
            // Callbacks are absent and the container marker is an explicit input:
            // this proves the installer-signature path, not VM cache/profile setup.
            var previous = patched.patchedData
            previous.replaceSubrange(0x30824 ..< 0x30828, with: data[0x30824 ..< 0x30828])
            try executeInstallerClassification(image: previous, admitsMissingCMS: false)
            try executeInstallerClassification(image: patched.patchedData, admitsMissingCMS: true)
            for adHoc in [false, true] {
                try executeInstallerClassification(image: baseline27.patchedData, admitsMissingCMS: false, outerClassifier: true, adHoc: adHoc)
                try executeInstallerClassification(image: patched27.patchedData, admitsMissingCMS: true, outerClassifier: true, adHoc: adHoc)
            }
            try executeLibraryCompatibility(image: data, relaxed: false)
            try executeLibraryCompatibility(image: patched.patchedData, relaxed: true)
        #endif
    }

    @Test(.enabled(if: reference26_1 != nil))
    func suppliedCloudOS26_1TXMPreservesNativePolicy() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.reference26_1)))
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(sha256 == "ec68dc5a1ec77d8399365f7164e0384539c75e06ed9555f793ce5ff34a9c1db6")
        func patcher(blocked: Bool) throws -> TXMDevPatcher {
            var preset = FirmwarePatchSetCatalog.standardPreset
            if blocked { preset.selection = preset.selection.blocking([TXMDevPatcher.executableRemapID]) }
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("18.6.2"), cloudOS: VPhoneVersion("26.1"),
            )
            let patcher = TXMDevPatcher(data: data, verbose: false)
            patcher.gate = VPhonePatchGate(plan: plan)
            try patcher.apply()
            #expect(patcher.patches.allSatisfy { !patcher.gate.isUndeclared(record: $0.patchID) })
            return patcher
        }
        let baseline = try patcher(blocked: true)
        let patched = try patcher(blocked: false)
        #expect(patched.patches.count == baseline.patches.count + 4)
        var expected = baseline.patchedData
        expected.replaceSubrange(0x2c1f8 ..< 0x2c1fc, with: data[0x2c1f8 ..< 0x2c1fc])
        expected.replaceSubrange(0x313d4 ..< 0x313d8, with: ARM64.movX0_0)
        expected.replaceSubrange(0x3039c ..< 0x303a0, with: ARM64.nop)
        expected.replaceSubrange(0x319c8 ..< 0x319cc, with: ARM64.nop)
        expected.replaceSubrange(0x3019c ..< 0x301a0, with: try #require(ARM64Encoder.encodeCompareBranch(
            nonzero: false, register: 0, from: 0x3019c, to: 0x30398, width64: true,
        )))
        expected.replaceSubrange(0x32a44 ..< 0x32a4c, with:
            try #require(ARM64Encoder.encodeMovzW(rd: 21, imm16: 7))
                + #require(ARM64Encoder.encodeB(from: 0x32a48, to: 0x32914)))
        #expect(patched.patchedData == expected)

        #if arch(arm64)
            for adHoc in [false, true] {
                try executeInstallerClassification(image: baseline.patchedData, admitsMissingCMS: false,
                                                   outerClassifier: true, adHoc: adHoc, layout: .cloudOS26_1)
                try executeInstallerClassification(image: patched.patchedData, admitsMissingCMS: true,
                                                   outerClassifier: true, adHoc: adHoc, layout: .cloudOS26_1)
            }
            try executeLibraryCompatibility(image: data, relaxed: false, layout: .cloudOS26_1)
            try executeLibraryCompatibility(image: patched.patchedData, relaxed: true, layout: .cloudOS26_1)
        #endif
    }

    #if arch(arm64)
        /// Entry points and signature-state fields of the hash-pinned images above.
        private struct ExecutionLayout {
            let validator: Int, cms: Int, classifier: Int, finalizer: Int, library: Int
            let category: Int, restriction: Int
            static let cloudOS26_4 = Self(validator: 0x2e7b0, cms: 0x30774, classifier: 0x31f74,
                                          finalizer: 0x32088, library: 0x32ec4, category: 0x101, restriction: 0xd4)
            static let cloudOS26_1 = Self(validator: 0x2e124, cms: 0x300ec, classifier: 0x318c0,
                                          finalizer: 0x319e0, library: 0x32888, category: 0xa1, restriction: 0xcc)
        }

        private func executeLibraryCompatibility(image: Data, relaxed: Bool, layout: ExecutionLayout = .cloudOS26_4) throws {
            let size = (image.count + Int(getpagesize()) - 1) / Int(getpagesize()) * Int(getpagesize())
            let executable = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
            try #require(executable != MAP_FAILED)
            defer { munmap(executable, size) }
            image.withUnsafeBytes { executable.copyMemory(from: $0.baseAddress!, byteCount: image.count) }
            try #require(mprotect(executable, size, PROT_READ | PROT_EXEC) == 0)
            sys_icache_invalidate(executable, size)
            typealias Compare = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> UInt64
            let compare = unsafeBitCast(executable.advanced(by: layout.library), to: Compare.self)

            // Comparison inputs only. These are not authenticated signatures;
            // parser/classifier admission is exercised separately above.
            func directory(main: Bool, team: String?) -> Data {
                var data = Data(repeating: 0, count: 96)
                if let team { data.append(contentsOf: team.utf8); data.append(0) }
                for (offset, value): (Int, UInt32) in [
                    (0, 0xfade0c02), (4, UInt32(data.count)), (8, 0x20400), (48, team == nil ? 0 : 96),
                ] {
                    var value = value.bigEndian
                    withUnsafeBytes(of: &value) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
                }
                data[87] = main ? 1 : 0 // big-endian execSegFlags
                return data
            }
            struct Case {
                var main: UInt8 = 5; var library: UInt8 = 5
                var mainTeam: String?; var libraryTeam: String?
                var mainFlag = true; var libraryFlag = false; var samePolicy = true
                var original: UInt64; var compatible: UInt64
            }
            let cases: [Case] = [
                .init(original: 0x62407, compatible: 7),
                .init(libraryTeam: "team-a", original: 0x62407, compatible: 7),
                .init(mainTeam: "team-a", original: 0x72407, compatible: 7),
                .init(mainTeam: "team-a", libraryTeam: "team-a", original: 7, compatible: 7),
                .init(mainTeam: "team-a", libraryTeam: "team-b", original: 0x82907, compatible: 7),
                .init(main: 4, library: 4, libraryTeam: "team-a", original: 0x62407, compatible: 7),
                .init(main: 3, library: 3, mainTeam: "team-a", libraryTeam: "team-b", original: 0x82907, compatible: 7),
                .init(library: 4, libraryTeam: "team-a", original: 0x53007, compatible: 0x53007),
                .init(library: 3, original: 0x53007, compatible: 0x53007),
                .init(main: 0, original: 0x12207, compatible: 0x12207),
                .init(library: 0, original: 0x22207, compatible: 0x22207),
                .init(mainFlag: false, original: 0x32e07, compatible: 0x32e07),
                .init(libraryFlag: true, original: 0x42e07, compatible: 0x42e07),
                .init(samePolicy: false, original: 0x92907, compatible: 0x92907),
                .init(library: 6, original: 7, compatible: 7),
                .init(library: 8, original: 7, compatible: 7),
                .init(library: 9, original: 7, compatible: 7),
                .init(library: 10, original: 7, compatible: 7),
            ]
            for input in cases {
                let main = directory(main: input.mainFlag, team: input.mainTeam)
                let library = directory(main: input.libraryFlag, team: input.libraryTeam)
                let state = UnsafeMutableRawPointer.allocate(byteCount: 0x240, alignment: 16)
                defer { state.deallocate() }
                state.initializeMemory(as: UInt8.self, repeating: 0, count: 0x240)
                let other = state.advanced(by: 0x120)
                state.storeBytes(of: state, as: UnsafeMutableRawPointer.self)
                other.storeBytes(of: input.samePolicy ? state : other, as: UnsafeMutableRawPointer.self)
                state.storeBytes(of: input.main, toByteOffset: layout.category + 1, as: UInt8.self)
                other.storeBytes(of: input.library, toByteOffset: layout.category + 1, as: UInt8.self)
                main.withUnsafeBytes { a in library.withUnsafeBytes { b in
                    state.storeBytes(of: a.baseAddress!, toByteOffset: 0x30, as: UnsafeRawPointer.self)
                    state.storeBytes(of: UInt64(main.count), toByteOffset: 0x38, as: UInt64.self)
                    other.storeBytes(of: b.baseAddress!, toByteOffset: 0x30, as: UnsafeRawPointer.self)
                    other.storeBytes(of: UInt64(library.count), toByteOffset: 0x38, as: UInt64.self)
                    #expect(compare(state, other) == (relaxed ? input.compatible : input.original))
                } }
            }
        }

        private func executeInstallerClassification(
            image: Data, admitsMissingCMS: Bool, outerClassifier: Bool = false, adHoc: Bool = false,
            layout: ExecutionLayout = .cloudOS26_4,
        ) throws {
            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("VPhoneSignTestFixtures/Executables/hello-arm64")
            let signed = try VPhoneSigner.sign(Data(contentsOf: fixtureURL), options: .init(identifier: "remap-admission", style: adHoc ? .appleAdHoc : .ldid))
            func word(_ data: Data, _ offset: Int, bigEndian: Bool = false) -> UInt32 {
                let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                return bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
            }
            var cursor = 32
            var signatureRange: Range<Int>?
            for _ in 0 ..< word(signed, 16) {
                if word(signed, cursor) == 0x1d { // LC_CODE_SIGNATURE
                    let offset = Int(word(signed, cursor + 8))
                    signatureRange = offset ..< offset + Int(word(signed, cursor + 12))
                }
                cursor += Int(word(signed, cursor + 4))
            }
            let blob = signed.subdata(in: try #require(signatureRange))
            let slots = (0 ..< Int(word(blob, 8, bigEndian: true))).map { 12 + $0 * 8 }
            #expect(slots.contains { word(blob, $0, bigEndian: true) == 0x10000 } == adHoc)
            let cdSlot = try #require(slots.first { word(blob, $0, bigEndian: true) == 0 })
            let cdOffset = Int(word(blob, cdSlot + 4, bigEndian: true))
            #expect(word(blob, cdOffset + 12, bigEndian: true) == (adHoc ? 2 : 0))

            let size = (image.count + Int(getpagesize()) - 1) / Int(getpagesize()) * Int(getpagesize())
            let executable = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
            try #require(executable != MAP_FAILED)
            defer { munmap(executable, size) }
            image.withUnsafeBytes { executable.copyMemory(from: $0.baseAddress!, byteCount: image.count) }
            try #require(mprotect(executable, size, PROT_READ | PROT_EXEC) == 0)
            sys_icache_invalidate(executable, size)

            let state = UnsafeMutableRawPointer.allocate(byteCount: 0x280, alignment: 16)
            defer { state.deallocate() }
            state.initializeMemory(as: UInt8.self, repeating: 0, count: 0x280)
            let policy = state.advanced(by: 0x60)
            let signature = state.advanced(by: 0x160)
            policy.storeBytes(of: state, as: UnsafeMutableRawPointer.self)
            signature.storeBytes(of: policy, as: UnsafeMutableRawPointer.self)

            typealias Validate = @convention(c) (UnsafeRawPointer, UInt64, UnsafeMutableRawPointer?) -> UInt64
            typealias Classify = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> UInt64
            typealias Finalize = @convention(c) (UnsafeMutableRawPointer) -> UInt64
            let validate = unsafeBitCast(executable.advanced(by: layout.validator), to: Validate.self)
            // The outer entry executes the native pre-check before the fallback,
            // reproducing startup rejection without policy callbacks installed.
            let classify = unsafeBitCast(executable.advanced(by: outerClassifier ? layout.classifier : layout.cms), to: Classify.self)
            let finalize = unsafeBitCast(executable.advanced(by: layout.finalizer), to: Finalize.self)
            try blob.withUnsafeBytes { raw in
                let base = try #require(raw.baseAddress)
                let length = UInt64(word(blob, 4, bigEndian: true))
                try #require(validate(base, length, nil) & 0xff00 == 0)
                #expect(validate(base, length - 1, nil) & 0xff00 != 0)
                signature.storeBytes(of: base, toByteOffset: 0x18, as: UnsafeRawPointer.self)
                signature.storeBytes(of: length, toByteOffset: 0x20, as: UInt64.self)
                signature.storeBytes(of: UInt8(1), toByteOffset: 0x29, as: UInt8.self)
                signature.storeBytes(of: base.advanced(by: cdOffset), toByteOffset: 0x30, as: UnsafeRawPointer.self)
                signature.storeBytes(of: UInt64(word(blob, cdOffset + 4, bigEndian: true)), toByteOffset: 0x38, as: UInt64.self)
                for container: UInt8 in [0, 1] {
                    for restriction: UInt8 in [0, 1] {
                        signature.storeBytes(of: container, toByteOffset: 0x2a, as: UInt8.self)
                        signature.storeBytes(of: UInt8(0), toByteOffset: layout.category, as: UInt8.self)
                        policy.storeBytes(of: restriction, toByteOffset: layout.restriction, as: UInt8.self)
                        var type: UInt8 = 0
                        let result = classify(signature, &type)
                        if admitsMissingCMS && (adHoc || restriction == 0) {
                            #expect(result == (outerClassifier ? 2 : 0x91))
                            #expect(type == (adHoc ? 10 : (container == 1 ? 5 : 10)))
                            signature.storeBytes(of: type, toByteOffset: layout.category, as: UInt8.self)
                            signature.storeBytes(of: UInt8(0), toByteOffset: layout.category + 1, as: UInt8.self)
                            #expect(finalize(signature) == 3)
                            #expect(signature.load(fromByteOffset: layout.category + 1, as: UInt8.self) == type)
                            if type == 5 {
                                // Restoring low classification must not bypass
                                // the native platform-only policy if enabled.
                                signature.storeBytes(of: UInt8(0), toByteOffset: layout.category + 1, as: UInt8.self)
                                state.storeBytes(of: UInt8(1), toByteOffset: 6, as: UInt8.self)
                                #expect(finalize(signature) & 0xff00 != 0)
                                state.storeBytes(of: UInt8(0), toByteOffset: 6, as: UInt8.self)
                            }
                        } else {
                            #expect(result == (admitsMissingCMS ? 0x42291 : (adHoc ? 0x32202 : 0x12491)))
                            #expect(type == 0)
                        }
                    }
                }
            }
            if adHoc { return }
            // A present CMS slot with the wrong magic is not "absent": the
            // real SuperBlob validator must reject it before classification.
            var malformed = blob
            let requirements = try #require(slots.first { word(blob, $0, bigEndian: true) == 2 })
            var cmsSlot = UInt32(0x10000).bigEndian
            withUnsafeBytes(of: &cmsSlot) { malformed.replaceSubrange(requirements ..< requirements + 4, with: $0) }
            malformed.withUnsafeBytes {
                #expect(validate($0.baseAddress!, UInt64(word(malformed, 4, bigEndian: true)), nil) == 0x12961)
            }
        }
    #endif
}
