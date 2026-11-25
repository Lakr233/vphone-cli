import Foundation
import VPhoneCoreKit

/// vphoned RPCs through a running VM's control socket, `vphone.sock`.
enum VPhoneHostAutomationProbe {
    /// One vphoned RPC through the VM process. A refusal from vphoned carries
    /// its error object as `detail`; anything else is a transport failure.
    static func rpc(_ method: String, params: [String: Any], socketPath: String, timeout: Int) throws -> [String: Any] {
        let request: [String: Any] = ["t": "rpc", "method": method, "params": params, "screen": false]
        guard let reply = VPhoneControlSocket.send(request, socketPath: socketPath, timeout: timeout, maximumReply: 64 << 20) else {
            throw VPhoneGuestCallError(kind: .transport, message: "no answer from vphone.sock")
        }
        if reply["ok"] as? Bool == true {
            return reply["result"] as? [String: Any] ?? [:]
        }
        let message = reply["error"] as? String ?? "refused"
        if let detail = reply["guest_error"] as? [String: Any] {
            throw VPhoneGuestCallError(kind: .refused, message: message, detail: detail)
        }
        // The VM answered for the guest: not connected yet, or the request
        // to vphoned failed on the way.
        throw VPhoneGuestCallError(kind: .notConnected, message: message)
    }
}
