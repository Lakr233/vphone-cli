import Foundation
@testable import FirmwarePatcher
import Testing

#if os(Linux)
@Suite("Dyld cache mapping lifetime")
struct DyldSharedCacheMappingLifetimeTests {
    private func mappings(of path: String) throws -> Int {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/proc/self/maps"))
        defer { try? handle.close() }
        let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").filter { $0.hasSuffix(path) }.count
    }

    @Test func imageScopeReleasesMappingsAfterSuccessAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        var original = Data(repeating: 0, count: 0x8000)
        original.replaceSubrange(0 ..< 16, with: Data("dyld_v1  arm64e\0\0".utf8))
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { original.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(UInt32(0x100), at: 16)
        put(UInt32(1), at: 20)
        put(UInt64(0x180000000), at: 0x100)
        put(UInt64(0x4000), at: 0x108)
        put(UInt64(0x4000), at: 0x110)
        put(UInt32(5), at: 0x118)
        put(UInt32(5), at: 0x11c)
        original[0x4000] = 0x5a
        try original.write(to: file)
        let chunks = try DyldSharedCacheChunkSet(directory: directory, mappedReads: true)
        let result = try chunks.withScopedMappedReads {
            let bytes = try chunks.bytesAtVMA(0x180000000, length: 4)
            #expect(try mappings(of: file.path) > 0)
            return bytes[0]
        }
        #expect(result == 0x5a)
        #expect(try mappings(of: file.path) == 0)

        enum PlanningFailure: Error { case expected }
        #expect(throws: PlanningFailure.self) {
            try chunks.withScopedMappedReads {
                _ = try chunks.bytesAtVMA(0x180000000, length: 4)
                #expect(try mappings(of: file.path) > 0)
                throw PlanningFailure.expected
            }
        }
        #expect(try mappings(of: file.path) == 0)
        #expect(chunks.recordedWrites.isEmpty)
        #expect(try Data(contentsOf: file) == original)
    }
}
#endif
