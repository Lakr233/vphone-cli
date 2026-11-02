import Foundation

/// Answers vphoned gives libMobileGestalt's cache because the device tree
/// cannot give them alone.
///
/// The Always On display is the one so far. MobileGestalt answers it from the
/// board's `/arm-io/disp0` `always-on-time`, and that property answers three
/// questions yes together: DeviceSupportsAlwaysOnDisplay,
/// DeviceSupportsAlwaysOnTime and DeviceSupportsAlwaysOnDisplayFlipbook.
/// Settings offers Always On Display only with the first two
/// (DisplayAndBrightnessSettings asks for AlwaysOnTime). The flipbook is the
/// panel controller (DCP) replaying prerendered frames, and CoreBrightness
/// asks the DCP for it in backboardd: this VM's paravirtual panel has none,
/// and an iPhone18,1 27.0.1 guest whose tree carried `always-on-time` lost
/// backboardd at every boot until launchd restarted it into the device
/// recovery environment. Without the flipbook, BacklightServices renders the
/// always-on Lock Screen itself (BLSHPseudoFlipbook), which works on a guest
/// (iPhone19,4 27.1, iPhone18,1 27.0.1). So the tree only marks a board that
/// has the display (`vphone-always-on-display` in `/product`), and these two
/// answers go into `CacheExtra`, where libMobileGestalt takes an answer before
/// working it out. The flipbook stays unanswered there and so no.
enum GuestMobileGestaltAnswers {
    /// DeviceSupportsAlwaysOnDisplay and DeviceSupportsAlwaysOnTime, as the
    /// cache keys them: the first 22 characters of the base64 MD5 of
    /// "MGCopyAnswer" followed by the name.
    static let alwaysOnDisplay = ["2OOJf1VhaM7NxfRok3HbWQ", "j8/Omm6s1lsmTDFsXjsBfA"]

    enum Update: Equatable {
        /// Not a cache vphoned can read, or one being written.
        case unreadable
        /// Every answer is already yes.
        case present
        /// The cache with the answers, to write back.
        case updated(Data)
    }

    /// `cache` with every key of `answers` answering yes in `CacheExtra`; the
    /// rest of the cache is kept as it is.
    static func answeringYes(_ answers: [String], in cache: Data) -> Update {
        guard var plist = try? PropertyListSerialization.propertyList(from: cache, format: nil) as? [String: Any],
              var extra = plist["CacheExtra"] as? [String: Any]
        else { return .unreadable }
        guard answers.contains(where: { extra[$0] as? Bool != true }) else { return .present }
        for key in answers {
            extra[key] = true
        }
        plist["CacheExtra"] = extra
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else {
            return .unreadable
        }
        return .updated(data)
    }
}
