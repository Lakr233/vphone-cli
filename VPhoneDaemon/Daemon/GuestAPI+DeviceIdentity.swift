import Darwin
import Foundation
import VphonedNative

// MARK: - Profile UDID

enum DeviceIdentityMethod: String, GuestMethod {
    case udidGet = "udid.get"
    case udidSet = "udid.set"
    case udidClear = "udid.clear"

    var spec: MethodSpec {
        switch self {
        case .udidGet: MethodSpec(summary: "Read the UDID override the guest reports to provisioning checks and the host, or null if none.", result: [.required("path", .any), .required("udid", .any)])
        case .udidSet: MethodSpec(.required("udid", .string, "UDID to present, stored as sent with no format check"), summary: "Set the guest UDID override, restart UDID-reading daemons and re-enumerate USB so the host sees it.", result: [.required("path", .any), .required("restarted_pids", .any), .required("udid", .any), .required("usb_reenumerated", .boolean), .required("usb_serial", .string)])
        case .udidClear: MethodSpec(summary: "Remove the UDID override so the guest reports its own, restarting daemons and re-enumerating USB.", result: [.required("path", .any), .required("restarted_pids", .any), .required("udid", .any), .required("usb_reenumerated", .boolean), .required("usb_serial", .string)])
        }
    }
}

/// The UDID the guest gives: to the hooked daemons checking a provisioning
/// profile's `ProvisionedDevices`, and to the host through lockdownd, remoted
/// and the USB serial string (`VPhoneGuestComponents/MISFix/MISFixDeviceIdentity.c`
/// has the three routes). TXM and the kernel keep the guest's own.
///
/// The hook reads the first of two files that exists and re-reads it when its
/// modification time or size changes. vphoned owns the data-volume file.
/// Clearing keeps that file with the key removed rather than deleting it:
/// the file then still comes first, so a UDID left in the `/usr/lib` copy
/// cannot take over again.
///
/// A change also stops every daemon that carries the hook, so the next check
/// runs in a fresh process that has cached nothing, and takes the USB device
/// off the bus and back, which relaunches remoted and makes the host read the
/// identity again. launchd starts the rest on demand.
///
/// That means installd as well as misagent, and it used to mean only misagent.
/// The reason given was that installd "asks misagent", and it does not: a
/// lockdown-path install runs
/// `+[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]`
/// inside installd, which calls `MISValidateSignatureAndCopyInfo` and evaluates
/// the profile's `ProvisionedDevices` itself. Two processes answer the UDID
/// question independently — which is why the spawn hooks insert libmisfix into
/// both — so refreshing one and not the other leaves them disagreeing.
///
/// Measured on test-26.4 (2026-09-30): with the override changed to a UDID in
/// the profile and only misagent restarted, `_installEmbeddedProfilesWithError:`
/// passed and installd then failed the same install with `0xE8008015`, "A valid
/// provisioning profile for this executable was not found", because installd was
/// still holding the previous UDID from before the change.
///
/// Stopping installd can abort an install already in flight. That is the lesser
/// evil: changing the device's identity underneath a running install is
/// incoherent anyway, whereas leaving one of the two evaluators on a stale
/// answer fails later, somewhere else, with an error that does not mention the
/// UDID at all.
extension GuestAPI {
    /// Must match `kConfigPaths` in `MISFixConfig.c`, in the same order.
    static let udidConfigPaths = ["/var/db/vphone/misfix.plist", "/usr/lib/libmisfix.plist"]
    static let udidConfigKey = "UniqueDeviceID"

    /// The daemons libmisfix is inserted into, and so the ones holding a UDID
    /// answer that a change has to invalidate. Keep in step with
    /// `vpIsMISFixTarget` in `VPhoneGuestComponents/Shared/InjectionEnvironment.h`,
    /// bar SpringBoard: it carries the hook for the launch check alone, never
    /// asks for the UDID, and stopping it would take the home screen down with it.
    static let udidHookedDaemons = ["misagent", "installd", "lockdownd", "remoted"]

