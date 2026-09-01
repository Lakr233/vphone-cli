import Foundation

// MARK: - VPhoneFirmwarePairing

/// A known iPhone-IPSW ↔ cloudOS pairing for iPhone17,3, with friendly names for
/// prompts and the direct download URLs `fw prepare` consumes.
public struct VPhoneFirmwarePairing: Sendable, Equatable {
    public let iosName: String
    public let iosURL: String
    public let cloudosName: String
    public let cloudosURL: String

    public init(iosName: String, iosURL: String, cloudosName: String, cloudosURL: String) {
        self.iosName = iosName
        self.iosURL = iosURL
        self.cloudosName = cloudosName
        self.cloudosURL = cloudosURL
    }
}

// MARK: - VPhoneCloudOSOption

public struct VPhoneCloudOSOption: Sendable, Equatable {
    public let name: String
    public let url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

// MARK: - VPhoneFirmwareCatalog

/// The known downloadable iPhone/cloudOS pairings. Prompts show the friendly
/// `iosName`/`cloudosName`; selection resolves to the URLs.
public enum VPhoneFirmwareCatalog {
    /// The iPhone model every catalog IPSW targets.
    public static let device = "iPhone17,3"

    // cloudOS images (one per major); referenced by multiple iPhone builds.
    static let cloud261 = "https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349"
    static let cloud262 = "https://updates.cdn-apple.com/private-cloud-compute/0cb00f22e0f7a8b33995b49b2bdca77f781ed6093a09c570ac21b0f012bab908"
    static let cloud263 = "https://updates.cdn-apple.com/private-cloud-compute/edc92b58ab7e2f207a6407fd0a0e1a60f7d43bf9d93325bf6d3db3e154ee5525"
    static let cloud264 = "https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64"

    public static let pairings: [VPhoneFirmwarePairing] = [
        .init(iosName: "iOS 18.6.2", iosURL: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-20738/98758B5A-311E-4538-B365-FEE3D8792CDF/iPhone17,3_18.6.2_22G100_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.0", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40775/B7282E74-76C1-4D0A-8FAE-CE97FC2330C2/iPhone17,3_26.0_23A341_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.0.1", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-46329/C1717B2A-9E58-4131-A398-75D9B1D01A89/iPhone17,3_26.0.1_23A355_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.1", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw", cloudosName: "cloudOS 26.1", cloudosURL: cloud261),
        .init(iosName: "iOS 26.2", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-90760/1214478F-8ED8-4AE0-B693-2F63CE0259A9/iPhone17,3_26.2_23C55_Restore.ipsw", cloudosName: "cloudOS 26.2", cloudosURL: cloud262),
        .init(iosName: "iOS 26.2.1", iosURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34150/D14FB1F1-B8C5-4A20-9250-8DD35EF19BF5/iPhone17,3_26.2.1_23C71_Restore.ipsw", cloudosName: "cloudOS 26.2", cloudosURL: cloud262),
        .init(iosName: "iOS 26.3", iosURL: "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-39165/E8E603F3-A2E2-4638-8067-394754896386/iPhone17,3_26.3_23D127_Restore.ipsw", cloudosName: "cloudOS 26.3", cloudosURL: cloud263),
        .init(iosName: "iOS 26.3.1", iosURL: "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90312/17B5C7BE-C560-43BD-BA9A-7DD1E5C2FC23/iPhone17,3_26.3.1_23D8133_Restore.ipsw", cloudosName: "cloudOS 26.3", cloudosURL: cloud263),
        .init(iosName: "iOS 26.4", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-06082/FE21226A-B87F-4FC7-9D4B-B97A9EAF5C20/iPhone17,3_26.4_23E246_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.4.1", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28526/10E1E3EC-6A3E-4620-A569-8E0C4361AB77/iPhone17,3_26.4.1_23E254_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.4.2", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60828/A4082066-CCC4-4903-89E6-FF4801EA609C/iPhone17,3_26.4.2_23E261_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.5", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-63074/5E6B4A05-BDBC-45FE-9606-22B8F4315989/iPhone17,3_26.5_23F77_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.5.2", iosURL: "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25549/1AFB1F72-E48E-476A-9C21-42B27C846C01/iPhone17,3_26.5.2_23F84_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.6", iosURL: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-58193/1F477C3E-934B-43C0-B428-753B9E005EC0/iPhone17,3_26.6_23G71_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 26.6.1", iosURL: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-93817/B5362BAA-F3EE-49C8-BA43-309F0DAD1362/iPhone17,3_26.6.1_23G83_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 1", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/122-99394/32118457-A80B-4953-BF2A-11F74FD7D375/iPhone17,3_27.0_24A5355q_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 2", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-21207/F0510574-F649-48C5-B535-0A477E342BFB/iPhone17,3_27.0_24A5370h_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 3", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-35950/D135F5B5-C2BE-4630-8AE9-C78A6F0E8381/iPhone17,3_27.0_24A5380h_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 4", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-57108/5E816D0E-89BB-4B95-8825-6A3EDF22E509/iPhone17,3_27.0_24A5390f_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 5", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-86338/57B34BF9-3BF5-4B47-BCCA-81B282175957/iPhone17,3_27.0_24A5408d_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 6", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/ad5b3026-b03e-4b21-8bcb-96d6ea527e09/iPhone17,3_27.0_24A5418b_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 7", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/ad5a4f9d-f005-466b-bbcf-3b466040074b/iPhone17,3_27.0_24A5424a_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
        .init(iosName: "iOS 27 beta 8", iosURL: "https://updates.cdn-apple.com/2026SpringSeed/2d03d580-843b-4b2a-b09d-976b31c10744/iPhone17,3_27.0_24A5430a_Restore.ipsw", cloudosName: "cloudOS 26.4", cloudosURL: cloud264),
    ]

    /// Distinct cloudOS images (first-seen order) for the "choose the cloudOS" prompt.
    public static var cloudOSOptions: [VPhoneCloudOSOption] {
        var seen = Set<String>()
        var out: [VPhoneCloudOSOption] = []
        for p in pairings where seen.insert(p.cloudosName).inserted {
            out.append(VPhoneCloudOSOption(name: p.cloudosName, url: p.cloudosURL))
        }
        return out
    }

    /// JSON-friendly projection of the catalog: each iOS build with its recommended cloudOS.
    public static var report: VPhoneFirmwareCatalogReport {
        VPhoneFirmwareCatalogReport(
            device: device,
            pairings: pairings.map {
                .init(
                    ios: .init(name: $0.iosName, url: $0.iosURL),
                    recommendedCloudOS: .init(name: $0.cloudosName, url: $0.cloudosURL))
            })
    }
}

// MARK: - VPhoneFirmwareCatalogReport

/// Codable view of the firmware catalog for `fw catalog --json`.
public struct VPhoneFirmwareCatalogReport: Codable, Equatable, Sendable {
    public struct Firmware: Codable, Equatable, Sendable {
        public let name: String
        public let url: String
        public init(name: String, url: String) { self.name = name; self.url = url }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let ios: Firmware
        public let recommendedCloudOS: Firmware
        public init(ios: Firmware, recommendedCloudOS: Firmware) {
            self.ios = ios
            self.recommendedCloudOS = recommendedCloudOS
        }
    }

    public let device: String
    public let pairings: [Entry]

    public init(device: String, pairings: [Entry]) {
        self.device = device
        self.pairings = pairings
    }
}
