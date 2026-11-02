@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Paravirtual GPU OpenGL ES renderer")
struct KernelParavirtGLESTests {
    // The raw vphone600 research kernel is operator supplied, never redistributed.
    static var fixture: String? { ProcessInfo.processInfo.environment["VPHONE_GLES_KERNEL"] }

    /// A `__PRELINK_INFO` laid out as vphone600's: the paravirtual GPU kext and
    /// an unrelated one after it, then NUL padding to the end of the segment.
    static func prelinkInfo(gpuClass: String = "AppleParavirtGPU", category: String = "IOAcceleratorES", extraKeys: String = "") -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>_PrelinkInfoDictionary</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>CFBundleIdentifier</key>
        \t\t\t<string>com.apple.driver.AppleParavirtGPUIOGPUFamily</string>
        \t\t\t<key>IOKitPersonalities</key>
        \t\t\t<dict>
        \t\t\t\t<key>AppleParavirtGPUARM</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>CFBundleIdentifier</key>
        \t\t\t\t\t<string>com.apple.driver.AppleParavirtGPUIOGPUFamily</string>
        \t\t\t\t\t<key>IOClass</key>
        \t\t\t\t\t<string>\(gpuClass)</string>
        \(extraKeys)\t\t\t\t\t<key>IOMatchCategory</key>
        \t\t\t\t\t<string>\(category)</string>
        \t\t\t\t\t<key>IONameMatch</key>
        \t\t\t\t\t<string>paravirtualizedgraphics,gpu</string>
        \t\t\t\t\t<key>IOProviderClass</key>
        \t\t\t\t\t<string>AppleARMIODevice</string>
        \t\t\t\t\t<key>MetalPluginClassName</key>
        \t\t\t\t\t<string>AppleParavirtDevice</string>
        \t\t\t\t\t<key>MetalPluginName</key>
        \t\t\t\t\t<string>AppleParavirtGPUMetalIOGPUFamily</string>
        \t\t\t\t</dict>
        \t\t\t</dict>
        \t\t\t<key>MinimumOSVersion</key>
        \t\t\t<string>26.4</string>
        \t\t</dict>
        \t\t<dict>
        \t\t\t<key>CFBundleIdentifier</key>
        \t\t\t<string>com.apple.iokit.IOGPUFamily</string>
        \t\t\t<key>MinimumOSVersion</key>
        \t\t\t<string>26.4</string>
        \t\t</dict>
        \t</array>
        </dict>
        </plist>

        """
        var data = Data(xml.utf8)
        data.append(Data(repeating: 0, count: 64))
        return data
    }

    func patcher(_ data: Data, gate: VPhonePatchGate? = nil) -> KernelCustomFirmwarePatcher {
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.segments = [MachOSegmentInfo(name: "__PRELINK_INFO", vmAddr: 0x1000, vmSize: UInt64(data.count), fileOffset: 0, fileSize: UInt64(data.count))]
        if let gate {
            patcher.gate = gate
        }
        return patcher
    }

    func personalities(_ data: Data) throws -> [[String: Any]] {
        let end = try #require(data.range(of: Data("</plist>".utf8)))
        let plist = try #require(PropertyListSerialization.propertyList(from: data[..<end.upperBound], format: nil) as? [String: Any])
        let items = try #require(plist["_PrelinkInfoDictionary"] as? [[String: Any]])
        return items.compactMap { $0["IOKitPersonalities"] as? [String: [String: Any]] }.flatMap(\.values)
    }

    @Test
    func `names the renderer in the paravirtual GPU personality only`() throws {
        let data = Self.prelinkInfo()
        let patcher = patcher(data)
        #expect(patcher.patchParavirtGLESRenderer())
        #expect(patcher.patches.count == 1)
        let record = try #require(patcher.patches.first)
        #expect(record.patchID == FirmwarePatchSetCatalog.paravirtGLESPatch)

        // The plist keeps its size and every byte outside the record.
        let patched = patcher.buffer.data
        #expect(patched.count == data.count)
        let region = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
        #expect(patched[..<region.lowerBound] == data[..<region.lowerBound])
        #expect(patched[region.upperBound...] == data[region.upperBound...])
        #expect(patched.suffix(64).allSatisfy { $0 == 0 })

        let gpu = try #require(personalities(patched).first)
        #expect(gpu["IOGLESBundleName"] as? String == "AppleMetalGLRenderer")
        #expect(gpu["IOClass"] as? String == "AppleParavirtGPU")
        #expect(gpu["MetalPluginName"] as? String == "AppleParavirtGPUMetalIOGPUFamily")
        #expect(gpu.count == 8)

        // The key lands after IOClass with the IOClass line's indentation.
        let text = String(decoding: patched, as: UTF8.self)
        #expect(text.contains("<string>AppleParavirtGPU</string>\n\t\t\t\t\t<key>IOGLESBundleName</key>\n\t\t\t\t\t<string>AppleMetalGLRenderer</string>\n"))

        // A second run finds the key and writes nothing.
        let second = self.patcher(patched)
        #expect(second.patchParavirtGLESRenderer())
        #expect(second.patches.isEmpty)
    }

    @Test
    func `blocked patch leaves the plist unchanged`() {
        let data = Self.prelinkInfo()
        let patcher = patcher(data, gate: VPhonePatchGate(declared: [FirmwarePatchSetCatalog.paravirtGLESPatch], enabled: []))
        #expect(patcher.patchParavirtGLESRenderer())
        #expect(patcher.patches.isEmpty)
        #expect(patcher.buffer.data == data)
    }

    @Test
    func `refuses a personality that is not the paravirtual accelerator`() {
        for data in [
            Self.prelinkInfo(gpuClass: "AGXAcceleratorG14X"),
            Self.prelinkInfo(category: "IOFramebuffer"),
            // A nested dict would leave the personality's bounds unknown.
            Self.prelinkInfo(extraKeys: "\t\t\t\t\t<key>IOPropertyMatch</key>\n\t\t\t\t\t<dict>\n\t\t\t\t\t</dict>\n"),
        ] {
            let patcher = patcher(data)
            #expect(!patcher.patchParavirtGLESRenderer())
            #expect(patcher.patches.isEmpty)
            #expect(patcher.buffer.data == data)
        }
    }

    @Test
    func `refuses when the indentation after the key cannot make room`() {
        // A compact plist has no indentation to give.
        let compact = Self.prelinkInfo().filter { $0 != UInt8(ascii: "\t") }
        let indented = Data(String(decoding: compact, as: UTF8.self)
            .replacingOccurrences(of: "<key>IOClass</key>", with: "\t\t<key>IOClass</key>").utf8)
        let patcher = patcher(indented)
        #expect(!patcher.patchParavirtGLESRenderer())
        #expect(patcher.patches.isEmpty)
    }

    @Test(.enabled(if: fixture != nil))
    func `patches the supplied kernel`() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.fixture)))
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.parseMachO()
        #expect(patcher.patchParavirtGLESRenderer())
        #expect(patcher.patches.count == 1)
        #expect(patcher.buffer.data.count == data.count)

        let second = KernelCustomFirmwarePatcher(data: patcher.patchedData, verbose: false)
        second.parseMachO()
        #expect(second.patchParavirtGLESRenderer())
        #expect(second.patches.isEmpty)
    }
}
