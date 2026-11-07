// MachOBuildPlatform.swift — read and rewrite the platform a Mach-O names.
//
// dyld refuses to load a library into a process of another platform. An
// Apple TV guest's processes are tvOS, so an iOS-built library a TV guest
// loads, the paravirtual GPU driver, is marked tvOS before it is installed;
// on watch and Vision Pro guests, watchOS and visionOS respectively.
// The code signature no longer matches afterwards: the caller signs.

import Foundation

public enum MachOBuildPlatform {
    public static let iOS: UInt32 = 2
    public static let tvOS: UInt32 = 3
    public static let watchOS: UInt32 = 4
    public static let visionOS: UInt32 = 11

    public enum Error: Swift.Error, Equatable {
        case notThin64BitMachO
        case noBuildVersion
    }

    private static let magic64: UInt32 = 0xFEED_FACF
    private static let buildVersionCommand: UInt32 = 0x32 // LC_BUILD_VERSION

    /// The platform of the first `LC_BUILD_VERSION`, or nil when there is none.
    public static func read(_ data: Data) throws -> UInt32? {
        try buildVersionOffsets(data).first.map { u32(data, $0 + 8) }
    }

    /// Rewrite the platform of every `LC_BUILD_VERSION` in a thin 64-bit Mach-O.
    public static func set(_ platform: UInt32, in data: inout Data) throws {
        let offsets = try buildVersionOffsets(data)
        guard !offsets.isEmpty else { throw Error.noBuildVersion }
        for offset in offsets {
            let start = data.startIndex + offset + 8
            withUnsafeBytes(of: platform.littleEndian) { data.replaceSubrange(start..<start + 4, with: $0) }
        }
    }

    private static func buildVersionOffsets(_ data: Data) throws -> [Int] {
        guard data.count >= 32, u32(data, 0) == magic64 else { throw Error.notThin64BitMachO }
        let commands = Int(u32(data, 16))
        let end = min(data.count, 32 + Int(u32(data, 20)))
        var offsets: [Int] = []
        var offset = 32
        for _ in 0..<commands {
            guard offset + 8 <= end else { break }
            let size = Int(u32(data, offset + 4))
            guard size >= 8, offset + size <= end else { break }
            if u32(data, offset) == buildVersionCommand, size >= 12 {
                offsets.append(offset)
            }
            offset += size
        }
        return offsets
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
}
