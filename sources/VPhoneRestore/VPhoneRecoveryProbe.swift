import Foundation
import MobileRecoveryCore

// MARK: - VPhoneRecoveryMode

/// The USB product id a device in one of Apple's boot modes enumerates with —
/// libirecovery's `enum irecv_mode`.
///
/// A struct rather than an enum because an unrecognised mode must still be
/// reportable: the probe has a live handle by the time it reads this, and
/// throwing away a device because its mode is new helps nobody.
public struct VPhoneRecoveryMode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let recovery1 = VPhoneRecoveryMode(rawValue: 0x1280)
    public static let recovery2 = VPhoneRecoveryMode(rawValue: 0x1281)
    public static let recovery3 = VPhoneRecoveryMode(rawValue: 0x1282)
    public static let recovery4 = VPhoneRecoveryMode(rawValue: 0x1283)
    public static let wtf = VPhoneRecoveryMode(rawValue: 0x1222)
    public static let dfu = VPhoneRecoveryMode(rawValue: 0x1227)
    public static let portDFU = VPhoneRecoveryMode(rawValue: 0xF014)

    /// pymobiledevice3's `Mode.is_recovery`: everything that is not WTF and not
    /// DFU. Port DFU is not in its enum at all; it is a DFU variant, so it
    /// answers `false` here, and an unknown mode does too.
    public var isRecovery: Bool {
        (Self.recovery1.rawValue ... Self.recovery4.rawValue).contains(rawValue)
    }

    public var description: String {
        switch self {
        case .recovery1, .recovery2, .recovery3, .recovery4: "recovery"
        case .wtf: "WTF"
        case .dfu: "DFU"
        case .portDFU: "port DFU"
        default: String(format: "mode 0x%04X", rawValue)
        }
    }
}

// MARK: - VPhoneRecoveryDevice

/// What a successful probe found.
///
/// The Python bridge's `recovery-probe` returned nothing but an exit code, and
/// its one caller only ever tested that. This carries the identity too, because
/// the probe already has it open and an orchestrator that can print
/// "iPhone17,3 in DFU, ECID 0x…" is easier to debug than one that prints "ok".
public struct VPhoneRecoveryDevice: Sendable, Equatable {
    public let ecid: UInt64
    public let mode: VPhoneRecoveryMode
    public let chipID: UInt32
    public let boardID: UInt32
    public let serialNumber: String?
    public let productType: String?
    public let hardwareModel: String?
}

// MARK: - VPhoneRecoveryProbe

public enum VPhoneRecoveryProbe {
    /// Python's `wait_for_irecv`: poll once a second until `timeout` seconds
    /// have gone by, then give up. It never blocks longer than that, which is
    /// the whole point — `vm create` calls this ninety times in a row while it
    /// waits for a DFU boot to come up, and a probe that hung would hang the
    /// create.
    ///
    /// - Parameters:
    ///   - ecid: the device to wait for, or `nil` for the only one attached.
    ///   - timeout: seconds. `0` or less means the deadline is already past and
    ///     this throws without probing — Python's `while now < deadline` did
    ///     the same.
    ///   - isRecovery: `true` waits for recovery mode only, `false` for
    ///     DFU/WTF only, `nil` for either.
    @discardableResult
    public static func probe(
        ecid: UInt64?,
        timeout: Int,
        isRecovery: Bool? = nil,
    ) throws -> VPhoneRecoveryDevice {
        let deadline = DispatchTime.now() + .seconds(max(timeout, 0))
        while DispatchTime.now() < deadline {
            if let device = openOnce(ecid: ecid, isRecovery: isRecovery) {
                return device
            }
        }
        // Python's `mode_label`, bug and all: `"recovery" if is_recovery else
        // "dfu/recovery"` says "dfu/recovery" for None AND for False. Keeping
        // it means the message a user greps for has not changed.
        throw VPhoneRestoreBackendError.recoveryProbeTimedOut(
            mode: isRecovery == true ? "recovery" : "dfu/recovery",
        )
    }

    // MARK: One attempt

    /// One `irecv_open_with_ecid_and_attempts` with a single attempt.
    ///
    /// Single, because libirecovery sleeps a second itself after a failed
    /// attempt (`libirecovery.c:2238`) — that IS `wait_for_irecv`'s
    /// `time.sleep(1)`, and asking for more attempts would only move the poll
    /// loop's cadence inside a call that cannot see the deadline.
    private static func openOnce(ecid: UInt64?, isRecovery: Bool?) -> VPhoneRecoveryDevice? {
        var client: irecv_client_t?
        // 0 is libirecovery's "match whichever device is attached"
        // (`iokit_open_with_ecid`), which is what `ecid: nil` asks for.
        guard irecv_open_with_ecid_and_attempts(&client, ecid ?? 0, 1) == IRECV_E_SUCCESS,
              let client
        else {
            return nil
        }
        defer { irecv_close(client) }

        var rawMode: Int32 = 0
        guard irecv_get_mode(client, &rawMode) == IRECV_E_SUCCESS else { return nil }
        let mode = VPhoneRecoveryMode(rawValue: rawMode)

        if let isRecovery, mode.isRecovery != isRecovery {
            // The open SUCCEEDED, so libirecovery did not sleep — a device sat
            // in the wrong mode and will keep sitting there. Pace the loop
            // here instead, or this spins the USB stack flat out.
            Thread.sleep(forTimeInterval: 1)
            return nil
        }

        guard let info = irecv_get_device_info(client) else { return nil }
        let (productType, hardwareModel) = describeDevice(client)
        return VPhoneRecoveryDevice(
            ecid: info.pointee.ecid,
            mode: mode,
            chipID: UInt32(info.pointee.cpid),
            boardID: UInt32(info.pointee.bdid),
            serialNumber: info.pointee.srnm.map { String(cString: $0) },
            productType: productType,
            hardwareModel: hardwareModel,
        )
    }

    /// libirecovery's device table, which is how a CPID/BDID pair becomes
    /// "iPhone17,3". An unknown pair lands on the table's all-`NULL` sentinel,
    /// so the fields are read as optionals rather than trusted.
    private static func describeDevice(_ client: irecv_client_t) -> (String?, String?) {
        var device: irecv_device_t?
        guard irecv_devices_get_device_by_client(client, &device) == IRECV_E_SUCCESS,
              let device
        else {
            return (nil, nil)
        }
        return (
            device.pointee.product_type.map { String(cString: $0) },
            device.pointee.hardware_model.map { String(cString: $0) },
        )
    }
}
