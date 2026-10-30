import Foundation
import Testing
@testable import VPhoneCoreKit

struct FirmwareCatalogReportTests {
    @Test(arguments: ["HomeAccessory17,1", "HomeAccessory17,2"])
    func `HomeView 27_2 uses its full Pallas OTA and the HD restore base`(type: String) throws {
        let release = try #require(VPhoneFirmwareCatalog.otaRelease(for: type, build: "24V514"))
        #expect(release.version == "27.2" && release.size == 6_509_559_808)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: release.url, preferring: type) == release)
        #expect(release.key == "C6bVk4JwejgY6PfCJTX/nbrw/CtdphOG5EmsQMYe6As=")
        let pairings = VPhoneFirmwareCatalog.pairings(for: type, hostMacOS: 27)
        #expect(pairings.count == 1 && pairings[0].iosURL == release.url)
        #expect(pairings[0].cloudosURL == VPhoneFirmwareCatalog.cloud264)
        #expect(VPhoneFirmwareCatalog.restoreBaseURL(for: release)?.hasSuffix("AppleTV5,3_26.6_23L773_Restore.ipsw") == true)
        #expect(VPhoneFirmwareCatalog.pairings(for: type, hostMacOS: 26).isEmpty)
        let report = try #require(VPhoneFirmwareCatalog.report(hostMacOS: 27).devices.first { $0.productType == type })
        #expect(report.family == "homeView" && report.pairings[0].ios.build == "24V514")
    }

    @Test func `maps every pairing`() {
        let report = VPhoneFirmwareCatalog.report
        #expect(report.device == VPhoneFirmwareCatalog.device)
        #expect(report.pairings.count == VPhoneFirmwareCatalog.pairings.count)

        for (entry, pairing) in zip(report.pairings, VPhoneFirmwareCatalog.pairings) {
            #expect(entry.ios.name == pairing.iosName)
            #expect(entry.ios.url == pairing.iosURL)
            #expect(entry.recommendedCloudOS.name == pairing.cloudosName)
            #expect(entry.recommendedCloudOS.url == pairing.cloudosURL)
        }
    }

    @Test func `an OTA pairing names its build and the files it needs`() throws {
        let tv4K = try #require(VPhoneFirmwareCatalog.report(hostMacOS: 27).devices.first { $0.productType == "AppleTV14,1" })
        let ipsw = try #require(tv4K.pairings.first { $0.ios.name == "tvOS 26.6" })
        let ota = try #require(tv4K.pairings.first { $0.ios.name == "tvOS 27.0" })
        #expect(ipsw.ios.build == nil && ipsw.ios.files == nil)
        #expect(ota.ios.build == "24J361")
        #expect(ota.ios.files == ["ota/AppleTV14,1_27.0_24J361_OTA.aea", "AppleTV5,3_26.6_23L773_Restore.ipsw"])
        // An IPSW's entry encodes as before, so an older Launchpad reads it unchanged.
        let json = try #require(String(data: JSONEncoder().encode(ipsw), encoding: .utf8))
        #expect(!json.contains("build") && !json.contains("files"))
    }

    @Test func `iOS 26.4 to 26.6 can also run on their own cloudOS, on the research board`() throws {
        let report = VPhoneFirmwareCatalog.report
        let own = Dictionary(uniqueKeysWithValues: report.pairings.compactMap { entry in
            entry.matchingCloudOS.map { (entry.ios.name, $0.name) }
        })
        #expect(own["iOS 26.4.2"] == "cloudOS 26.4 (23E244)")
        #expect(own["iOS 26.5"] == "cloudOS 26.5 (23F75)")
        #expect(own["iOS 26.6.2"] == "cloudOS 26.6 (23G71)")
        #expect(own["iOS 26.3.1"] == nil && own["iOS 27.0"] == nil)
        // The recommendation stays the 26.4 beta, which needs neither root nor ipsw.
        let ios266 = try #require(report.pairings.first { $0.ios.name == "iOS 26.6" })
        #expect(ios266.recommendedCloudOS.name == "cloudOS 26.4")
        // Only the iPhone has run on the research board.
        let pad = try #require(report.devices.first { $0.family == "iPad" })
        #expect(pad.pairings.allSatisfy { $0.matchingCloudOS == nil })
        // An entry without one encodes as before, so an older Launchpad reads it unchanged.
        let ios27 = try #require(report.pairings.first { $0.ios.name == "iOS 27.0" })
        #expect(try !String(decoding: JSONEncoder().encode(ios27), as: UTF8.self).contains("matchingCloudOS"))
    }

