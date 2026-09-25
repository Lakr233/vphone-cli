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
    ]
}
