import Foundation

// MARK: - Guest Device

/// The Apple device whose restore IPSW supplies the guest's OS image.
///
/// The boot chain, kernel, SEP and device tree always come from the PCC
/// `vresearch101ap` / `vphone600ap` identities. Only the userland changes with
/// the device: an iPhone17,3 IPSW gives the guest iOS, an iPad IPSW gives it
/// iPadOS. The device tree then has to present the matching idiom, artwork
/// and product type, or the iPadOS userland lays itself out as a phone.
///
/// The identity and `/product` values come from the device's own
/// `DeviceTree.<deviceClass>.im4p`, which the IPSW carries and `fw prepare`
/// keeps in the restore tree. What a device tree does not say — the panel's
/// size and density — is recorded here.
public struct VPhoneGuestDevice: Sendable, Equatable {
    public enum Family: String, Codable, Sendable {
        case iPhone
        case iPad
        case appleTV
        case homePod
        case homeView
        case watch

        public var osName: String {
            switch self {
            case .iPhone: "iOS"
            case .iPad: "iPadOS"
            case .appleTV: "tvOS"
            case .homePod: "HomePod Software"
            case .homeView: "HomeView Software"
            case .watch: "watchOS"
            }
        }

        /// Apple TV, HomePod and HomeView share the tvOS executable platform and
        /// filesystem layout. Their user interfaces and device idioms differ.
        public var usesTVOS: Bool {
            self == .appleTV || self == .homePod || self == .homeView
        }
    }

    public let family: Family
    /// `Ap,ProductType`, e.g. `iPad16,1`.
    public let productType: String
    /// BuildManifest `DeviceClass`, and the board in `DeviceTree.<board>.im4p`.
    public let deviceClass: String
    /// The marketing name, for logs and prompts.
    public let productName: String
    /// The guest display: a device panel, or a provisional virtual canvas.
    public let screen: VPhoneVirtualMachineManifest.ScreenConfig

    public init(
        family: Family,
        productType: String,
        deviceClass: String,
        productName: String,
        screen: VPhoneVirtualMachineManifest.ScreenConfig,
    ) {
        self.family = family
        self.productType = productType
        self.deviceClass = deviceClass
        self.productName = productName
        self.screen = screen
    }

    public var isPad: Bool {
        family == .iPad
    }

    public var usesTVOS: Bool {
        family.usesTVOS
    }

    /// Whether the guest boots a device tree of its own that presents this
    /// board, built by `fw patch` from the board's tree in the IPSW. Every
    /// device but the iPhone XS Max does; it keeps the fixed D47 identity
    /// `cfw install` writes into the restored tree.
    public var presentsBoard: Bool {
        notchedArtworkSubtype == nil
    }

    /// The artwork subtype of a guest presented as the iPhone17,3 whose own
    /// userland has none of the iPhone 16's: the XS family's asset catalogs
    /// only carry 2436 and 2688 artwork, and its SpringBoard no Dynamic Island
    /// layout. Without it Hello and the wallpaper stay empty and the home
    /// gesture breaks. Nil for every other device.
    public var notchedArtworkSubtype: Int? {
        productType == "iPhone11,6" ? 2688 : nil
    }

    // MARK: - Known Devices

    /// iPhone 16 (D47AP), the device every catalog IPSW targets.
    public static let iPhone17_3 = VPhoneGuestDevice(
        family: .iPhone,
        productType: "iPhone17,3",
        deviceClass: "d47ap",
        productName: "iPhone 16",
        screen: .default,
    )

    private static func iPhone(
        _ productType: String,
        _ deviceClass: String,
        _ productName: String,
        width: Int,
        height: Int,
    ) -> VPhoneGuestDevice {
        VPhoneGuestDevice(
            family: .iPhone,
            productType: productType,
            deviceClass: deviceClass,
            productName: productName,
            screen: .init(width: width, height: height, pixelsPerInch: 460, scale: 3.0),
        )
    }

