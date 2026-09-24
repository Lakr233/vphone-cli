import Foundation
import Testing
@testable import VPhoneRestore

/// `VPhoneRestoreOptions` -> `struct vphone_restore_options`.
///
/// This is the boundary where a wrong field is silent: `erase` and `shsh_only`
/// are adjacent bools, a `NULL` `udid` means "any device" while an empty string
/// means "a device called ''", and nothing downstream would complain.
struct RestoreOptionsTests {
    // MARK: - Fixtures

    /// The C struct, read while its strings are still alive.
    private struct Snapshot {
        var restoreDir: String?
        var cacheDir: String?
        var udid: String?
        var ticketPath: String?
        var ecid: UInt64
        var erase: Bool
        var shshOnly: Bool
        var keepPers: Bool
        var debugLevel: Int32
        var hasLogCallback: Bool
        var hasProgressCallback: Bool
        var hasContext: Bool
    }

    private func snapshot(_ options: VPhoneRestoreOptions) -> Snapshot {
        options.withCOptions { c in
            Snapshot(
                restoreDir: c.restore_dir.map { String(cString: $0) },
                cacheDir: c.cache_dir.map { String(cString: $0) },
                udid: c.udid.map { String(cString: $0) },
                ticketPath: c.ticket_path.map { String(cString: $0) },
                ecid: c.ecid,
                erase: c.erase,
                shshOnly: c.shsh_only,
                keepPers: c.keep_pers,
                debugLevel: c.debug_level,
                hasLogCallback: c.log_cb != nil,
                hasProgressCallback: c.progress_cb != nil,
                hasContext: c.context != nil,
            )
        }
    }

    // MARK: - Mapping

    @Test func `every field reaches the C struct`() {
        let options = VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/vm/iPhone17,3_Restore"),
            cacheDirectory: URL(fileURLWithPath: "/tmp/cache"),
            udid: "ABCDEF01-0001020304050607",
            ecid: 0x0000_0001_1A2B_3C4D,
            erase: true,
            ticketPath: URL(fileURLWithPath: "/tmp/vm/000000011A2B3C4D.shsh"),
            shshOnly: false,
            keepPers: true,
            debugLevel: 2,
        )
        let c = snapshot(options)
        #expect(c.restoreDir == "/tmp/vm/iPhone17,3_Restore")
        #expect(c.cacheDir == "/tmp/cache")
        #expect(c.udid == "ABCDEF01-0001020304050607")
        #expect(c.ticketPath == "/tmp/vm/000000011A2B3C4D.shsh")
        #expect(c.ecid == 0x0000_0001_1A2B_3C4D)
        #expect(c.erase)
        #expect(!c.shshOnly)
        #expect(c.keepPers)
        #expect(c.debugLevel == 2)
    }

    @Test func `absent optionals become null not empty strings`() {
        // A `udid` of "" is a device whose UDID is the empty string, which
        // matches nothing; NULL is "whichever device is attached".
        let options = VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/vm/iPhone17,3_Restore"),
        )
        let c = snapshot(options)
        #expect(c.cacheDir == nil)
        #expect(c.udid == nil)
        #expect(c.ticketPath == nil)
    }

    @Test func `defaults are an online erase restore`() {
        // Which is what `restore-update` did with no flags: Behavior.Erase,
        // a ticket from Apple, no debug logging.
        let c = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/vm/iPhone17,3_Restore"),
        ))
        #expect(c.erase)
        #expect(c.ecid == 0)
        #expect(!c.shshOnly)
        #expect(!c.keepPers)
        #expect(c.debugLevel == 0)
        #expect(c.ticketPath == nil)
    }

    @Test func `update in place clears erase`() {
        // pymobiledevice3's Behavior.Update, the bridge's `--no-erase`.
        let c = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/vm/iPhone17,3_Restore"),
            erase: false,
        ))
        #expect(!c.erase)
    }

    @Test func `erase and shsh only are independent`() {
        // The SHSH fetch asks for an ERASE ticket and stops before the device;
        // both bits are set, and swapping them would fetch the wrong blob.
        let c = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/vm/iPhone17,3_Restore"),
            erase: true,
            shshOnly: true,
        ))
        #expect(c.erase)
        #expect(c.shshOnly)
    }

    @Test func `callback fields are left for the runner`() {
        // `withCOptions` maps the data only; `VPhoneRestoreRunner` installs the
        // function pointers and the context on its own copy.
        let c = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/vm/iPhone17,3_Restore"),
        ))
        #expect(!c.hasLogCallback)
        #expect(!c.hasProgressCallback)
        #expect(!c.hasContext)
    }

    @Test func `paths are taken from the URL not its description`() {
        // A URL's description is "file:///…"; its `path` is what a C API wants.
        let c = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/a space/iPhone17,3_Restore"),
        ))
        #expect(c.restoreDir == "/tmp/a space/iPhone17,3_Restore")
    }

    // MARK: - Storage lifetime

    @Test func `each call gets its own storage`() {
        // `withCOptions` frees its strings on the way out, so two snapshots
        // taken separately must not alias — a stale pointer here would be a
        // use-after-free inside idevicerestore.
        let first = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/one/iPhone17,3_Restore"),
        ))
        let second = snapshot(VPhoneRestoreOptions(
            restoreDirectory: URL(fileURLWithPath: "/tmp/two/iPhone17,3_Restore"),
        ))
        #expect(first.restoreDir == "/tmp/one/iPhone17,3_Restore")
        #expect(second.restoreDir == "/tmp/two/iPhone17,3_Restore")
    }

    @Test func `nested calls do not clobber each other`() {
        let outer = VPhoneRestoreOptions(restoreDirectory: URL(fileURLWithPath: "/tmp/outer"))
        let inner = VPhoneRestoreOptions(restoreDirectory: URL(fileURLWithPath: "/tmp/inner"))
        let pair = outer.withCOptions { outerC in
            inner.withCOptions { innerC in
                (
                    outerC.restore_dir.map { String(cString: $0) },
                    innerC.restore_dir.map { String(cString: $0) },
                )
            }
        }
        #expect(pair.0 == "/tmp/outer")
        #expect(pair.1 == "/tmp/inner")
    }
}
