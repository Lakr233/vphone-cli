import Darwin
import Foundation
import IcliKit

/// Turns off CoreAnimation's surface compression on an iOS 18 guest.
///
/// iOS 18's AppleParavirtIOSurface maps only address format 0 and rejects the
/// compressed surfaces CoreAnimation asks for ("invalid address format (3)"):
/// backboardd's framebuffer allocation fails at boot, it retries forever, and
/// the screen stays black. Three keys in the any-user global domain turn the
/// compression and the deep framebuffer off.
///
/// The Minimal preset writes them into the restore image
/// (`filesystem-boot-ios18_surface_compression`). Every other preset restores
/// the system as shipped and customises the System volume afterwards, and the
/// preferences live on the Data volume, which the host cannot mount (see
/// ``GuestMobileGestaltCache``). So vphoned sets them here, and restarts the
/// backboardd that started without them; a guest that has them already is left
/// alone, so this happens once, on the first boot.
enum GuestCoreAnimationCompression {
    static let keys = ["CAEnableIOSurfaceCompression", "CAEnableFramebufferCompression", "CAEnableDeepFramebuffer"]
    private static let backboardd = "/usr/libexec/backboardd"

    static func applyOnStartup() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 18 else { return }
        let app = kCFPreferencesAnyApplication, user = kCFPreferencesAnyUser, host = kCFPreferencesAnyHost
        let missing = keys.filter {
            (CFPreferencesCopyValue($0 as CFString, app, user, host) as? Bool) != false
        }
        guard !missing.isEmpty else { return }
        let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, false) }) as CFDictionary
        CFPreferencesSetMultiple(values, nil, app, user, host)
        guard CFPreferencesSynchronize(app, user, host) else {
            NSLog("vphoned: CoreAnimation compression: cannot write the global preferences")
            return
        }
        let rows = (try? listProcesses(filter: "backboardd"))?["processes"] as? [[String: Any]] ?? []
        guard let pid = rows.first(where: { $0["executable"] as? String == backboardd })?["pid"] as? Int else {
            NSLog("vphoned: CoreAnimation compression: turned off (%@); backboardd not running yet", missing.joined(separator: ", "))
            return
        }
        guard kill(pid_t(pid), SIGKILL) == 0 else {
            NSLog("vphoned: CoreAnimation compression: kill(%d): %@", pid, String(cString: strerror(errno)))
            return
        }
        NSLog("vphoned: CoreAnimation compression: turned off (%@), restarted backboardd %d", missing.joined(separator: ", "), pid)
    }
}