    /// iPhone 16 Pro: 1206x2622, 402x874 points.
    public static let iPhone17_1 = iPhone("iPhone17,1", "d93ap", "iPhone 16 Pro", width: 1206, height: 2622)
    /// iPhone 16 Pro Max: 1320x2868, 440x956 points.
    public static let iPhone17_2 = iPhone("iPhone17,2", "d94ap", "iPhone 16 Pro Max", width: 1320, height: 2868)
    /// iPhone 16 Plus: 1290x2796, 430x932 points.
    public static let iPhone17_4 = iPhone("iPhone17,4", "d48ap", "iPhone 16 Plus", width: 1290, height: 2796)
    /// iPhone 16e: 1170x2532, 390x844 points.
    public static let iPhone17_5 = iPhone("iPhone17,5", "v59ap", "iPhone 16e", width: 1170, height: 2532)
    /// iPhone 17 Pro: 1206x2622, 402x874 points.
    public static let iPhone18_1 = iPhone("iPhone18,1", "v53ap", "iPhone 17 Pro", width: 1206, height: 2622)
    /// iPhone 17 Pro Max: 1320x2868, 440x956 points.
    public static let iPhone18_2 = iPhone("iPhone18,2", "v54ap", "iPhone 17 Pro Max", width: 1320, height: 2868)
    /// iPhone 17: 1206x2622, 402x874 points.
    public static let iPhone18_3 = iPhone("iPhone18,3", "v57ap", "iPhone 17", width: 1206, height: 2622)
    /// iPhone Air: 1260x2736, 420x912 points.
    public static let iPhone18_4 = iPhone("iPhone18,4", "d23ap", "iPhone Air", width: 1260, height: 2736)
    /// iPhone 17e: 1170x2532, 390x844 points.
    public static let iPhone18_5 = iPhone("iPhone18,5", "v159ap", "iPhone 17e", width: 1170, height: 2532)
    /// iPhone 18 Pro (V63AP): 1206x2622, 402x874 points.
    public static let iPhone19_2 = iPhone("iPhone19,2", "v63ap", "iPhone 18 Pro", width: 1206, height: 2622)

    /// iPhone Duo (V68AP). The VM's panel is its outer display (the cover); the
    /// guest publishes the inner display as a second, virtual display and shows
    /// it on that panel while the device is open (libvphonefolddisplay).
    public static let iPhone19_4 = iPhone("iPhone19,4", "v68ap", "iPhone Duo", width: 1398, height: 2034)

    /// iPhone XS Max: 1242x2688 at 458 ppi, 414x896 points. Its IPSW carries the
    /// iOS 18 releases after 18.6, which the iPhone 16 never got; the research
    /// board's own iOS 18 kernel boots it (the 18.x kernelcache recipes, `minimal`
    /// only). It is presented as the iPhone17,3 with its own artwork
    /// (`notchedArtworkSubtype`).
    public static let iPhone11_6 = VPhoneGuestDevice(
        family: .iPhone,
        productType: "iPhone11,6",
        deviceClass: "d331pap",
        productName: "iPhone XS Max",
        screen: .init(width: 1242, height: 2688, pixelsPerInch: 458, scale: 3.0),
    )

    private static func iPad(
        _ productType: String,
        _ deviceClass: String,
        _ productName: String,
        width: Int,
        height: Int,
        pixelsPerInch: Int = 264,
    ) -> VPhoneGuestDevice {
        VPhoneGuestDevice(
            family: .iPad,
            productType: productType,
            deviceClass: deviceClass,
            productName: productName,
            screen: .init(width: width, height: height, pixelsPerInch: pixelsPerInch, scale: 2.0),
        )
    }

    /// iPad mini (A17 Pro): 8.3-inch, 1488x2266 at 326 ppi, 744x1133 points.
    public static let iPad16_1 = iPad("iPad16,1", "j410ap", "iPad mini (A17 Pro)", width: 1488, height: 2266, pixelsPerInch: 326)
    /// iPad (A16): 11-inch, 1640x2360, 820x1180 points.
    public static let iPad15_7 = iPad("iPad15,7", "j481ap", "iPad (A16)", width: 1640, height: 2360)
    /// iPad Air 11-inch (M3): 1640x2360, 820x1180 points.
    public static let iPad15_3 = iPad("iPad15,3", "j607ap", "iPad Air 11-inch (M3)", width: 1640, height: 2360)
    /// iPad Air 13-inch (M3): 2048x2732, 1024x1366 points.
    public static let iPad15_5 = iPad("iPad15,5", "j637ap", "iPad Air 13-inch (M3)", width: 2048, height: 2732)
    /// iPad Pro 11-inch (M4): 1668x2420, 834x1210 points.
    public static let iPad16_3 = iPad("iPad16,3", "j717ap", "iPad Pro 11-inch (M4)", width: 1668, height: 2420)
    /// iPad Pro 13-inch (M4): 2064x2752, 1032x1376 points.
    public static let iPad16_5 = iPad("iPad16,5", "j720ap", "iPad Pro 13-inch (M4)", width: 2064, height: 2752)
    /// iPad Pro 11-inch (M5): 1668x2420, 834x1210 points.
    public static let iPad17_1 = iPad("iPad17,1", "j817ap", "iPad Pro 11-inch (M5)", width: 1668, height: 2420)
    /// iPad Pro 13-inch (M5): 2064x2752, 1032x1376 points.
    public static let iPad17_3 = iPad("iPad17,3", "j820ap", "iPad Pro 13-inch (M5)", width: 2064, height: 2752)

