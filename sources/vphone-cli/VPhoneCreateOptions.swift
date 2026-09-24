import Foundation
import VPhoneCore

// MARK: - Create Options

public extension VPhoneCreateOrchestrator {
    struct Options {
        public var name: String
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var gpuDriverBundle: URL?
        public var sudoPassword: String?
        public var forceDSCMaxSlide: Bool
        public var enableFrida: Bool
        public var rootPopup: Bool
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
            sudoPassword: String? = nil,
            forceDSCMaxSlide: Bool = false,
            enableFrida: Bool = false,
            rootPopup: Bool = false,
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
            self.sudoPassword = sudoPassword
            self.forceDSCMaxSlide = forceDSCMaxSlide
            self.enableFrida = enableFrida
            self.rootPopup = rootPopup
            self.cpuCount = cpuCount
            self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB
            self.verbosity = verbosity
            self.keepArtifacts = keepArtifacts
        }
    }
}
