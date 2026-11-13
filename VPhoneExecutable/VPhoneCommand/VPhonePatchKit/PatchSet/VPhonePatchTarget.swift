// VPhonePatchTarget.swift — What a declared patch writes to.
//
// The target is the one piece of a declaration the loader can check before any
// patch runs: a patch set that claims a component this PatchKit does not know
// fails to decode instead of being skipped silently at patch time.

import Foundation

/// A boot-chain component, spelled the way ``FirmwarePipeline`` names it.
public enum VPhoneFirmwareComponent: String, Sendable, Hashable, Codable, CaseIterable {
    case avpBooter = "AVPBooter"
    case iBSS
    case iBEC
    case llb = "LLB"
    case txm = "TXM"
    case sptm = "SPTM"
    case restoreRamDisk = "RestoreRamDisk"
    case restoreTrustCache = "RestoreTrustCache"
    case kernelcache
    case deviceTree = "DeviceTree"
    case sep = "SEP"
    case filesystem = "Filesystem"
    case manifest = "Manifest"
}

/// Where a patch writes. Boot-chain patches run inside `fw patch`; the guest
/// cases run inside `cfw install`, after the system volume is mounted.
public enum VPhonePatchTarget: Sendable, Hashable {
    /// A signed boot-chain component, patched before the IM4P is resealed.
    case firmware(VPhoneFirmwareComponent)
    /// The guest dyld shared cache, re-attested chunk by chunk afterwards.
    case dyldSharedCache
    /// A Mach-O in the mounted system volume, at that absolute guest path.
    case guestExecutable(path: String)
    /// The entitlements blob of a Mach-O in the mounted system volume.
    case guestEntitlements(path: String)
    /// A non-executable file written into the mounted system volume.
    case guestFile(path: String)
    /// The post-restore device tree in the guest's Preboot volume.
    case prebootDeviceTree
}

// MARK: - Plist Coding

extension VPhonePatchTarget: Codable {
    private enum Kind: String, Codable {
        case firmware = "Firmware"
        case dyldSharedCache = "DyldSharedCache"
        case guestExecutable = "GuestExecutable"
        case guestEntitlements = "GuestEntitlements"
        case guestFile = "GuestFile"
        case prebootDeviceTree = "PrebootDeviceTree"
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "Kind"
        case component = "Component"
        case path = "Path"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .firmware:
            self = try .firmware(container.decode(VPhoneFirmwareComponent.self, forKey: .component))
        case .dyldSharedCache:
            self = .dyldSharedCache
        case .prebootDeviceTree:
            self = .prebootDeviceTree
        case .guestExecutable, .guestEntitlements, .guestFile:
            let path = try container.decode(String.self, forKey: .path)
            guard path.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "A guest path is absolute inside the guest volume, got \(path)",
                )
            }
            switch kind {
            case .guestExecutable: self = .guestExecutable(path: path)
            case .guestEntitlements: self = .guestEntitlements(path: path)
            default: self = .guestFile(path: path)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .firmware(component):
            try container.encode(Kind.firmware, forKey: .kind)
            try container.encode(component, forKey: .component)
        case .dyldSharedCache:
            try container.encode(Kind.dyldSharedCache, forKey: .kind)
        case .prebootDeviceTree:
            try container.encode(Kind.prebootDeviceTree, forKey: .kind)
        case let .guestExecutable(path):
            try container.encode(Kind.guestExecutable, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .guestEntitlements(path):
            try container.encode(Kind.guestEntitlements, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .guestFile(path):
            try container.encode(Kind.guestFile, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

// MARK: - Description

extension VPhonePatchTarget: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .firmware(component): component.rawValue
        case .dyldSharedCache: "dyld shared cache"
        case .prebootDeviceTree: "preboot device tree"
        case let .guestExecutable(path): path
        case let .guestEntitlements(path): "\(path) (entitlements)"
        case let .guestFile(path): "\(path) (file)"
        }
    }

    /// Whether the patch runs in `fw patch` rather than `cfw install`.
    public var isBootChain: Bool {
        switch self {
        case .firmware: true
        case .dyldSharedCache, .prebootDeviceTree, .guestExecutable, .guestEntitlements, .guestFile: false
        }
    }
}
