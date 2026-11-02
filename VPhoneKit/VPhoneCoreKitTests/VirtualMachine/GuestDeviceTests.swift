import Foundation
import Testing
@testable import VPhoneCoreKit

/// Which device's OS a VM runs, as `fw prepare` finds it in the IPSW and the
/// VM's `config.plist` keeps it.
@Suite("Guest device")
struct GuestDeviceTests {
    @Test func `experimental iPhone 15 keeps its board and display through manifest encoding`() throws {
        let device = try #require(VPhoneGuestDevice.named("iPhone15,4"))
        #expect(device.deviceClass == "d37ap")
        #expect(device.screen.width == 1179 && device.screen.height == 2556)
        #expect(device.screen.scale == 3)
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPhone15,4"]]) == device)
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: device)
        let decoded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: PropertyListEncoder().encode(manifest))
        #expect(decoded.guestDevice == device)
        #expect(VPhoneGuestDevice.default == .iPhone17_3)
    }

    @Test(arguments: ["HomeAccessory17,1", "HomeAccessory17,2"])
    func `HomeView keeps distinct board identities and the tvOS executable platform`(type: String) throws {
        let device = try #require(VPhoneGuestDevice.named(type))
        #expect(device.family == .homeView && device.usesTVOS)
        #expect(!device.isPad && !device.hasPlainArm64Userland && device.presentsBoard)
        #expect(device.restoreBase == .appleTV5_3)
        #expect(device.deviceClass == (type == "HomeAccessory17,1" ? "j490ap" : "j491ap"))
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: device)
        let decoded = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: PropertyListEncoder().encode(manifest))
        #expect(decoded.guestDevice == device && decoded.screenConfig.scale == 2)
        #expect(VPhoneResources.vphonedName(for: device.family) == "vphoned-tvos")
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["HomeAccessory17,1", "HomeAccessory17,2"]], preferring: type) == device)
    }

    @Test
    func `a restore manifest names its device`() {
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPhone17,3"]]) == .iPhone17_3)
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPad16,1", "iPad16,2"]]) == .iPad16_1)
        // The cellular model shares the Wi-Fi one's IPSW and identity.
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPad16,2"]]) == .iPad16_1)
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPad13,1"]]) == nil)
        #expect(VPhoneGuestDevice.isPadManifest(["SupportedProductTypes": ["iPad13,1"]]))
    }

    @Test
    func `a supported TV donor is detected without admitting unknown TVs`() {
        let tv = ["SupportedProductTypes": ["AppleTV5,3"]]
        #expect(VPhoneGuestDevice.detect(buildManifest: tv) == .appleTV5_3)
        #expect(VPhoneGuestDevice.covered(by: tv) == [.appleTV5_3])
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["AppleTV11,1"]]) == nil)
        #expect(!VPhoneGuestDevice.appleTV5_3.isPad)
        #expect(VPhoneGuestDevice.appleTV5_3.presentsBoard)
        #expect(VPhoneGuestDevice.appleTV5_3.family.osName == "tvOS")
        #expect(VPhoneGuestDevice.appleTV5_3.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.j42dap.im4p")
        #expect(VPhoneGuestDevice.appleTV5_3.restoreTreeName(version: "26.4", build: "23L243")
            == "iPhoneOS_AppleTV5,3_26.4_23L243_Restore")
    }

    @Test
    func `HomePod mini has its own identity and the tvOS executable platform`() throws {
        let device = try #require(VPhoneGuestDevice.named("AudioAccessory5,1"))
        let manifest = ["SupportedProductTypes": ["AudioAccessory5,1"]]
        #expect(device == .audioAccessory5_1)
        #expect(device.family == .homePod)
        #expect(device.productName == "HomePod mini")
        #expect(device.family.osName == "HomePod Software")
        #expect(device.usesTVOS && !device.isPad && device.presentsBoard)
        #expect(!device.hasPlainArm64Userland && device.restoreBase == nil)
        #expect(device.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.b520ap.im4p")
        #expect(VPhoneGuestDevice.detect(buildManifest: manifest) == device)
        #expect(VPhoneGuestDevice.covered(by: manifest) == [device])
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["AudioAccessory1,1"]]) == nil)
        #expect(device.restoreTreeName(version: "27.0", build: "24J361")
            == "iPhoneOS_AudioAccessory5,1_27.0_24J361_Restore")
        #expect(!VPhoneGuestDevice.iPhone17_3.usesTVOS && !VPhoneGuestDevice.iPad16_1.usesTVOS)
        #expect(VPhoneGuestDevice.appleTV5_3.usesTVOS && VPhoneGuestDevice.appleTV14_1.usesTVOS)
    }

    @Test
    func `HomePod mini persists its identity and provisional virtual canvas`() throws {
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: .audioAccessory5_1)
        let decoded = try PropertyListDecoder().decode(
            VPhoneVirtualMachineManifest.self,
            from: PropertyListEncoder().encode(manifest),
        )
        #expect(decoded.guestProductType == "AudioAccessory5,1")
        #expect(decoded.guestDevice == .audioAccessory5_1)
        #expect(decoded.screenConfig == .init(width: 320, height: 320, pixelsPerInch: 72, scale: 1.0))
        #expect(decoded.updating(cpuCount: 4).guestDevice == .audioAccessory5_1)
    }

    @Test
    func `the Apple TV 4K is an arm64e TV guest at 2x restored over the Apple TV HD`() throws {
        let tv4k = try #require(VPhoneGuestDevice.named("AppleTV14,1"))
        #expect(tv4k == .appleTV14_1 && tv4k.family == .appleTV)
        #expect(tv4k.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.j255ap.im4p")
        #expect(tv4k.screen == .init(width: 3840, height: 2160, pixelsPerInch: 144, scale: 2.0))
        #expect(!tv4k.hasPlainArm64Userland && VPhoneGuestDevice.appleTV5_3.hasPlainArm64Userland)
        #expect(!VPhoneGuestDevice.iPhone17_3.hasPlainArm64Userland)
        #expect(tv4k.restoreBase == .appleTV5_3)
        #expect(VPhoneGuestDevice.appleTV5_3.restoreBase == nil && VPhoneGuestDevice.iPhone17_3.restoreBase == nil)
    }

    @Test
    func `the fourth generation Apple TV keeps its J265 identity and 4K canvas`() throws {
        let device = try #require(VPhoneGuestDevice.named("AppleTV18,1"))
        #expect(device == .appleTV18_1 && device.family == .appleTV)
        #expect(device.productName == "Apple TV 4K (4th generation)")
        #expect(device.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.j265ap.im4p")
        #expect(device.restoreBase == .appleTV5_3)
        #expect(device.usesTVOS && device.presentsBoard && !device.hasPlainArm64Userland)
        #expect(device.screen == VPhoneGuestDevice.appleTV14_1.screen)
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["AppleTV18,1"]]) == device)
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: device)
        let decoded = try PropertyListDecoder().decode(
            VPhoneVirtualMachineManifest.self, from: PropertyListEncoder().encode(manifest)
        )
        #expect(decoded.guestDevice == device && decoded.screenConfig == device.screen)
        #expect(decoded.updating(cpuCount: 4).guestProductType == "AppleTV18,1")
    }

    @Test
    func `a TV guest persists its identity and provisional landscape canvas`() throws {
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: .appleTV5_3)
        #expect(manifest.guestProductType == "AppleTV5,3")
        #expect(manifest.screenConfig == .init(width: 1920, height: 1080, pixelsPerInch: 72, scale: 1.0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try manifest.write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.guestDevice == .appleTV5_3)
        #expect(loaded.screenConfig == manifest.screenConfig)
        #expect(loaded.updating(cpuCount: 4).guestProductType == "AppleTV5,3")
    }

    @Test
    func `an iPad restore tree keeps the prefix every reader matches`() {
        let name = VPhoneGuestDevice.iPad16_1.restoreTreeName(version: "26.6.2", build: "23G90")
        #expect(name == "iPhoneOS_iPad16,1_26.6.2_23G90_Restore")
        #expect(name.hasPrefix("iPhone") && name.hasSuffix("_Restore"))
        #expect(VPhoneGuestDevice.iPhone17_3.restoreTreeName(version: "27.0", build: "24A435")
            == "iPhone17,3_27.0_24A435_Restore")
    }

    @Test
    func `a VM made before iPad guests is an iPhone17,3`() {
        let manifest = VPhoneVirtualMachineManifest.newVM()
        #expect(manifest.guestProductType == nil)
        #expect(manifest.guestDevice == .iPhone17_3)
    }

    @Test
    func `an iPad guest records its product and display`() throws {
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: .iPad16_1)
        #expect(manifest.guestProductType == "iPad16,1")
        #expect(manifest.guestDevice == .iPad16_1)
        #expect(manifest.screenConfig == .init(width: 1488, height: 2266, pixelsPerInch: 326, scale: 2.0))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try manifest.write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.guestDevice == .iPad16_1)
        #expect(loaded.screenConfig == manifest.screenConfig)

        // Editing CPU or memory keeps the device.
        #expect(loaded.updating(cpuCount: 4).guestProductType == "iPad16,1")
    }

    @Test
    func `an iPhone17,3 guest writes no product, so older bundles read it unchanged`() {
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: .iPhone17_3)
        #expect(manifest.guestProductType == nil)
        #expect(manifest.screenConfig == .default)
    }

    @Test
    func `an IPSW covering several iPads gives the one asked for`() {
        let air = ["SupportedProductTypes": ["iPad15,3", "iPad15,4", "iPad15,5", "iPad15,6"]]
        #expect(VPhoneGuestDevice.detect(buildManifest: air) == .iPad15_3)
        #expect(VPhoneGuestDevice.detect(buildManifest: air, preferring: "iPad15,5") == .iPad15_5)
        // A cellular model maps onto its Wi-Fi twin.
        #expect(VPhoneGuestDevice.detect(buildManifest: air, preferring: "iPad15,6") == .iPad15_5)
        // A model the IPSW does not cover is not invented.
        #expect(VPhoneGuestDevice.detect(buildManifest: air, preferring: "iPad17,3") == .iPad15_3)
        #expect(VPhoneGuestDevice.covered(by: air) == [.iPad15_3, .iPad15_5])
    }

    @Test
    func `every known iPad has a 2x panel and a board tree to read`() {
        for device in VPhoneGuestDevice.known where device.isPad {
            #expect(device.screen.scale == 2.0)
            #expect(device.screen.width < device.screen.height)
            #expect(device.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.\(device.deviceClass).im4p")
        }
        #expect(VPhoneGuestDevice.iPad17_3.screen == .init(width: 2064, height: 2752, pixelsPerInch: 264, scale: 2.0))
    }

    @Test
    func `an iPhone XS Max is presented as the iPhone17,3 with its own artwork`() {
        let xsMax = VPhoneGuestDevice.iPhone11_6
        #expect(!xsMax.presentsBoard)
        #expect(xsMax.notchedArtworkSubtype == 2688)
        #expect(xsMax.screen == .init(width: 1242, height: 2688, pixelsPerInch: 458, scale: 3.0))
        #expect(VPhoneGuestDevice.iPhone17_3.notchedArtworkSubtype == nil)
        // Its IPSW covers the XS (iPhone11,2), which vphone does not run, first.
        #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPhone11,2", "iPhone11,4", "iPhone11,6"]]) == xsMax)
    }

    @Test
    func `every iPhone but the XS Max presents its own board at 3x`() {
        #expect(VPhoneGuestDevice.iPhone17_3.presentsBoard)
        for device in VPhoneGuestDevice.known where device.family == .iPhone && device.notchedArtworkSubtype == nil {
            #expect(device.presentsBoard)
            #expect(device.screen.scale == 3.0)
            #expect(device.screen.pixelsPerInch == 460)
            #expect(device.screen.width < device.screen.height)
            #expect(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": [device.productType]]) == device)
            #expect(device.restoreTreeName(version: "27.0", build: "24A437") == "\(device.productType)_27.0_24A437_Restore")
        }
        for device in VPhoneGuestDevice.known where device.isPad {
            #expect(device.presentsBoard)
        }
        #expect(VPhoneGuestDevice.named("iPhone18,1") == .iPhone18_1)
        #expect(VPhoneGuestDevice.iPhone18_1.deviceClass == "v53ap")
        #expect(VPhoneGuestDevice.iPhone18_1.screen == .init(width: 1206, height: 2622, pixelsPerInch: 460, scale: 3.0))
    }

    @Test
    func `iPhone 18 Pro preserves its V63 identity and display in the VM`() throws {
        let device = try #require(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPhone19,2"]]))
        #expect(device == .iPhone19_2)
        #expect(device.deviceClass == "v63ap")
        #expect(device.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.v63ap.im4p")
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: device)
        let decoded = try PropertyListDecoder().decode(
            VPhoneVirtualMachineManifest.self,
            from: PropertyListEncoder().encode(manifest),
        )
        #expect(decoded.guestProductType == "iPhone19,2")
        #expect(decoded.guestDevice == device)
        #expect(decoded.screenConfig == .init(width: 1206, height: 2622, pixelsPerInch: 460, scale: 3.0))
    }

    @Test
    func `iPhone Duo preserves its V68 identity and outer display in the VM`() throws {
        let device = try #require(VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": ["iPhone19,4"]]))
        #expect(device == .iPhone19_4)
        #expect(device.boardDeviceTreePath == "Firmware/all_flash/DeviceTree.v68ap.im4p")
        let manifest = VPhoneVirtualMachineManifest.newVM().updating(guestDevice: device)
        let decoded = try PropertyListDecoder().decode(
            VPhoneVirtualMachineManifest.self,
            from: PropertyListEncoder().encode(manifest),
        )
        #expect(decoded.guestProductType == "iPhone19,4")
        #expect(decoded.guestDevice == device)
        #expect(decoded.screenConfig == .init(width: 1398, height: 2034, pixelsPerInch: 460, scale: 3.0))
    }
}
