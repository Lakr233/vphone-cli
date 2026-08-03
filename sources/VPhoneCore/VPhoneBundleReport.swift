import Foundation

public struct VPhoneBundleReport: Codable, Equatable, Sendable {
    public let name: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeBytes: Int64
    public let network: VPhoneVirtualMachineManifest.NetworkConfig
    public let restoreInfo: VPhoneRestoreInfo?
    public let udid: String?

    public init(bundle: VPhoneBundle) {
        self.name = bundle.name
        self.cpuCount = Int(bundle.manifest.cpuCount)
        self.memoryMB = Int(bundle.manifest.memorySize / (1024 * 1024))
        self.diskSizeBytes = bundle.diskSizeBytes
        self.network = bundle.manifest.networkConfig
        self.restoreInfo = VPhoneRestoreInfo.load(fromBundle: bundle)
        self.udid = VPhoneRestoreOps.resolveUDID(bundle: bundle)
    }
}
