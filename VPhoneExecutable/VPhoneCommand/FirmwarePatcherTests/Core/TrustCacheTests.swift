// TrustCacheTests.swift — trust cache payloads and the categories carried into cryptexctl's.
//
// The layouts were read off real caches: iOS 18.6 22G86's OS, System OS and
// App OS caches are version 2 (24-byte entries, category in the 23rd byte, as
// `ipsw fw tc` prints it), and what `cryptexctl generate-trust-cache` wrote
// for the merged volume is version 1 (22-byte entries), with every CDHash of
// its --base-trust-cache once as given and once more, flags 0xC0, for each
// binary its scan found.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Trust cache")
struct TrustCacheTests {
    @Test
    func `version 1 and 2 payloads read and write back unchanged`() throws {
        for version in [UInt32(1), 2] {
            let payload = Self.payload(version: version, entries: [
                (hash(0x10), 2, 0, 4),
                (hash(0x20), 1, 0xC0, 0),
            ])
            let cache = try TrustCache(payload: payload)
            #expect(cache.version == version)
            #expect(cache.uuid == Data(repeating: 0xAB, count: 16))
            #expect(cache.entries.map(\.cdHash) == [hash(0x10), hash(0x20)])
            #expect(cache.entries.map(\.flags) == [0, 0xC0])
            #expect(cache.entries.map(\.constraintCategory) == (version == 2 ? [4, 0] : [0, 0]))
            #expect(cache.payload == payload)
        }
    }

    @Test
    func `malformed payloads are rejected`() {
        var unknownVersion = Self.payload(version: 2, entries: [])
        unknownVersion[0] = 3
        let truncated = Self.payload(version: 2, entries: [(hash(0x10), 2, 0, 1)]).dropLast()
        for payload in [unknownVersion, Data(truncated), Data(count: 10)] {
            #expect(throws: (any Error).self) { try TrustCache(payload: payload) }
        }
    }

    @Test
    func `categories come from the originals and everything else is kept`() throws {
        let generated = try TrustCache(payload: Self.payload(version: 1, entries: [
            (hash(0x10), 2, 0, 0), // from --base-trust-cache
            (hash(0x10), 2, 0xC0, 0), // the same binary, found by the scan
            (hash(0x20), 2, 0xC0, 0), // in a cryptex's cache
            (hash(0x30), 2, 0xC0, 0), // re-signed by the merge
            (hash(0x40), 2, 0xC0, 0), // added by the merge
        ]))
        let os = try TrustCache(payload: Self.payload(version: 2, entries: [
            (hash(0x10), 2, 0, 2),
            (hash(0x31), 2, 0, 5),
        ]))
        let cryptex = try TrustCache(payload: Self.payload(version: 2, entries: [(hash(0x20), 2, 0, 14)]))

        let cache = generated.withConstraintCategories(
            from: [os, cryptex],
            inherited: [hash(0x30): [hash(0x31)], hash(0x40): [hash(0x41)]],
        )
        #expect(cache.version == 2)
        #expect(cache.uuid == generated.uuid)
        #expect(cache.entries.map(\.constraintCategory) == [2, 2, 14, 5, 0])
        #expect(cache.entries.map(\.cdHash) == generated.entries.map(\.cdHash))
        #expect(cache.entries.map(\.flags) == generated.entries.map(\.flags))
        #expect(cache.entries.map(\.hashType) == generated.entries.map(\.hashType))
        #expect(cache.payload.count == 24 + 5 * 24)
    }

    @Test
    func `a re-signed binary whose slices disagree gets no category`() throws {
        let generated = TrustCache(version: 1, uuid: Data(count: 16), entries: [
            .init(cdHash: hash(0x30), hashType: 2, flags: 0),
        ])
        let os = TrustCache(version: 2, uuid: Data(count: 16), entries: [
            .init(cdHash: hash(0x31), hashType: 2, flags: 0, constraintCategory: 1),
            .init(cdHash: hash(0x32), hashType: 2, flags: 0, constraintCategory: 2),
        ])
        let cache = generated.withConstraintCategories(from: [os], inherited: [hash(0x30): [hash(0x31), hash(0x32)]])
        #expect(cache.entries.map(\.constraintCategory) == [0])
    }

