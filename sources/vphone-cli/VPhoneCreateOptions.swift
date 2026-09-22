import VPhoneCore

// MARK: - Create Options

extension VPhoneCreateOrchestrator {
    public struct Options {
        public var name: String
        public var variant: String
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var sudoPassword: String?
        public var spoofBuild: String?
        public var forceDSCMaxSlide: Bool
        public var enableFrida: Bool
        public var rootPopup: Bool
        public var interactive: Bool
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        public var verbosity: VPhoneVerbosity
        public var keepArtifacts: Bool

        public init(
            name: String,
            variant: String,
            iphoneSource: String? = nil,
            cloudosSource: String? = nil,
            sudoPassword: String? = nil,
            spoofBuild: String? = nil,
            forceDSCMaxSlide: Bool = false,
            enableFrida: Bool = false,
            rootPopup: Bool = false,
            interactive: Bool = false,
            cpuCount: UInt = 8,
            memoryMB: UInt64 = 8192,
            diskSizeGB: UInt64 = 64,
            verbosity: VPhoneVerbosity = .quiet,
            keepArtifacts: Bool = false
        ) {
            self.name = name
            self.variant = variant
            self.iphoneSource = iphoneSource
            self.cloudosSource = cloudosSource
            self.sudoPassword = sudoPassword
            self.spoofBuild = spoofBuild
            self.forceDSCMaxSlide = forceDSCMaxSlide
            self.enableFrida = enableFrida
            self.rootPopup = rootPopup
            self.interactive = interactive
            self.cpuCount = cpuCount
            self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB
            self.verbosity = verbosity
            self.keepArtifacts = keepArtifacts
        }
    }
}
