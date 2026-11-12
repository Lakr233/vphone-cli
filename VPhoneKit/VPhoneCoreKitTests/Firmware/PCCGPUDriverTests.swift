import Foundation
import Testing
@testable import VPhoneCoreKit

struct PCCGPUDriverTests {
    static func archive(fields: [String: Data]) throws -> URL {
        var body = Data()
        for name in fields.keys.sorted() {
            let record = Data(name.utf8) + Data([0]) + fields[name]!
            withUnsafeBytes(of: UInt32(record.count + 4).littleEndian) { body.append(contentsOf: $0) }
            body.append(record)
        }
        var image = Data("AEA1".utf8)
        for word in [UInt32(1), UInt32(body.count)] {
            withUnsafeBytes(of: word.littleEndian) { image.append(contentsOf: $0) }
        }
        image.append(body)
        let file = FileManager.default.temporaryDirectory.appending(path: "pcc-key-\(UUID().uuidString).aea")
        try image.write(to: file)
        return file
    }

    @Test(arguments: [false, true])
    func `an embedded PCC key decodes to exactly 32 bytes`(uppercase: Bool) throws {
        let key = (0 ..< 32).map { String(format: "%02x", $0) }.joined()
        let file = try Self.archive(fields: ["encryption_key": Data((uppercase ? key.uppercased() : key).utf8)])
        defer { try? FileManager.default.removeItem(at: file) }
        let encoded = try #require(try VPhoneAEA.embeddedSymmetricKey(of: file))
        #expect(encoded == "base64:" + Data((0 ..< 32).map(UInt8.init)).base64EncodedString())
    }

    @Test(arguments: ["", String(repeating: "0", count: 63), String(repeating: "0", count: 65),
                      String(repeating: "z", count: 64), "+0" + String(repeating: "0", count: 62)])
    func `a malformed embedded key is refused`(key: String) throws {
        let file = try Self.archive(fields: ["encryption_key": Data(key.utf8)])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: VPhoneAEA.Error.self) {
            try VPhoneAEA.embeddedSymmetricKey(of: file)
        }
    }

    @Test func `an archive without an embedded key leaves recovery to the caller`() throws {
        let file = try Self.archive(fields: ["unrelated": Data([0])])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try VPhoneAEA.embeddedSymmetricKey(of: file) == nil)
        let destination = file.deletingPathExtension()
        #expect(try !VPhonePCCGPUDriver.stage(fromSystemImage: file, into: destination, expectedPlatformVersion: "18.6"))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// A bundle with the files `validateBundle` checks and `DTPlatformVersion` `version`.
    static func bundle(version: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "gpu-\(UUID().uuidString)/\(VPhonePCCGPUDriver.name)")
        try FileManager.default.createDirectory(at: url.appending(path: "_CodeSignature"), withIntermediateDirectories: true)
        try Data().write(to: url.appending(path: "AppleParavirtGPUMetalIOGPUFamily"))
        try Data().write(to: url.appending(path: "_CodeSignature/CodeResources"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily",
            "DTPlatformVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appending(path: "Info.plist"))
        return url
    }

    @Test func `a driver matches its cloud OS release, whatever the point release`() throws {
        let driver = try Self.bundle(version: "18.7")
        defer { try? FileManager.default.removeItem(at: driver.deletingLastPathComponent()) }
        try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "18.7.2")
        try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "18.7")
        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "18.6")
        }
        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "26.4")
        }
    }
}