    /// The detached launchd.plist signature's cdhashes reach the static cache
    /// through a raw version 1 base trust cache. Read back, they take the
    /// category Apple's signature had (2 in 22G86's static trust cache), as
    /// `resignLaunchdCache` maps them.
    @Test
    func `a re-signed launchd.plist signature keeps the category of Apple's`() throws {
        let apple = try CustomFirmwareDetachedSignature.codeDirectoryHashes(
            in: CustomFirmwareDetachedSignature.sign(Data("Apple's launchd.plist".utf8), identifierStem: "launchd"),
        ).map(\.cdhash)
        let resigned = try CustomFirmwareDetachedSignature.codeDirectoryHashes(
            in: CustomFirmwareDetachedSignature.sign(Data("launchd.plist with vphoned".utf8), identifierStem: "launchd"),
        )
        let detached = try TrustCache(payload: CustomFirmwareDetachedSignature.trustCache(resigned))
        #expect(detached.version == 1)
        #expect(Set(detached.entries.map(\.cdHash)) == Set(resigned.map(\.cdhash)))

        let os = TrustCache(version: 2, uuid: Data(count: 16), entries: apple.map {
            .init(cdHash: $0, hashType: 2, flags: 0, constraintCategory: 2)
        })
        let inherited = Dictionary(uniqueKeysWithValues: resigned.map { ($0.cdhash, apple) })
        let cache = detached.withConstraintCategories(from: [os], inherited: inherited)
        #expect(cache.version == 2)
        #expect(cache.entries.map(\.constraintCategory) == [2, 2])
        #expect(detached.withConstraintCategories(from: [os]).entries.map(\.constraintCategory) == [0, 0])
    }

    /// Checked against codesign, which prints the CDHash of the slice it
    /// is asked for. /bin/ls is universal, so both slices are reached.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign")))
    func `CDHashes of a universal binary match codesign`() throws {
        let binary = URL(filePath: "/bin/ls")
        let hashes = TrustCache.cdHashes(ofMachO: try Data(contentsOf: binary))
        for architecture in ["arm64e", "x86_64"] {
            let output = try Self.run("/usr/bin/codesign", ["-d", "-vvv", "-a", architecture, binary.path])
            let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
            let expected = String(line.dropFirst("CDHash=".count))
            #expect(hashes.map(\.hex).contains(expected))
        }
        #expect(TrustCache.cdHashes(ofMachO: Data("not a Mach-O".utf8)).isEmpty)
    }

    // MARK: - Fixtures

    @Test
    func `trusted darwinOS allows every entry in both REM phases, each CDHash once`() throws {
        let cache = try TrustCache(payload: Self.payload(version: 2, entries: [
            (hash(0x10), 2, 0, 2), // from --base-trust-cache: Apple's, REM none
            (hash(0x10), 2, 0xC0, 2), // the same binary, found by the scan
            (hash(0x20), 2, 0, 0), // only in a base cache
            (hash(0x30), 1, 0x40, 0), // REM before only
            (hash(0x30), 2, 0xC0, 0), // the same CDHash, another hash type
        ]))
        let allowed = cache.allowingBothRestrictedExecutionPhases()
        #expect(allowed.entries.map(\.cdHash) == [hash(0x10), hash(0x20), hash(0x30), hash(0x30)])
        #expect(allowed.entries.map(\.hashType) == [2, 2, 1, 2])
        #expect(allowed.entries.allSatisfy { $0.flags == 0xC0 })
        #expect(allowed.entries.map(\.constraintCategory) == [2, 0, 0, 0])
        #expect(allowed.version == 2 && allowed.uuid == cache.uuid)
    }

    private func hash(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 20)
    }

    private static func payload(version: UInt32, entries: [(Data, UInt8, UInt8, UInt8)]) -> Data {
        var data = Data()
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0xAB, count: 16))
        withUnsafeBytes(of: UInt32(entries.count).littleEndian) { data.append(contentsOf: $0) }
        for (cdHash, hashType, flags, category) in entries {
            data.append(cdHash)
            data.append(contentsOf: [hashType, flags])
            if version == 2 { data.append(contentsOf: [category, 0]) }
        }
        return data
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
