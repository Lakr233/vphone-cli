import Foundation

// MARK: - VPhoneRestoreLayout

/// Where a restore's files sit inside a VM bundle.
///
/// Both rules here come from `scripts/pymobiledevice3_bridge.py` and both are
/// load-bearing: `vphone-cli restore --offline` and the
/// `vm create` orchestrator all find the `.shsh` by the name this produces.
public enum VPhoneRestoreLayout {
    // MARK: Restore directory

    /// Python's `find_restore_dir`: the ONE `iPhone*_Restore` directory in the
    /// bundle.
    ///
    /// Neither failure is defensive. None means `fw_prepare` has not run (or
    /// ran into a different bundle), and more than one means two firmware trees
    /// are sitting side by side — restoring from whichever sorted first would
    /// flash a build nobody chose.
    public static func findRestoreDirectory(in vmDir: URL) throws -> URL {
        let names = try restoreDirectoryNames(in: vmDir)
        guard let first = names.first else {
            throw VPhoneRestoreBackendError.noRestoreDirectory(vmDir)
        }
        guard names.count == 1 else {
            throw VPhoneRestoreBackendError.multipleRestoreDirectories(names)
        }
        return vmDir.appendingPathComponent(first, isDirectory: true)
    }

    /// The sorted names matching Python's `vm_dir.glob("iPhone*_Restore")`.
    ///
    /// `hasPrefix` + `hasSuffix` is the whole of that glob here, because no
    /// suffix of "iPhone" is a prefix of "_Restore" — the two literals cannot
    /// overlap, so any name satisfying both is at least "iPhone_Restore" long
    /// and `*` has something (possibly empty) to match.
    static func restoreDirectoryNames(in vmDir: URL) throws -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: vmDir.path)) ?? []

        return entries
            .filter { name in
                guard name.hasPrefix("iPhone"), name.hasSuffix("_Restore") else { return false }
                // `fileExists(atPath:isDirectory:)` stats through a symlink,
                // which is what Python's `p.is_dir()` did — a bundle that
                // points its restore tree at a shared firmware directory has
                // to keep working. `URLResourceValues.isDirectory` would NOT:
                // it answers for the link itself.
                var isDirectory: ObjCBool = false
                let exists = fm.fileExists(
                    atPath: vmDir.appendingPathComponent(name).path,
                    isDirectory: &isDirectory,
                )
                return exists && isDirectory.boolValue
            }
            .sorted()
    }

    // MARK: SHSH output

    /// Python's `derive_shsh_output`: `<ECID as %016X>.shsh` beside the bundle,
    /// or `auto.shsh` when the device never reported an ECID.
    ///
    /// The name is a contract, not a convenience — `VPhoneRestoreCommand`'s
    /// `--offline` path picks the first `*.shsh` in the bundle, and the
    /// `%016X` form is what sorts a per-device blob next to its VM.
    public static func shshOutput(vmDir: URL, ecid: UInt64?) -> URL {
        let tag = ecid.map(VPhoneRestoreIdentity.formatECID) ?? "auto"
        return vmDir.appendingPathComponent("\(tag).shsh", isDirectory: false)
    }
}
