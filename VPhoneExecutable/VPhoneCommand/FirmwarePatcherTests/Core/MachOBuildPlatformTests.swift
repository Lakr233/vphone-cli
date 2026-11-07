// MachOBuildPlatformTests.swift — the platform rewrite a tvOS or visionOS
// guest's GPU driver gets before it is installed.

import FirmwarePatcher
import Foundation
import Testing

@Suite("Mach-O build platform")
struct MachOBuildPlatformTests {
    /// A thin 64-bit header with the given load commands, each `(cmd, body)`.
    static func machO(_ commands: [(UInt32, [UInt32])]) -> Data {
        var body = Data()
        for (command, words) in commands {
            let size = UInt32(8 + 4 * words.count)
            for word in [command, size] + words {
                withUnsafeBytes(of: word.littleEndian) { body.append(contentsOf: $0) }
            }
        }
        var header = Data()
        // magic, cputype arm64, cpusubtype, MH_EXECUTE, ncmds, sizeofcmds, flags, reserved
        for word: UInt32 in [0xFEED_FACF, 0x0100_000C, 0, 2, UInt32(commands.count), UInt32(body.count), 0, 0] {
            withUnsafeBytes(of: word.littleEndian) { header.append(contentsOf: $0) }
        }
        return header + body
    }

    @Test(arguments: [MachOBuildPlatform.tvOS, MachOBuildPlatform.visionOS])
    func `the platform of every build version changes and nothing else does`(_ platform: UInt32) throws {
        #expect(MachOBuildPlatform.visionOS == 11)
        // LC_UUID-shaped filler, then two LC_BUILD_VERSIONs (platform, minos, sdk, ntools).
        let original = Self.machO([
            (0x1B, [1, 2, 3, 4]),
            (0x32, [MachOBuildPlatform.iOS, 0x000F_0000, 0x001B_0000, 0]),
            (0x32, [MachOBuildPlatform.iOS, 0x000F_0000, 0x001B_0000, 0]),
        ])
        #expect(try MachOBuildPlatform.read(original) == MachOBuildPlatform.iOS)
        var data = original
        try MachOBuildPlatform.set(platform, in: &data)
        #expect(try MachOBuildPlatform.read(data) == platform)
        let changed = zip(original, data).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        // Only the low byte of each platform word changes: 2 -> 3 or 11.
        #expect(changed == [32 + 24 + 8, 32 + 24 + 24 + 8])
    }

    @Test
    func `a file that is not a thin 64-bit Mach-O or has no build version is refused`() throws {
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE] + [UInt8](repeating: 0, count: 60))
        #expect(throws: MachOBuildPlatform.Error.notThin64BitMachO) {
            try MachOBuildPlatform.set(MachOBuildPlatform.tvOS, in: &fat)
        }
        var bare = Self.machO([(0x1B, [1, 2, 3, 4])])
        #expect(try MachOBuildPlatform.read(bare) == nil)
        #expect(throws: MachOBuildPlatform.Error.noBuildVersion) {
            try MachOBuildPlatform.set(MachOBuildPlatform.tvOS, in: &bare)
        }
    }

    @Test
    func `a load command running past the declared commands is not followed`() throws {
        var data = Self.machO([(0x32, [MachOBuildPlatform.iOS, 0, 0, 0])])
        // Claim a second command the header's sizeofcmds does not cover.
        data.replaceSubrange(16..<20, with: [2, 0, 0, 0])
        #expect(try MachOBuildPlatform.read(data) == MachOBuildPlatform.iOS)
        try MachOBuildPlatform.set(MachOBuildPlatform.tvOS, in: &data)
        #expect(try MachOBuildPlatform.read(data) == MachOBuildPlatform.tvOS)
    }
}
