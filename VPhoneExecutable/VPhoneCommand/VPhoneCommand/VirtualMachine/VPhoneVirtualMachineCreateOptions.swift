import Foundation
import VPhoneCoreKit

// MARK: - Create Options

public extension VPhoneVirtualMachineCreator {
    struct Options {
        public var name: String
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var gpuDriverBundle: URL?
        public var forceDyldSharedCacheMaxSlide: Bool
        public var enableFrida: Bool
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        public var verbosity: VPhoneVerbosity
        public var keepArtifacts: Bool

        public init(
            name: String,
            iphoneSource: String? = nil,
            cloudosSource: String? = nil,
            gpuDriverBundle: URL? = nil,
            forceDyldSharedCacheMaxSlide: Bool = false,
            enableFrida: Bool = false,
            cpuCount: UInt = 8,
            memoryMB: UInt64 = 8192,
            diskSizeGB: UInt64 = 64,
            verbosity: VPhoneVerbosity = .quiet,
            keepArtifacts: Bool = false,
        ) {
            self.name = name
            self.iphoneSource = iphoneSource
            self.cloudosSource = cloudosSource
            self.gpuDriverBundle = gpuDriverBundle
            self.forceDyldSharedCacheMaxSlide = forceDyldSharedCacheMaxSlide
            self.enableFrida = enableFrida
            self.cpuCount = cpuCount
            self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB
            self.verbosity = verbosity
            self.keepArtifacts = keepArtifacts
        }
    }
}
