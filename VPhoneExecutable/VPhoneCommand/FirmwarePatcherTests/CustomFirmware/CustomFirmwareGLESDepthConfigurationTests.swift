import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("GLES compiler depth configuration")
struct CustomFirmwareGLESDepthConfigurationTests {
    let payload = Data("VPHONE_GLES_DEPTH_CLIP_V1:0\0".utf8)
    let payloadOffset = 0x100

    func fixture() -> Data {
        var data = Data(count: payloadOffset) + payload
        func put(_ value: UInt32, at offset: Int) { data.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value)) }
        func string(_ value: String, at offset: Int) { data.replaceSubrange(offset ..< offset + value.utf8.count, with: value.utf8) }
        put(0xFEED_FACF, at: 0)
        put(1, at: 16)
        put(152, at: 20)
        put(0x19, at: 32)
        put(152, at: 36)
        string("__DATA", at: 40)
        put(1, at: 96)
        string("__vphone_gles", at: 104)
        string("__DATA", at: 120)
        put(UInt32(payload.count), at: 144)
        put(UInt32(payloadOffset), at: 152)
        return data
    }

    @Test func `selection changes only the configuration byte and both directions are idempotent`() throws {
        var data = fixture()
        let original = data
        #expect(try CustomFirmwareGLESDepthConfiguration.configure(&data, enabled: false) == false)
        #expect(try CustomFirmwareGLESDepthConfiguration.configure(&data, enabled: true))
        #expect(data.indices.filter { data[$0] != original[$0] } == [data.count - 2])
        #expect(try CustomFirmwareGLESDepthConfiguration.configure(&data, enabled: true) == false)
        #expect(try CustomFirmwareGLESDepthConfiguration.configure(&data, enabled: false))
        #expect(data == original)
    }

    @Test func `truncated or malformed sections refuse without writing`() throws {
        let original = fixture()
        var cases = (0 ..< original.count).map { Data(original.prefix($0)) }
        for (offset, bytes) in [
            (0, ARM64.encodeU32(0)), (36, ARM64.encodeU32(72)),
            (40, Data("x".utf8)), (104, Data("x".utf8)),
            (144, ARM64.encodeU32(UInt32.max)), (152, ARM64.encodeU32(UInt32.max)),
            (payloadOffset, Data("x".utf8)),
            (original.count - 2, Data("2".utf8)), (original.count - 1, Data([1])),
        ] {
            var changed = original
            changed.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
            cases.append(changed)
        }
        for var data in cases {
            let before = data
            #expect(throws: PatcherError.self) { try CustomFirmwareGLESDepthConfiguration.configure(&data, enabled: true) }
            #expect(data == before)
        }
    }
}
