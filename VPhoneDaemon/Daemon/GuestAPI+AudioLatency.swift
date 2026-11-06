import Foundation
import IcliKit

// MARK: - Host Audio Latency

enum AudioLatencyMethod: String, GuestMethod {
    case audioHostLatency = "audio.host_latency"

    var spec: MethodSpec {
        switch self {
        case .audioHostLatency: MethodSpec(.optional("seconds", .number))
        }
    }
}

/// What the Mac's output device adds after its mixer, which the sound plugin
/// adds to the speaker's output latency so a guest player holds its picture
/// back by as much as the sound is late. vphone-vm reads it from CoreAudio
/// and sends it after every connect and whenever the Mac's output changes.
///
/// It is stored as `VPhoneVirtIOSoundHostLatency` in `com.apple.coreaudio`
/// for user mobile, the domain the plugin reads its settings from in
/// audiomxd, and `com.vphone.audio.host-latency` is posted so a running
/// audiomxd reads it again. Each answer is `{seconds}`, plus `changed` after
/// a set; an unchanged value is neither written nor posted.
///
/// See Research/Guest/virtio_sound.md §6 (Picture against sound).
extension GuestAPI {
    private static let hostLatencyDomain = "com.apple.coreaudio"
    private static let hostLatencyKey = "VPhoneVirtIOSoundHostLatency"
    private static let hostLatencyNotification = "com.vphone.audio.host-latency"

    static func executeAudioLatency(_ m: AudioLatencyMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .audioHostLatency:
            let stored = storedHostLatency()
            guard params["seconds"] != nil else {
                return ["seconds": stored]
            }
            let seconds = try requiredNumber(params, "seconds")
            // The plugin takes at most one second; a Bluetooth output is a few
            // hundred milliseconds.
            guard seconds >= 0, seconds <= 1 else {
                throw GuestAPIError.invalidRequest("seconds must be between 0 and 1")
            }
            // CoreAudio's figure for one device does not move by less than a
            // frame; anything closer than that is the value already stored.
            guard abs(seconds - stored) >= 0.000_01 else {
                return ["seconds": stored, "changed": false]
            }
            _ = try writePreference(
                domain: hostLatencyDomain,
                key: hostLatencyKey,
                value: .float(seconds),
                notify: hostLatencyNotification,
            )
            NSLog("vphoned: host audio latency %.1f ms -> %.1f ms", stored * 1000, seconds * 1000)
            return ["seconds": seconds, "changed": true]
        }
    }

    private static func storedHostLatency() -> Double {
        let value = CFPreferencesCopyValue(
            hostLatencyKey as CFString, hostLatencyDomain as CFString, "mobile" as CFString, kCFPreferencesAnyHost,
        )
        return (value as? NSNumber)?.doubleValue ?? 0
    }
}