    /// Apple TV HD donor; the documented 26.4 beta pairing boots
    /// with explicit TV patches. No general catalog pairing is advertised.
    /// J42d's device tree supplies the TV idiom and 1x scale. The 1080p canvas
    /// and 72 ppi are provisional VM settings, not an attached television's density.
    public static let appleTV5_3 = VPhoneGuestDevice(
        family: .appleTV,
        productType: "AppleTV5,3",
        deviceClass: "j42dap",
        productName: "Apple TV HD",
        screen: .init(width: 1920, height: 1080, pixelsPerInch: 72, scale: 1.0),
    )

    /// Apple TV 4K (3rd generation), research only: Apple ships it no IPSW,
    /// so its arm64e userland comes from an OTA over a restored Apple TV HD
    /// (`system-tv-exp-ota_userland`). J255's device tree supplies the 2x
    /// identity; 3840x2160 is the panel it drives at 4K.
    public static let appleTV14_1 = VPhoneGuestDevice(
        family: .appleTV,
        productType: "AppleTV14,1",
        deviceClass: "j255ap",
        productName: "Apple TV 4K (3rd generation)",
        screen: .init(width: 3840, height: 2160, pixelsPerInch: 144, scale: 2.0),
    )

    /// Apple TV 4K (4th generation), J265AP. Its tvOS 27.2 userland and
    /// device tree come from a full OTA over the Apple TV HD restore base.
    /// The virtual display uses the same 4K canvas as the 3rd generation.
    public static let appleTV18_1 = VPhoneGuestDevice(
        family: .appleTV,
        productType: "AppleTV18,1",
        deviceClass: "j265ap",
        productName: "Apple TV 4K (4th generation)",
        screen: .init(width: 3840, height: 2160, pixelsPerInch: 144, scale: 2.0),
    )

    /// HomeView's two OTA board identities. The square 1088-pixel canvas is
    /// provisional; the donor tree supplies the home idiom and 2x artwork scale.
    public static let homeAccessory17_1 = VPhoneGuestDevice(
        family: .homeView,
        productType: "HomeAccessory17,1",
        deviceClass: "j490ap",
        productName: "HomeView (J490)",
        screen: .init(width: 1088, height: 1088, pixelsPerInch: 264, scale: 2.0),
    )

    public static let homeAccessory17_2 = VPhoneGuestDevice(
        family: .homeView,
        productType: "HomeAccessory17,2",
        deviceClass: "j491ap",
        productName: "HomeView (J491)",
        screen: .init(width: 1088, height: 1088, pixelsPerInch: 264, scale: 2.0),
    )

    /// HomePod mini (B520AP). It has no physical display; this small virtual
    /// canvas satisfies the VM graphics configuration and is not a panel
    /// specification or a promise of a graphical HomePod interface.
    public static let audioAccessory5_1 = VPhoneGuestDevice(
        family: .homePod,
        productType: "AudioAccessory5,1",
        deviceClass: "b520ap",
        productName: "HomePod mini",
        screen: .init(width: 320, height: 320, pixelsPerInch: 72, scale: 1.0),
    )

    /// Apple Watch Series 11 (GPS), 46 mm: 416x496 at 326 ppi, 208x248 points.
    /// The research board's kernel boots it with the watchOS kexts of its IPSW
    /// (the `watch` kernelcache recipe); N227b's device tree supplies the watch
    /// idiom and 2x identity.
    public static let watch7_18 = VPhoneGuestDevice(
        family: .watch,
        productType: "Watch7,18",
        deviceClass: "n227bap",
        productName: "Apple Watch Series 11 (GPS)",
        screen: .init(width: 416, height: 496, pixelsPerInch: 326, scale: 2.0),
    )

    /// Whether the guest's userland is plain arm64 rather than arm64e: only
    /// the Apple TV HD's. HomePod mini 27.0 ships arm64e dyld and launchd.
    /// The Apple TV HD has no paravirtual GPU driver to load, and its
    /// dyld needs the TV TPRO patches.
    public var hasPlainArm64Userland: Bool {
        self == .appleTV5_3
    }

