import Darwin
import Foundation

/// Drops libMobileGestalt's cache when it is older than the device tree the
/// guest booted.
///
/// libMobileGestalt works most of its answers out from the device tree, and at
/// first boot it writes them to a cache on the Data volume. Every process
/// answers from that file from then on, so a guest whose Preboot device tree
/// was changed later keeps answering as the old tree did: after `cfw
/// update-environment` removed `/product/haptics`, Settings still showed the
/// Haptics row and tones stayed silent. With the file gone, the answers are
/// worked out again from the tree the guest booted.
///
/// The host cannot do this. The Data volume is a FileVault volume whose keys
/// are in the guest's SEP; a host that attaches the disk sees it locked and
/// cannot mount it. So vphoned does it here, at startup.
///
/// The rule is about age, not about any one answer. The host changes the tree
/// only with the VM stopped, and writes it only when a repair changed it, so a
/// cache older than the tree's modification time was worked out from an older
/// tree. One written after it was written by a boot of this tree. That covers
/// every tree repair — the haptics removal, the board audio node — and needs
/// no state: an existing guest's first-boot cache is older than the tree
/// `update-environment` just rewrote, a new guest's tree is written before its
/// first boot, and the cache rebuilt after a drop is newer than the tree.
///
/// Processes that have read the cache keep its answers until they exit, so a
/// drop takes full effect at the next boot. vphoned never restarts the guest
/// for it; `/v1/health` reports `mobilegestalt_restart_pending` until then.
///
/// See Research/Guest/virtio_sound.md §7.
enum GuestMobileGestaltCache {
    static let cachePath =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
    /// The Preboot volume. The tree the guest boots is
    /// `<boot manifest hash>/usr/standalone/firmware/devicetree.img4` in it,
    /// the same file `cfw install` and `cfw update-environment` patch.
    private static let preboot = "/private/preboot"
    /// The boot session in which vphoned dropped the cache, so that a vphoned
    /// restarted in the same boot (`agent.apply_update`) still reports it.
    private static let dropMarker = "/var/root/Library/Caches/com.vphone.vphoned.mobilegestalt-dropped"

    // MARK: - Startup

    static func dropIfStaleOnStartup() {
        guard let cache = modificationTime(cachePath) else { return }
        let trees = (try? FileManager.default.contentsOfDirectory(atPath: preboot))?
            .map { "\(preboot)/\($0)/usr/standalone/firmware/devicetree.img4" }
            .filter { modificationTime($0) != nil } ?? []
        guard trees.count == 1, let tree = modificationTime(trees[0]) else {
            NSLog("vphoned: MobileGestalt cache: found %ld device trees in %@, left the cache alone", trees.count, preboot)
            return
        }
        guard isEarlier(cache, than: tree) else { return }
        guard unlink(cachePath) == 0 || errno == ENOENT else {
            NSLog("vphoned: MobileGestalt cache: cannot remove %@: %@", cachePath, String(cString: strerror(errno)))
            return
        }
        if let session = bootSession() {
            try? Data(session.utf8).write(to: URL(fileURLWithPath: dropMarker), options: .atomic)
        }
        NSLog("vphoned: MobileGestalt cache predates the device tree, removed it; a restart makes the new answers take effect")
    }

    /// True when vphoned dropped the cache during this boot: the guest has
    /// not restarted since, and still answers some questions from the old tree.
    static func restartPending() -> Bool {
        guard let session = bootSession(),
              let marker = FileManager.default.contents(atPath: dropMarker)
        else { return false }
        return String(decoding: marker, as: UTF8.self) == session
    }

    // MARK: - Helpers

    /// A regular file's modification time; nil for anything else or nothing.
    private static func modificationTime(_ path: String) -> timespec? {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return status.st_mtimespec
    }

    private static func isEarlier(_ a: timespec, than b: timespec) -> Bool {
        a.tv_sec != b.tv_sec ? a.tv_sec < b.tv_sec : a.tv_nsec < b.tv_nsec
    }

    private static func bootSession() -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var size = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
