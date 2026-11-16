import Foundation
import VPhoneCoreKit
import VPhonePatchKit

// MARK: - Create Options

public extension VPhoneVirtualMachineCreator {
    /// Whether the new machine is cloned from a template.
    enum TemplateUse: Equatable, Sendable {
        /// The full pipeline into the machine itself, with keys of its own.
        case none
        /// Clone from the template whose key the options resolve to,
        /// building it first when there is none.
        case automatic
        /// Clone from this template; no IPSW is needed.
        case identifier(String)
    }

    struct Options {
        public var name: String
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var gpuDriverBundle: URL?
        public var ipswCacheDirectory: URL
        /// The guest device to take from an IPSW that covers several models.
        public var device: String?
        /// For a device without an IPSW: its full OTA and the OTA's key. Nil
        /// takes the catalog's for the IPSW's build.
        public var otaSource: String?
        public var otaKey: String?
        /// Which patch preset the new VM is built with. Individual patches are
        /// turned on or off per VM afterwards, through its patch selection.
        public var patchPreset: String
        /// The preset when `--preset` named a file; kept in the machine.
        public var patchPresetFile: VPhonePatchPreset?
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        /// Set on the new machine after it exists; nil keeps the default.
        public var networkMode: VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode?
        public var unlocksAtStartup: Bool?
        public var verbosity: VPhoneVerbosity
        public var keepArtifacts: Bool
        public var template: TemplateUse
        /// The key fields named on the command line, checked against a
        /// template given by identifier. Nil fields were not given.
        public var templateRequest: VPhoneMachineTemplateRequest
        /// Leave the first boot to the caller (Launchpad boots the machine
        /// itself). This is the clone's boot; a template boots only for its
        /// setup boot, before it is frozen.
        public var skipsFirstBoot: Bool
        /// Install the Irisin bootstrap in this layout (`roothide` or `rootless`)
        /// during the first boot; nil leaves the guest without one.
        public var bootstrapLayout: String?
        /// What a template built for this create is slimmed of; part of the
        /// key it is looked up by.
        public var slimming: VPhoneMachineTemplateSlimming

        public init(
            name: String,
            iphoneSource: String? = nil,
            cloudosSource: String? = nil,
            gpuDriverBundle: URL? = nil,
            ipswCacheDirectory: URL = VPhoneResources.ipswCacheDirectory(),
            device: String? = nil,
            otaSource: String? = nil,
            otaKey: String? = nil,
            patchPreset: String = VPhonePatchPreset.standardIdentifier,
            patchPresetFile: VPhonePatchPreset? = nil,
            cpuCount: UInt = 8,
            memoryMB: UInt64 = 8192,
            diskSizeGB: UInt64 = 64,
            networkMode: VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode? = nil,
            unlocksAtStartup: Bool? = nil,
            verbosity: VPhoneVerbosity = .quiet,
            keepArtifacts: Bool = false,
            template: TemplateUse = .none,
            templateRequest: VPhoneMachineTemplateRequest = VPhoneMachineTemplateRequest(),
            skipsFirstBoot: Bool = false,
            bootstrapLayout: String? = nil,
            slimming: VPhoneMachineTemplateSlimming = VPhoneTemplateSlimmingRequest.defaultSlimming,
        ) {
            self.name = name
            self.iphoneSource = iphoneSource
            self.cloudosSource = cloudosSource
            self.gpuDriverBundle = gpuDriverBundle
            self.ipswCacheDirectory = ipswCacheDirectory
            self.device = device
            self.otaSource = otaSource
            self.otaKey = otaKey
            self.patchPreset = patchPreset
            self.patchPresetFile = patchPresetFile
            self.cpuCount = cpuCount
            self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB
            self.networkMode = networkMode
            self.unlocksAtStartup = unlocksAtStartup
            self.verbosity = verbosity
            self.keepArtifacts = keepArtifacts
            self.template = template
            self.templateRequest = templateRequest
            self.skipsFirstBoot = skipsFirstBoot
            self.bootstrapLayout = bootstrapLayout
            self.slimming = slimming
        }
    }
}