    /// The device whose IPSW is restored under this one, for a device Apple
    /// ships no IPSW for: the Apple TV HD under the Apple TV 4K, whose own
    /// device tree and userland `fw prepare` takes from its OTA. HomeView uses
    /// the same restore base with its own board tree and full OTA. Nil for every
    /// device restored from its own IPSW.
    public var restoreBase: VPhoneGuestDevice? {
        self == .appleTV14_1 || self == .appleTV18_1 || family == .homeView ? .appleTV5_3 : nil
    }

    public static let known: [VPhoneGuestDevice] = [
        iPhone17_3,
        iPhone17_4, iPhone17_1, iPhone17_2, iPhone17_5,
        iPhone18_3, iPhone18_4, iPhone18_1, iPhone18_2, iPhone18_5,
        iPhone19_2, iPhone19_4,
        iPhone11_6,
        iPad16_1,
        iPad15_7,
        iPad15_3, iPad15_5,
        iPad16_3, iPad16_5,
        iPad17_1, iPad17_3,
        appleTV5_3, appleTV14_1, appleTV18_1,
        audioAccessory5_1, homeAccessory17_1, homeAccessory17_2,
        watch7_18,
    ]

    /// Cellular models that ship in the same IPSW as a known Wi-Fi model and map
    /// onto it: the VM has no baseband, so it gets the Wi-Fi identity.
    static let aliases: [String: String] = [
        "iPhone11,4": "iPhone11,6",
        "iPad16,2": "iPad16,1",
        "iPad15,4": "iPad15,3",
        "iPad15,6": "iPad15,5",
        "iPad16,4": "iPad16,3",
        "iPad16,6": "iPad16,5",
        "iPad17,2": "iPad17,1",
        "iPad17,4": "iPad17,3",
    ]

    /// The device a VM has when its configuration names none: every VM made
    /// before iPad guests existed is an iPhone17,3.
    public static let `default` = iPhone17_3

    public static func named(_ productType: String?) -> VPhoneGuestDevice? {
        guard let productType else { return nil }
        let canonical = aliases[productType] ?? productType
        return known.first { $0.productType == canonical }
    }

    // MARK: - Restore Tree

    /// The folder `fw prepare` builds the restore tree in.
    ///
    /// Every reader of the tree — restore, `cfw install`, Launchpad's cleanup —
    /// matches `iPhone*_Restore`, so non-iPhone trees keep that prefix as a
    /// restore-tree compatibility convention.
    public func restoreTreeName(version: String, build: String) -> String {
        switch family {
        case .iPhone: "\(productType)_\(version)_\(build)_Restore"
        case .iPad, .appleTV, .homePod, .homeView, .watch: "iPhoneOS_\(productType)_\(version)_\(build)_Restore"
        }
    }

    /// Where the restore tree keeps this device's own device tree.
    public var boardDeviceTreePath: String {
        "Firmware/all_flash/DeviceTree.\(deviceClass).im4p"
    }

    // MARK: - Detection

    /// The device a restore BuildManifest is for, from its
    /// `SupportedProductTypes`. One IPSW often covers several models — an 11-
    /// and a 13-inch iPad and their cellular twins — so `preferring` names the
    /// one wanted; without it, or when the IPSW does not cover it, the first
    /// known model wins. Nil when the manifest names no known device.
    public static func detect(buildManifest: [String: Any], preferring productType: String? = nil) -> VPhoneGuestDevice? {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        if let productType, types.contains(productType), let device = named(productType) {
            return device
        }
        for type in types {
            if let device = named(type) {
                return device
            }
        }
        return nil
    }

    public static func detect(buildManifestAt url: URL, preferring productType: String? = nil) -> VPhoneGuestDevice? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return detect(buildManifest: plist, preferring: productType)
    }

    /// Every known device a restore BuildManifest can supply.
    public static func covered(by buildManifest: [String: Any]) -> [VPhoneGuestDevice] {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        var devices: [VPhoneGuestDevice] = []
        for type in types {
            if let device = named(type), !devices.contains(device) {
                devices.append(device)
            }
        }
        return devices
    }

    /// Whether a restore BuildManifest is for an iPad at all, known or not.
    public static func isPadManifest(_ buildManifest: [String: Any]) -> Bool {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        return types.contains { $0.hasPrefix("iPad") }
    }
}
