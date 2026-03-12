import Foundation
import MobileRestoreCore

enum VPhoneIRecovery {
    static func sendDFUFile(path: String, ecid: UInt64?) throws {
        try sendFile(
            path: path,
            ecid: ecid,
            mode: Int32(VPHONE_IRECV_MODE_DFU),
            options: UInt32(VPHONE_IRECV_SEND_OPT_DFU_NOTIFY_FINISH),
            action: "DFU file transfer"
        )
    }

    static func sendRecoveryFile(path: String, ecid: UInt64?) throws {
        try sendFile(
            path: path,
            ecid: ecid,
            mode: Int32(VPHONE_IRECV_MODE_RECOVERY),
            options: 0,
            action: "recovery file transfer"
        )
    }

    static func sendRecoveryCommand(_ command: String, ecid: UInt64?) throws {
        let result = command.withCString { commandPtr in
            vphone_irecv_send_command(
                commandPtr,
                ecid ?? 0,
                ecid == nil ? 0 : 1,
                Int32(VPHONE_IRECV_MODE_RECOVERY)
            )
        }
        try requireSuccess(result, action: "recovery command '\(command)'")
    }

    static func waitForRecovery(ecid: UInt64?, timeout: TimeInterval = 20) throws {
        let milliseconds = max(Int(timeout * 1000.0), 0)
        let result = vphone_irecv_wait_for_mode(
            ecid ?? 0,
            ecid == nil ? 0 : 1,
            Int32(VPHONE_IRECV_MODE_RECOVERY),
            Int32(milliseconds)
        )
        try requireSuccess(result, action: "wait for recovery mode")
    }
}

private extension VPhoneIRecovery {
    static func sendFile(
        path: String,
        ecid: UInt64?,
        mode: Int32,
        options: UInt32,
        action: String
    ) throws {
        let result = path.withCString { pathPtr in
            vphone_irecv_send_file(
                pathPtr,
                ecid ?? 0,
                ecid == nil ? 0 : 1,
                mode,
                options
            )
        }
        try requireSuccess(result, action: action)
    }

    static func requireSuccess(_ result: Int32, action: String) throws {
        guard result == 0 else {
            let detail: String
            if let errorPtr = vphone_irecv_error_string(result) {
                detail = String(cString: errorPtr)
            } else {
                detail = "unknown error"
            }
            throw VPhoneHostError.invalidArgument("\(action) failed: \(detail) (\(result))")
        }
    }
}
