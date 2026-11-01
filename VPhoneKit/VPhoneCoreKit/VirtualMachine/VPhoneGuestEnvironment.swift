import Foundation

// MARK: - VPhoneGuestEnvironment

/// The libraries vphone keeps in the guest's /usr/lib. cfw install places them
/// on the system volume, and the environment update replaces changed ones in a
/// running guest. vphoned keeps the same list in `GuestAPI+Environment.swift`.
public enum VPhoneGuestEnvironment {
    public static let libraries = [
        "launchdhook-vphone.dylib",
        "SystemHook-vphone.dylib",
        "libvcamcaptured.dylib",
        "libcamfix.dylib",
        "libmisfix.dylib",
        "libhapticsfix.dylib",
        "libbatteryhealthfix.dylib",
        "libdevicehubfix.dylib",
        "libdevicename.dylib",
        "libprefsfix.dylib",
        "libsigninfix.dylib", "libvphoneios17desktop.dylib",
        "libvphonefolddisplay.dylib",
        "libvphonefoldguard.dylib",
        "libvphonehinge.dylib",
        "libvphonegyro.dylib",
        "libvphoneaccelerometer.dylib",
        "libvphoneattitude.dylib",
    ]

    /// What an Apple TV takes: the launchd hook and SystemHook, which give
    /// every spawn the RootHide loader links, the bootstrap root and the tweak
    /// loader. The others serve iOS processes (SpringBoard, Settings, the
    /// camera) or are not validated in tvOS ones, and the spawn hooks insert a
    /// library only when it is installed.
    public static let tvLibraries = ["launchdhook-vphone.dylib", "SystemHook-vphone.dylib"]

    /// Selection installs/removes these. A live hash sync may replace an
    /// installed copy, but must never reinstall a patch the user turned off.
    public static let selectedLibraries: Set<String> = [
        "libprefsfix.dylib", "libsigninfix.dylib", "libvphoneios17desktop.dylib",
        "libvphonegyro.dylib", "libvphoneaccelerometer.dylib", "libvphoneattitude.dylib",
        "libvphonehinge.dylib", "libvphonefoldguard.dylib", "libvphonefolddisplay.dylib",
    ]
}
