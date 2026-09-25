import Foundation

// MARK: - vm list / vm info

/// Mirrors `VPhoneBundleReport`, the JSON `vphone-cli vm list --json` and
/// `vm info --json` print.
nonisolated struct VPhoneLaunchpadMachine: Decodable, Hashable, Identifiable, Sendable {
    struct Network: Decodable, Hashable, Sendable {
        let mode: String
        let macAddress: String
        let bridgeInterface: String?
    }

    struct OSVersion: Decodable, Hashable, Sendable {
        let version: String
        let build: String
    }

    struct RestoreInfo: Decodable, Hashable, Sendable {
        let ios: OSVersion
        let cloudOS: OSVersion
        let variant: String?
        let device: String?
    }

    let name: String
    let cpuCount: Int
    let memoryMB: Int
    let diskSizeBytes: Int64
    let network: Network
    let restoreInfo: RestoreInfo?
    let udid: String?

    var id: String {
        name
    }

    var networkDescription: String {
        switch network.mode {
        case "nat": String(localized: "NAT")
        case "bridged": network.bridgeInterface.map { String(localized: "Bridged to \($0)") } ?? String(localized: "Bridged")
        case "hostOnly": String(localized: "Host only")
        default: String(localized: "None")
        }
    }
}

// MARK: - fw catalog

/// Mirrors `VPhoneFirmwareCatalogReport` from `vphone-cli fw catalog --json`.
nonisolated struct VPhoneLaunchpadFirmwareCatalog: Decodable, Sendable {
    struct Image: Decodable, Hashable, Sendable {
        let name: String
        let url: String
    }

    struct Pairing: Decodable, Hashable, Identifiable, Sendable {
        let ios: Image
        let recommendedCloudOS: Image

        var id: String {
            ios.url
        }

        /// The build from an IPSW name such as `iPhone17,3_27.0_24A435_Restore.ipsw`.
        var build: String {
            let fields = (ios.url as NSString).lastPathComponent.split(separator: "_")
            return fields.count >= 4 ? String(fields[2]) : ""
        }
    }

    let device: String
    let pairings: [Pairing]
}
