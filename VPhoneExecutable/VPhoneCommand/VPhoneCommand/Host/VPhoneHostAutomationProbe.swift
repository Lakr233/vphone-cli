import Foundation
import VPhoneCoreKit

/// vphoned RPCs through a running VM's control socket, `vphone.sock`.
enum VPhoneHostAutomationProbe {
    static func rpc(_ method: String, params: [String: Any], socketPath: String, timeout: Int) throws -> [String: Any] {
        try VPhoneControlSocket.rpc(method, params: params, socketPath: socketPath, timeout: timeout)
    }
}