    @Test func `lists every curated guest`() {
        let report = VPhoneFirmwareCatalog.report(hostMacOS: 27)
        #expect(report.devices.map(\.productType) == VPhoneGuestDevice.known.map(\.productType))
        #expect(report.devices.first?.pairings == report.pairings)
        for device in report.devices.dropFirst() {
            #expect(device.family == VPhoneGuestDevice.named(device.productType)?.family.rawValue)
            #expect(!device.pairings.isEmpty)
            #expect(device.name == VPhoneGuestDevice.named(device.productType)?.productName)
        }
    }

    @Test func `the Apple TV 4K pairs each OTA with the Apple TV HD IPSW it is restored over`() throws {
        let pairings = VPhoneFirmwareCatalog.pairings(for: "AppleTV14,1", hostMacOS: 27)
        #expect(pairings.map(\.iosName) == ["tvOS 26.6", "tvOS 27.0"])
        let hd = try #require(VPhoneFirmwareCatalog.pairings(for: "AppleTV5,3").first { $0.iosName == "tvOS 26.6" })
        for p in pairings {
            #expect(p.device == "AppleTV14,1")
            #expect(p.cloudosURL == hd.cloudosURL)
        }
        // 26.6 names the HD's IPSW of its own version; 27.0, which the HD
        // never got, names its OTA, and `fw prepare` finds the base from it.
        #expect(pairings[0].iosURL == hd.iosURL)
        let ota27 = try #require(VPhoneFirmwareCatalog.otaRelease(source: pairings[1].iosURL))
        #expect(ota27.version == "27.0" && ota27.build == "24J361" && ota27.baseVersion == "26.6")
        #expect(VPhoneFirmwareCatalog.restoreBaseURL(for: ota27) == hd.iosURL)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: "/cache/ota/\(ota27.fileName)") == ota27)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: hd.iosURL) == nil)
        let ota = try #require(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV14,1", build: "23L773"))
        #expect(ota.version == "26.6")
        #expect(ota.url.hasPrefix("https://updates.cdn-apple.com/") && ota.url.hasSuffix(".aea"))
        #expect(ota.size == 4_764_729_344)
        #expect(Data(base64Encoded: try #require(ota.key))?.count == 32)
        #expect(ota.fileName == "AppleTV14,1_26.6_23L773_OTA.aea")
        #expect(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV14,1", build: "23L760") == nil)
        #expect(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV5,3", build: "23L773") == nil)
        // Every OTA has a base release to be restored over.
        for release in VPhoneFirmwareCatalog.otaReleases {
            let guest = try #require(VPhoneGuestDevice.named(release.productType))
            let base = guest.restoreBase ?? guest
            #expect(VPhoneFirmwareCatalog.pairings(for: base.productType).contains { $0.iosName.hasSuffix(" \(release.baseVersion)") })
            #expect(VPhoneFirmwareCatalog.restoreBaseURL(for: release) != nil)
            if let key = release.key { #expect(Data(base64Encoded: key)?.count == 32) }
        }
    }

    @Test func `the fourth generation Apple TV offers only its 27 point 2 OTA over the HD base`() throws {
        let release = try #require(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV18,1", build: "24K120"))
        #expect(release.version == "27.2" && release.baseVersion == "26.6")
        #expect(release.size == 5_234_491_392)
        #expect(release.key == "B/S/c74WZgPJLoJc7BDr+IxDjtQZ2H8gUwWp7kq9RpI=")
        #expect(release.url.hasSuffix("/c6553d1b2d6e080adcd92fd8281e36a47dc870e22fb9d0ac057b4489916bcd9c.aea"))
        #expect(release.fileName == "AppleTV18,1_27.2_24K120_OTA.aea")
        #expect(VPhoneFirmwareCatalog.otaRelease(source: "/cache/ota/\(release.fileName)") == release)
        let pairings = VPhoneFirmwareCatalog.pairings(for: "AppleTV18,1", hostMacOS: 27)
        #expect(pairings.map(\.iosName) == ["tvOS 27.2"])
        #expect(pairings.first?.iosURL == release.url)
        #expect(pairings.first?.cloudosURL == VPhoneFirmwareCatalog.cloud264)
        let base = try #require(VPhoneFirmwareCatalog.restoreBaseURL(for: release))
        #expect(base.hasSuffix("/AppleTV5,3_26.6_23L773_Restore.ipsw"))
        let device = try #require(VPhoneFirmwareCatalog.report(hostMacOS: 27).devices.first { $0.productType == "AppleTV18,1" })
        #expect(device.family == "appleTV" && device.name == "Apple TV 4K (4th generation)")
        #expect(device.pairings.count == 1 && device.pairings[0].ios.build == "24K120")
        #expect(device.pairings[0].ios.files == ["ota/\(release.fileName)", (base as NSString).lastPathComponent])
        #expect(VPhoneFirmwareCatalog.pairings(for: "AppleTV18,1", hostMacOS: 26).isEmpty)
        #expect(!VPhoneFirmwareCatalog.report(hostMacOS: 26).devices.contains { $0.productType == "AppleTV18,1" })
        #expect(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV18,1", build: "24J361") == nil)
    }

    @Test func `Apple TV pairings are tvOS releases on cloudOS 26.4`() throws {
        let pairings = VPhoneFirmwareCatalog.pairings(for: "AppleTV5,3")
        #expect(pairings.map(\.iosName) == ["tvOS 26.6"])
        for p in pairings {
            #expect(p.device == "AppleTV5,3")
            #expect(p.iosURL.hasPrefix("https://updates.cdn-apple.com/"))
            #expect(p.iosURL.contains("/AppleTV5,3_"))
            #expect(p.iosURL.hasSuffix("_Restore.ipsw"))
            #expect(p.cloudosName == "cloudOS 26.4")
            #expect(p.cloudosURL == VPhoneFirmwareCatalog.cloud264)
        }
        let tv = try #require(VPhoneFirmwareCatalog.report.devices.first { $0.productType == "AppleTV5,3" })
        #expect(tv.family == "appleTV")
        #expect(tv.name == "Apple TV HD")
    }

    @Test func `HomePod mini pairs its native 27 IPSW with cloudOS without an OTA base`() throws {
        let pairings = VPhoneFirmwareCatalog.pairings(for: "AudioAccessory5,1", hostMacOS: 27)
        #expect(pairings.count == 2)
        let pairing = try #require(pairings.first)
        #expect(pairing.device == "AudioAccessory5,1")
        #expect(pairing.iosName == "HomePod Software 27.0")
        #expect(pairing.iosURL == "https://updates.cdn-apple.com/2026SFallFCS/a595a3b2-2c42-470a-9417-a705aaafa05c/AudioAccessory5,1_27.0_24J361_Restore.ipsw")
        #expect(pairing.cloudosName == "cloudOS 26.4")
        #expect(pairing.cloudosURL == VPhoneFirmwareCatalog.cloud264)
        #expect(VPhoneGuestDevice.audioAccessory5_1.restoreBase == nil)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: pairing.iosURL) == nil)
        #expect(VPhoneFirmwareCatalog.otaRelease(for: "AudioAccessory5,1", build: "24J361") == nil)
        #expect(VPhoneFirmwareCatalog.pairings(for: "AudioAccessory1,1").isEmpty)

        let device = try #require(VPhoneFirmwareCatalog.report.devices.first { $0.productType == "AudioAccessory5,1" })
        #expect(device.family == "homePod" && device.name == "HomePod mini")
        let entry = try #require(device.pairings.first)
        #expect(entry.ios.name == pairing.iosName && entry.ios.url == pairing.iosURL)
        #expect(entry.ios.build == nil && entry.ios.files == nil)
        #expect(entry.recommendedCloudOS.url == VPhoneFirmwareCatalog.cloud264)
    }

    @Test func `HomePod 27 point 2 takes its full ZIP OTA over its own 27 IPSW`() throws {
        let release = try #require(VPhoneFirmwareCatalog.otaRelease(for: "AudioAccessory5,1", build: "24K120"))
        #expect(release.version == "27.2" && release.baseVersion == "27.0")
        #expect(release.key == nil && release.size == 3_051_441_612)
        #expect(release.fileName == "AudioAccessory5,1_27.2_24K120_OTA.zip")
        let pairings = VPhoneFirmwareCatalog.pairings(for: release.productType, hostMacOS: 27)
        #expect(VPhoneFirmwareCatalog.restoreBaseURL(for: release) == pairings[0].iosURL)
        #expect(pairings[1].iosURL == release.url)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: "/cache/ota/\(release.fileName)") == release)
        let device = try #require(VPhoneFirmwareCatalog.report(hostMacOS: 27).devices.first { $0.productType == release.productType })
        #expect(device.pairings[1].ios.build == "24K120")
        #expect(device.pairings[1].ios.files == ["ota/\(release.fileName)", (pairings[0].iosURL as NSString).lastPathComponent])
    }

    @Test func `a Mac before macOS 27 is offered no OTA it cannot unpack`() throws {
        // tvOS 27.0 and HomePod Software 27.2 compress their chunks with LZRAVEN.
        let lzraven = VPhoneFirmwareCatalog.otaReleases.filter { $0.minimumHostMacOS == 27 }
        #expect(Set(lzraven.map(\.build)) == ["24J361", "24K120", "24V514"])
        // Every 27-series OTA is LZRAVEN so far: a new one must say so, or an
        // older Mac would be offered it and fail only after its downloads.
        for release in VPhoneFirmwareCatalog.otaReleases where Int(release.version.split(separator: ".")[0]) ?? 0 >= 27 {
            #expect(release.minimumHostMacOS == VPhoneOTARelease.lzravenMinimumMacOS, "\(release.productType) \(release.version)")
        }
        for release in lzraven {
            #expect(!release.unpacks(onMacOS: 26) && release.unpacks(onMacOS: 27))
        }
        #expect(VPhoneFirmwareCatalog.pairings(for: "AppleTV14,1", hostMacOS: 26).map(\.iosName) == ["tvOS 26.6"])
        #expect(VPhoneFirmwareCatalog.pairings(for: "AudioAccessory5,1", hostMacOS: 26).map(\.iosName) == ["HomePod Software 27.0"])
        let report = VPhoneFirmwareCatalog.report(hostMacOS: 26)
        let tv4K = try #require(report.devices.first { $0.productType == "AppleTV14,1" })
        #expect(tv4K.pairings.map(\.ios.name) == ["tvOS 26.6"])
        // Nothing else depends on the host.
        #expect(VPhoneFirmwareCatalog.pairings(for: "AppleTV5,3", hostMacOS: 26) == VPhoneFirmwareCatalog.pairings(for: "AppleTV5,3", hostMacOS: 27))
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPhone17,3", hostMacOS: 26) == VPhoneFirmwareCatalog.pairings)
    }

    @Test func `i pad pairings come from an IPSW that covers the device`() {
        for guest in VPhoneGuestDevice.known where guest.isPad {
            let pairings = VPhoneFirmwareCatalog.pairings(for: guest.productType)
            #expect(pairings.map(\.iosName).first == "iPadOS 26.0" || guest.productType.hasPrefix("iPad17,"))
            #expect(pairings.map(\.iosName).last == "iPadOS 27.0.1")
            for p in pairings {
                #expect(p.device == guest.productType)
                #expect(p.iosURL.hasPrefix("https://updates.cdn-apple.com/"))
                #expect(p.iosURL.hasSuffix("_Restore.ipsw"))
                #expect(p.cloudosURL.contains("/private-cloud-compute/"))
                // The iPad Pro (M4) IPSWs are named iPad_Pro_M4_…; the rest name their models.
                let name = (p.iosURL as NSString).lastPathComponent
                #expect(name.hasPrefix("iPad_Pro_M4_") || name.split(separator: "_")[0].split(separator: ",").count >= 2)
                #expect(name.contains("_\(p.iosName.dropFirst("iPadOS ".count))_"))
            }
        }
    }

    @Test func `other i phones have pairings of their own`() {
        for guest in VPhoneGuestDevice.known where guest.family == .iPhone && guest.presentsBoard && guest != .iPhone17_3 {
            let pairings = VPhoneFirmwareCatalog.pairings(for: guest.productType)
            let firstRelease = switch guest.productType {
            case "iPhone18,5": "iOS 26.3.1"
            case "iPhone19,2": "iOS 27.0.1"
            case "iPhone19,4": "iOS 27.1"
            default: "iOS 26.0"
            }
            #expect(pairings.map(\.iosName).first == firstRelease)
            #expect(pairings.map(\.iosName).last == (guest.productType == "iPhone19,4" ? "iOS 27.1" : "iOS 27.0.1"))
            for p in pairings {
                #expect(p.device == guest.productType)
                #expect(p.iosURL.hasPrefix("https://updates.cdn-apple.com/"))
                let name = (p.iosURL as NSString).lastPathComponent
                #expect(name.hasPrefix("\(guest.productType)_\(p.iosName.dropFirst("iOS ".count))_"))
                #expect(name.hasSuffix("_Restore.ipsw"))
                #expect(p.cloudosURL == VPhoneFirmwareCatalog.recommendedCloudOS(forVersion: String(p.iosName.dropFirst("iOS ".count))).url)
            }
        }
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPhone18,1") != VPhoneFirmwareCatalog.pairings)
    }

    @Test func `an i phone XS max pairs each iOS 18 release with its own research board cloud OS, linked kernel-first`() {
        let pairings = VPhoneFirmwareCatalog.pairings(for: "iPhone11,6")
        #expect(pairings.map(\.iosName) == ["iOS 18.1", "iOS 18.2.1", "iOS 18.3.1", "iOS 18.5", "iOS 18.6", "iOS 18.7", "iOS 18.7.2"])
        for p in pairings {
            let version = p.iosName.dropFirst("iOS ".count)
            #expect(p.device == "iPhone11,6")
            #expect((p.iosURL as NSString).lastPathComponent.hasPrefix("iPhone11,2,iPhone11,4,iPhone11,6_\(version)_"))
            #expect(p.cloudosName.hasPrefix("cloudOS \(version) ("))
            #expect(p.cloudosURL.contains("/private-cloud-compute/"))
        }
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPhone11,4") == pairings)
        let devices = VPhoneFirmwareCatalog.report.devices
        #expect(devices.first { $0.productType == "iPhone11,6" }?.kernelcacheLayout == "kernel-first")
        #expect(devices.filter { $0.kernelcacheLayout != nil }.map(\.productType) == ["iPhone11,6"])
    }

    @Test func `cellular i pad gets its wi fi model's pairings`() {
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPad17,4") == VPhoneFirmwareCatalog.pairings(for: "iPad17,3"))
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPad17,3").first?.device == "iPad17,3")
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPad15,8").isEmpty)
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPhone17,3") == VPhoneFirmwareCatalog.pairings)
    }

    @Test func `i pad cloud OS follows the i phone pairing of the same release`() {
        let iPhone = Dictionary(
            VPhoneFirmwareCatalog.pairings.map { ($0.iosName.replacingOccurrences(of: "iOS ", with: ""), $0.cloudosURL) },
            uniquingKeysWith: { first, _ in first },
        )
        for p in VPhoneFirmwareCatalog.pairings(for: "iPad16,1") {
            let version = p.iosName.replacingOccurrences(of: "iPadOS ", with: "")
            #expect(iPhone[version] == p.cloudosURL, "\(version)")
        }
    }

    @Test func `round trips JSON`() throws {
        let report = VPhoneFirmwareCatalog.report
        let back = try JSONDecoder().decode(VPhoneFirmwareCatalogReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
    }
}
