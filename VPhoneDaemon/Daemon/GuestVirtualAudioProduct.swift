import Darwin
import Foundation
import IcliKit

/// Stores the ProductID VirtualAudio should route this guest with.
///
/// VirtualAudio reads `ProductIDOverride` in `com.apple.audio.virtualaudio`
/// before it derives a ProductID of its own, and the one it derives on a VM
/// never initializes: no sound anywhere. The sound plugin sets the key inside
/// audiomxd on every launch, which works as long as the plugin initializes
/// before VirtualAudio reads its defaults; audiomxd's sandbox keeps that write
/// from reaching disk. Nothing guarantees the order. A stored value needs
/// none, so vphoned stores the same one here, at startup: every launch of
/// audiomxd after this finds it whichever plugin comes first.
///
/// A value already stored gives way. The earlier recipe had 198 set by hand,
/// and a guest that kept it dropped every tone. Someone who wants another ID
/// sets `VPhoneVirtIOSoundProductID` in the plugin's settings instead, which
/// the plugin reads too; 0 there leaves VirtualAudio's key alone.
///
/// Only on a guest that has the plugin: the ID selects a speaker route, and
/// without the plugin there is no device for it.
///
/// See Research/Guest/virtio_sound.md §6.
enum GuestVirtualAudioProduct {
    private static let plugin = "/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver"
    private static let domain = "com.apple.audio.virtualaudio"
    private static let key = "ProductIDOverride"
    private static let settingsDomain = "com.apple.coreaudio"
    private static let settingsKey = "VPhoneVirtIOSoundProductID"

    static func storeOnStartup() {
        guard FileManager.default.fileExists(atPath: plugin) else { return }
        let product = product(machine: machine(), chosen: integer(settingsKey, in: settingsDomain))
        guard product != 0 else { return }
        let stored = integer(key, in: domain)
        guard stored != product else { return }
        do {
            _ = try writePreference(domain: domain, key: key, value: .int(Int64(product)))
            NSLog(
                "vphoned: VirtualAudio ProductIDOverride was %@, stored %d; audiomxd reads it at its next launch",
                stored.map(String.init) ?? "unset", product,
            )
        } catch {
            NSLog("vphoned: VirtualAudio ProductIDOverride: %@", String(describing: error))
        }
    }

    /// The same answer as the plugin's `VPGuestProductID`: 8010 on an iPad or
    /// iPhone guest, native B520 route 4 on HomePod mini, native acoustic
    /// product 4017 on a Watch7,18, 0 elsewhere unless one was chosen. This
    /// preference affects only VirtualAudio; the VM keeps its original
    /// MobileGestalt product token for every other subsystem.
    static func product(machine: String, chosen: Int?) -> Int {
        if let chosen, chosen >= 0 {
            return chosen
        }
        if machine == "AudioAccessory5,1" { return 4 }
        if machine == "Watch7,18" { return 4017 }
        return machine.hasPrefix("iPad") || machine.hasPrefix("iPhone") ? 8010 : 0
    }

    // MARK: - Helpers

    private static func integer(_ key: String, in domain: String) -> Int? {
        let value = CFPreferencesCopyValue(key as CFString, domain as CFString, "mobile" as CFString, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.intValue
    }

    static func machine() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