    static func executeDeviceIdentity(_ m: DeviceIdentityMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .udidGet:
            udidState()
        case .udidSet:
            // Stored exactly as sent, with no format check: the API is also
            // for probing what misagent does with an unusual value. The VM
            // window's menu is what holds a person to a real UDID's shape.
            try applyUDID(string(params, "udid"))
        case .udidClear:
            try applyUDID(nil)
        }
    }

    /// Writes the setting, reads it back the way the hook resolves it, and
    /// restarts every daemon that carries the hook.
    private static func applyUDID(_ udid: String?) throws -> [String: Any] {
        try writeUDIDConfiguration(udid)
        var state = udidState()
        guard state["path"] as? String == udidConfigPaths[0], state["udid"] as? String == udid else {
            throw GuestAPIError.operationFailed("\(udidConfigPaths[0]) did not read back as written")
        }
        // SIGKILL: remoted runs with EnableTransactions and outlives a SIGTERM.
        state["restarted_pids"] = udidHookedDaemons.flatMap { stopProcesses(named: $0, signal: SIGKILL) }
        // Always off the bus and back, even for an unchanged serial: that is
        // what launches remoted again (its launch event is the NCM link coming
        // up), and what makes the host ask lockdown who this is once more.
        let usb = try applyUSBSerial(udid, reenumerate: true)
        state["usb_serial"] = usb.serial
        state["usb_reenumerated"] = usb.changed
        return state
    }

    /// Shows the host `udid` — or the guest's own UDID when nil — as the USB
    /// serial string, which is where usbmuxd, and so `idevice_id`, gets it.
    /// The dashes go, as on a real device: usbmuxd puts one back after the
    /// eighth character of a 24-character serial. Returns the serial in effect and
    /// whether the device went off the bus to show it.
    @discardableResult
    static func applyUSBSerial(_ udid: String?, reenumerate: Bool = false) throws -> (serial: String, changed: Bool) {
        let serial: String
        if let udid {
            serial = udid.replacingOccurrences(of: "-", with: "")
        } else {
            guard let own = vp_usb_own_serial() else {
                throw GuestAPIError.operationFailed("/chosen has no chip-id or unique-chip-id")
            }
            serial = String(cString: own)
            free(own)
        }
        var changed = false
        if let error = vp_usb_set_serial(serial, reenumerate, &changed) {
            defer { free(error) }
            throw GuestAPIError.operationFailed(String(cString: error))
        }
        return (serial, changed)
    }

    /// Puts a configured UDID back on the USB serial after a boot or a vphoned
    /// restart; the kernel starts from the guest's own every time. A guest with
    /// no override is left untouched.
    ///
    /// vphoned starts before the USB device exists, and until it does the
    /// controller has no description to change (measured on test-27.0). So this
    /// retries in the background, every two seconds for five minutes, until the
    /// serial is set.
    static func restoreUSBSerialOnStartup(attempt: Int = 0) {
        guard let udid = udidState()["udid"] as? String else { return }
        do {
            let usb = try applyUSBSerial(udid)
            NSLog("vphoned: USB serial %@ after %d retries", usb.serial, attempt)
        } catch {
            guard attempt < 150 else {
                NSLog("vphoned: USB serial not set: %@", String(describing: error))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                restoreUSBSerialOnStartup(attempt: attempt + 1)
            }
        }
    }

    /// The UDID the hook answers with and the file it comes from, resolved the
    /// way `MISFixCopyConfiguredDeviceIdentifier` resolves it. `udid` is null
    /// when the guest answers with its own.
    private static func udidState() -> [String: Any] {
        guard let path = udidConfigPaths.first(where: { access($0, F_OK) == 0 }) else {
            return ["udid": NSNull(), "path": NSNull()]
        }
        let udid = (readUDIDConfiguration(path)?[udidConfigKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ["udid": udid ?? NSNull(), "path": path]
    }

    private static func readUDIDConfiguration(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Replaces the data-volume file in one rename, which is what the hook's
    /// mtime check expects. Other keys in the file are kept.
    private static func writeUDIDConfiguration(_ udid: String?) throws {
        guard let path = udidConfigPaths.first else { return }
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755],
            )
        } catch {
            throw GuestAPIError.operationFailed("Could not create \(directory): \(error.localizedDescription)")
        }
        var configuration = readUDIDConfiguration(path) ?? [:]
        configuration[udidConfigKey] = udid
        do {
            // Binary, so any string the caller sends survives the round trip;
            // XML cannot carry every control character.
            let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw GuestAPIError.operationFailed("Could not write \(path): \(error.localizedDescription)")
        }
        // World-readable: the hook only ever reads, and this file has to be
        // reachable from whatever uid each hooked daemon runs under.
        chmod(path, 0o644)
    }
}
