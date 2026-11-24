import Foundation
import VPhonePatchKit

/// Lets a free personal team's app launch on a guest that was activated
/// offline, without a binary patch.
///
/// libmis asks Apple's servers to authorize such an app's profile, and that
/// request is signed with the device identity from an activation record. A
/// guest activated without Apple's servers has none, so the request fails and
/// "Verify App" can never succeed. libmis skips that step on its own when
/// MobileGestalt says `IsVirtualDevice` (true on every guest) and its
/// `ReleaseType` is `Internal`: it then clears `RespectUppTrustAndAuthorization`
/// and `OnlineAuthorization` (`MISValidateSignatureAndCopyInfoWithProgress`,
/// iOS 26.5 and 27.2). MobileGestalt reads `ReleaseType` from
/// SystemVersion.plist.
///
/// libsystem_darwin's os_variant reads the same key, and "Internal" would turn
/// on its internal content, diagnostics and UI checks for every process. The
/// override file Apple's os_variant reads at launchd's start turns all four
/// off again. Code that reads ReleaseType itself (MobileGestalt's answer,
/// CoreFoundation's SystemVersion dictionary) still sees Internal; libmis is
/// what needs it.
/// `os_variant_allows_internal_security_policies` never follows ReleaseType:
/// it asks whether the hardware is development-fused or the kernel a
/// development one. Research/0_binary_patch_comparison.md, "Free personal-team apps offline".
public enum CustomFirmwareInternalReleaseType {
    /// The root copy, which CoreFoundation, MobileGestalt and os_variant read,
    /// and the merged OS cryptex's copy, kept the same.
    public static let systemVersionPaths = CustomFirmwareBuildVersion.systemVersionPaths
    public static let key = "ReleaseType"
    public static let value = "Internal"
    public static let osVariantOverridePath = "usr/share/misc/os_variant_override"
    /// Every os_variant check the override can turn off.
    public static let osVariantOverride = Data("content,diagnostics,ui,security\n".utf8)

    /// SystemVersion.plist with `ReleaseType` set, in the plist's own format,
    /// or nil when it already is.
    public static func patched(systemVersion data: Data) throws -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              root["ProductVersion"] is String
        else {
            throw PatcherError.invalidFormat("Not a SystemVersion.plist")
        }
        if root[key] as? String == value {
            return nil
        }
        root[key] = value
        return try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
    }
}
