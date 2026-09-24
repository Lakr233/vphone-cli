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
        name = bundle.name
        cpuCount = Int(bundle.manifest.cpuCount)
        memoryMB = Int(bundle.manifest.memorySize / (1024 * 1024))
        diskSizeBytes = bundle.diskSizeBytes
        network = bundle.manifest.networkConfig
        restoreInfo = VPhoneRestoreInfo.load(fromBundle: bundle)
        udid = VPhoneRestoreOps.resolveUDID(bundle: bundle)
    }
}
