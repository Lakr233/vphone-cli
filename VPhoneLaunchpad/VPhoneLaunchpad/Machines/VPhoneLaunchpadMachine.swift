import Foundation

// MARK: - Machine path

/// A machine's library root and name. Machines in two libraries may share a
/// name, so the pair, not the name, identifies a machine.
nonisolated struct VPhoneLaunchpadMachinePath: Hashable, Sendable {
    /// A canonical root, as `VPhoneLaunchpadMachineLocations.canonical` makes it.
    let libraryRoot: String
    let name: String

    var url: URL {
        URL(fileURLWithPath: libraryRoot, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    var libraryArguments: [String] {
        ["--library-root", libraryRoot]
    }
}

// MARK: - vm list / vm info

/// Mirrors `VPhoneBundleReport`, the JSON `vphone-cli vm list --json` and
/// `vm info --json` print.
nonisolated struct VPhoneLaunchpadMachine: Decodable, Hashable, Identifiable, Sendable {
    struct Network: Decodable, Hashable, Sendable {
        struct IPv4: Decodable, Hashable, Sendable {
            let address: String
            let prefixLength: Int
            let router: String?
            let dns: [String]?
        }

        struct PortForward: Decodable, Hashable, Sendable {
            let transport: String
            let hostAddress: String?
            let hostPort: Int
            let guestPort: Int

            private enum CodingKeys: String, CodingKey {
                case transport = "protocol"
                case hostAddress, hostPort, guestPort
            }

            /// The spelling `vm config --forward` takes.
            var argument: String {
                "\(transport):\(hostAddress ?? "127.0.0.1"):\(hostPort):\(guestPort)"
            }
        }

        let mode: String
        let macAddress: String
        let bridgeInterface: String?
        /// Nil from a bundle older than fixed addresses, and when DHCP decides.
        let ipv4: IPv4?
        let portForwards: [PortForward]?
        /// The guest's mDNS name without `.local`; nil when not managed.
        let localHostName: String?
        /// False when the guest is not given this Mac's name locally.
        let resolvesMacName: Bool?
        /// False when a nat guest is kept from the other nat machines.
        let reachesPeers: Bool?
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
    /// `false` when the last CFW install did not finish, `nil` when unknown.
    let customFirmwareInstalled: Bool?
    let udid: String?
    /// Whether vphone-vm unlocks the guest each time it starts. Nil from a
    /// bundle older than the setting.
    let unlocksAtStartup: Bool?
    /// Whether vphone-vm forwards the Mac's location to the guest. Nil from a
    /// bundle older than the setting.
    let syncsHostLocation: Bool?
    /// The template the machine was cloned from, or nil.
    let template: String?
    /// How `template` stands to the template with that identifier now:
    /// `current`, `earlierBuild` or `deleted`. `vphone-cli` decides it
    /// (`VPhoneMachineTemplateSource.isClone(of:)`), so Launchpad never reads
    /// the template records itself. A String, so a value this Launchpad
    /// does not know leaves the row out rather than failing the list.
    let templateMatch: String?
    /// The library `vm list` was run on. Not part of the JSON.
    var libraryRoot = ""
    /// The guest's product type, such as iPad16,1, read by the library from
    /// the machine folder. Not part of the JSON: `restoreInfo.device` is the
    /// restore identity's model, the same for every guest.
    var guestProductType: String?

    private enum CodingKeys: String, CodingKey {
        case name, cpuCount, memoryMB, diskSizeBytes, network, restoreInfo, customFirmwareInstalled, udid, unlocksAtStartup,
             syncsHostLocation, template, templateMatch
    }

    /// Read from disk at launch time rather than from the last `vm list`, so a
    /// machine that was just installed is not refused on stale data. Mirrors
    /// `vm launch`: restore-info.json with no variant is an unfinished install.
    static func customFirmwareIncomplete(at path: VPhoneLaunchpadMachinePath) -> Bool {
        let file = path.url.appendingPathComponent("restore-info.json")
        guard let data = try? Data(contentsOf: file),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return info["variant"] == nil
    }

    /// The inspector's Template row: nil for a machine not cloned from a
    /// template, or when the bundle did not say how it matches.
    var templateOrigin: VPhoneLaunchpadTemplateOrigin? {
        guard let template, let match = templateMatch.flatMap(VPhoneLaunchpadTemplateOrigin.Match.init(rawValue:)) else {
            return nil
        }
        return VPhoneLaunchpadTemplateOrigin(identifier: template, match: match)
    }

    var path: VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: libraryRoot, name: name)
    }

    var id: VPhoneLaunchpadMachinePath {
        path
    }

    /// The table's iOS sort key; a machine not yet restored sorts first.
    var iosVersion: String {
        restoreInfo?.ios.version ?? ""
    }

    /// True for an iPad guest.
    var isPad: Bool {
        guestProductType?.hasPrefix("iPad") == true
    }

    /// True for an Apple TV guest.
    var isAppleTV: Bool {
        guestProductType?.hasPrefix("AppleTV") == true
    }

    var isHomeView: Bool {
        guestProductType?.hasPrefix("HomeAccessory") == true
    }

    var isHomePod: Bool {
        guestProductType?.hasPrefix("AudioAccessory") == true
    }

    var isWatch: Bool {
        guestProductType?.hasPrefix("Watch") == true
    }

    /// The guest OS name, including accessory and watch guests.
    var osName: String {
        isHomeView ? "HomeView Software" : isHomePod ? "HomePod Software" : isWatch ? "watchOS" : isAppleTV ? "tvOS" : isPad ? "iPadOS" : "iOS"
    }

    /// config.plist's `guestProductType`, else the product type in the name
    /// of the restore tree `fw prepare` keeps in `FirmwareOriginals`
    /// (`iPhone17,3_…_Restore`, or `iPhoneOS_iPad16,1_…_Restore` for an iPad
    /// and `iPhoneOS_AppleTV5,3_…_Restore` for an Apple TV, `iPhoneOS_Watch7,18_…`
    /// for an Apple Watch),
    /// for configs written before the key.
    static func guestProductType(in folder: URL) -> String? {
        let config = NSDictionary(contentsOf: folder.appendingPathComponent("config.plist"))
        if let type = config?["guestProductType"] as? String {
            return type
        }
        let originals = folder.appendingPathComponent("FirmwareOriginals", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? []
        for name in names.sorted() where name.hasSuffix("_Restore") {
            if let type = name.split(separator: "_").first(where: { $0.wholeMatch(of: /(iPhone|iPad|AppleTV|AudioAccessory|HomeAccessory|Watch)\d+,\d+/) != nil }) {
                return String(type)
            }
        }
        return nil
    }

    var networkDescription: String {
        switch network.mode {
        case "nat": String(localized: "NAT")
        case "bridged": network.bridgeInterface.map { String(localized: "Bridged to \($0)") } ?? String(localized: "Bridged")
        case "tunnel": String(localized: "Tunnel")
        case "hostOnly": String(localized: "Host only")
        default: String(localized: "None")
        }
    }

    /// The fixed address, or nil when DHCP decides.
    var addressDescription: String? {
        network.ipv4.map { "\($0.address)/\($0.prefixLength)" }
    }
}

/// The template a machine was cloned from, as `vm list --json` reports it
/// (`template` and `templateMatch`).
///
/// The identifier names a key, and a template deleted and built again gets
/// the same one, but a clone of the earlier build shares no block and no key
/// with the new template. Which of the two a machine came from is
/// `vphone-cli`'s call (`VPhoneMachineTemplateSource.isClone(of:)`), made
/// from `TemplateSource.plist` and `Template.plist`, which Launchpad does not
/// read.
nonisolated struct VPhoneLaunchpadTemplateOrigin: Hashable, Sendable {
    /// `VPhoneMachineTemplateMatch`.
    enum Match: String, Hashable, Sendable {
        /// Cloned from the template that has the identifier now.
        case current
        /// Cloned from an earlier build with the same key, since deleted.
        case earlierBuild
        /// No template has the identifier now.
        case deleted
    }

    let identifier: String
    let match: Match
}

// MARK: - fw catalog

/// Mirrors `VPhoneFirmwareCatalogReport` from `vphone-cli fw catalog --json`.
nonisolated struct VPhoneLaunchpadFirmwareCatalog: Decodable, Sendable {
    struct Image: Decodable, Hashable, Sendable {
        let name: String
        let url: String
        /// The build, from a bundle that knows `url`'s name does not carry it.
        var build: String?
        /// The files the firmware needs in the IPSW cache, relative to it, from
        /// a bundle that lists them: an OTA and the IPSW it is restored over.
        var files: [String]?
    }

    struct Pairing: Decodable, Hashable, Identifiable, Sendable {
        let ios: Image
        let recommendedCloudOS: Image
        /// The release's own cloudOS, on the research board, from a bundle that
        /// links its kernelcache mix (`fw kernelcache`).
        var matchingCloudOS: Image?

        var id: String {
            ios.url
        }

        /// The build the bundle gives, else the one from an IPSW name such as
        /// `iPhone17,3_27.0_24A435_Restore.ipsw` or
        /// `iPad_Pro_M4_27.0.1_24A446_Restore.ipsw`: the field before `Restore`.
        var build: String {
            if let build = ios.build {
                return build
            }
            let fields = (ios.url as NSString).lastPathComponent.split(separator: "_")
            return fields.count >= 4 ? String(fields[fields.count - 2]) : ""
        }

        var isBeta: Bool {
            ios.name.localizedCaseInsensitiveContains("beta")
        }
    }

    /// One guest device and its pairings, oldest first.
    struct Device: Decodable, Hashable, Identifiable, Sendable {
        /// The product type `fw prepare --device` takes.
        let productType: String
        let name: String
        /// The guest family identifier, including homePod and watch.
        let family: String
        let pairings: [Pairing]
        /// `kernel-first` for a device whose kernelcache mix only the kmutil
        /// of macOS 15 or 26.0 to 26.3 links, from a bundle that has one.
        var kernelcacheLayout: String?

        var id: String {
            productType
        }

        /// The iOS 18 research board guest: every pairing rebuilds a
        /// kernel-first kernelcache, which from macOS 26.4 on another Mac links
        /// over ssh (`VPhoneLaunchpadKernelcacheBuilder`).
        var linksKernelFirst: Bool {
            kernelcacheLayout == "kernel-first"
        }

        var isPad: Bool {
            family == "iPad"
        }

        var isAppleTV: Bool {
            family == "appleTV"
        }

        var isWatch: Bool {
            family == "watch"
        }

        var isHomeView: Bool {
            family == "homeView"
        }

        var isHomePod: Bool {
            family == "homePod"
        }

        /// HomePod, HomeView and Apple TV do not use iOS templates or slimming.
        var requiresStandaloneRestore: Bool {
            isAppleTV || isHomePod || isHomeView
        }

        /// The system its IPSWs install.
        var osName: String {
            isHomeView ? "HomeView Software" : isHomePod ? "HomePod Software" : isWatch ? "watchOS" : isAppleTV ? "tvOS" : isPad ? "iPadOS" : "iOS"
        }

        /// The name with its product type, `iPhone 16 (iPhone17,3)`: Launchpad
        /// showed only the product type before, which reads as iPhone 17.
        var detailedName: String {
            name == productType ? name : "\(name) (\(productType))"
        }

        /// The newest release, or the newest build when every one is a beta.
        var defaultPairing: Pairing? {
            pairings.last { !$0.isBeta } ?? pairings.last
        }
    }

    /// The iPhone the `pairings` list is for.
    let device: String
    let pairings: [Pairing]
    /// Every guest device, from a bundle with iPad guests; nil before.
    let devices: [Device]?

    /// The guest devices, or the iPhone alone from a bundle without `devices`.
    var guests: [Device] {
        devices ?? [Device(productType: device, name: device, family: "iPhone", pairings: pairings)]
    }
}
