import Darwin
import Foundation
import IcliKit

/// Drops IconServices' icon store when it predates the iOS 18 GPU transport.
///
/// An iOS 18 guest on a cloudOS 26.1 kernel had no Metal device before
/// `system-systemhook-cfw-ios18_gpu_transport`. Without one, iconservicesagent
/// rendered every graphic icon (an SF Symbol on a colored square, such as each
/// Settings row's) fully transparent, stored the result, and kept serving it
/// once the GPU worked: Settings' rows stayed blank. The store is on the Data
/// volume, which the host cannot mount (see ``GuestMobileGestaltCache``), so
/// vphoned drops it here.
///
/// The rule is about age, as the MobileGestalt cache's is. `cfw install` writes
/// the transport's marker when it turns the transport on and leaves it alone
/// afterwards, so a store created before the marker was rendered without a GPU,
/// and the store rebuilt after a drop is newer. App icons in it are drawn
/// again on demand.
///
/// See Research/Guest/ios18_gpu_transport.md.
enum GuestIconServicesCache {
    static let storePath =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache"
    static let transportMarker = "/usr/lib/vphone-ios18-gpu"
    private static let agent = "/System/Library/CoreServices/iconservicesagent"

    static func dropIfOlderThanGPUOnStartup() {
        guard let marker = birthTime(transportMarker), let store = birthTime(storePath),
              isEarlier(store, than: marker)
        else { return }
        do {
            try FileManager.default.removeItem(atPath: storePath)
        } catch {
            NSLog("vphoned: icon store: cannot remove %@: %@", storePath, error.localizedDescription)
            return
        }
        // A running agent keeps writing into the store it opened; launchd
        // starts it again for its next client, with a new one.
        let rows = (try? listProcesses(filter: "iconservices"))?["processes"] as? [[String: Any]] ?? []
        for row in rows where row["executable"] as? String == agent {
            if let pid = row["pid"] as? Int { kill(pid_t(pid), SIGTERM) }
        }
        NSLog("vphoned: icon store predates the GPU transport, removed it; icons are drawn again")
    }

    private static func birthTime(_ path: String) -> timespec? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status.st_birthtimespec
    }

    private static func isEarlier(_ a: timespec, than b: timespec) -> Bool {
        a.tv_sec != b.tv_sec ? a.tv_sec < b.tv_sec : a.tv_nsec < b.tv_nsec
    }
}
