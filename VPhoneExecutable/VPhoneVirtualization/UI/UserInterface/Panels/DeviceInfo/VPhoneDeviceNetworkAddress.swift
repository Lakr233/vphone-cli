import Foundation

/// One address from icli `networkInfo()`, which reports each as the string
/// `"<interface> <numeric host>"`.
struct VPhoneDeviceNetworkAddress: Identifiable, Hashable {
    let interface: String
    let family: String
    let address: String

    var id: String {
        "\(interface) \(address)"
    }

    var line: String {
        "\(interface)\t\(family)\t\(address)"
    }

    init(interface: String, family: String, address: String) {
        self.interface = interface
        self.family = family
        self.address = address
    }

    /// Parses `"en0 192.168.64.3"` or `"en0 fe80::1%en0"`.
    init?(_ raw: String) {
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        interface = String(parts[0])
        address = parts[1].trimmingCharacters(in: .whitespaces)
        family = address.contains(":") ? "IPv6" : "IPv4"
    }
}
