import Foundation

public struct VPhoneBundleReport: Codable, Equatable, Sendable {
    public let name: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeBytes: Int64
    public let network: VPhoneVirtualMachineManifest.NetworkConfig
    public let restoreInfo: VPhoneRestoreInfo?
    /// `false` when the last `cfw install` did not finish; `nil` when unknown.
    public let customFirmwareInstalled: Bool?
    public let udid: String?
    /// Whether vphone-vm unlocks the guest each time it starts. Always
    /// present, so a client can tell a bundle that knows the setting from one
    /// that does not.
    public let unlocksAtStartup: Bool
    /// The template the machine was cloned from (`TemplateSource.plist`),
    /// or nil.
    public let template: String?
    /// Whether `template` is the build the machine was cloned from, an
    /// earlier build since deleted, or deleted; nil when `template` is.
    /// Launchpad reads it rather than the template records, so the rule
    /// (``VPhoneMachineTemplateSource/isClone(of:)``) has one home. Added in
    /// 2.9.0.
    public let templateMatch: VPhoneMachineTemplateMatch?
    /// Whether vphone-vm forwards the Mac's location to the guest. Always
    /// present, like `unlocksAtStartup`.
    public let syncsHostLocation: Bool
    /// Whether vphone-vm holds the guest's CoreDevice tunnel open. Always
    /// present, like `unlocksAtStartup`.
    public let holdsDeveloperTunnel: Bool
    /// The boot ROM the machine starts from: `openavb` or `apple`. Nil when the
    /// manifest names none (the framework's built-in ROM) or it cannot be
    /// read. Added with OpenAVB.
    public let bootROM: String?
    /// The SEP ROM the machine starts its SEP from: `opensep` or `apple`, nil
    /// as for `bootROM`. Added with OpenSEP.
    public let sepROM: String?

    public init(bundle: VPhoneBundle) {
        name = bundle.name
        cpuCount = Int(bundle.manifest.cpuCount)
        memoryMB = Int(bundle.manifest.memorySize / (1024 * 1024))
        diskSizeBytes = bundle.diskSizeBytes
        // Report the effective setting so clients do not have to duplicate the
        // legacy fixed-address exception when the manifest has no explicit flag.
        let configuredNetwork = bundle.manifest.networkConfig
        network = configuredNetwork.mode == .nat
            ? configuredNetwork.with(reachesPeers: .some(VPhoneNetworking.reachesPeers(configuredNetwork)))
            : configuredNetwork
        restoreInfo = VPhoneRestoreInfo.load(fromBundle: bundle)
        customFirmwareInstalled = VPhoneRestoreInfo.customFirmwareInstalled(inBundle: bundle)
        udid = VPhoneRestoreOperations.resolveUDID(bundle: bundle)
        unlocksAtStartup = bundle.manifest.unlocksScreenAtStartup
        let source = VPhoneMachineTemplates.readSource(inBundle: bundle.url)
        template = source?.identifier
        // A machine lives directly in its library's root.
        let library = VPhoneLibrary(root: bundle.url.deletingLastPathComponent())
        templateMatch = source.map { VPhoneMachineTemplates.match(of: $0, in: library) }
        syncsHostLocation = bundle.manifest.sharesHostLocation
        holdsDeveloperTunnel = bundle.manifest.keepsDeveloperTunnelOpen
        bootROM = VPhoneBootROM.kind(ofMachineAt: bundle.url)?.rawValue
        sepROM = VPhoneSEPROM.kind(ofMachineAt: bundle.url)?.rawValue
    }
}
