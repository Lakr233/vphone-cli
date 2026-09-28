import Foundation

/// Darwin notification names the Controls window offers as presets, grouped
/// by the part of the system that posts or observes them. Any other name can
/// be typed in.
enum VPhoneControlsNotification {
    static let presets: [[String]] = [
        [
            "com.apple.springboard.lockcomplete",
            "com.apple.springboard.lockstate",
            "com.apple.springboard.hasBlankedScreen",
            "com.apple.iokit.hid.displayStatus",
        ],
        [
            "com.apple.system.lowpowermode",
            "com.apple.system.thermalpressurelevel",
            "com.apple.system.lowdiskspace",
            "com.apple.system.timezone",
            "com.apple.system.clock_set",
            "com.apple.system.config.network_change",
            "com.apple.system.hostname",
            "com.apple.language.changed",
        ],
        [
            "com.apple.mobile.application_installed",
            "com.apple.mobile.application_uninstalled",
            "com.apple.mobile.keybagd.lock_status",
            "com.apple.mobile.keybagd.first_unlock",
        ],
        [
            "com.apple.mobile.lockdown.device_name_changed",
            "com.apple.mobile.lockdown.activation_state",
            "com.apple.mobile.lockdown.host_attached",
            "com.apple.mobile.lockdown.host_detached",
            "com.apple.mobile.developer_image_mounted",
        ],
    ]
}
