import Foundation
import IcliKit
import VphonedNative

extension GuestAPI {
    /// `executeInterface` holds `interfaceLock` around this: AX enable/restore is process-wide.
    /// The foreground is verified once, before the native call.
    static func executeElement(_ m: InterfaceMethod, _ params: [String: Any]) throws -> [String: Any] {
        let operation: GuestElementRequest.Operation = switch m {
        case .uiElementActivate: .activate
        case .uiElementFocus: .focus
        case .uiElementSetValue: .setValue
        default: .attributes
        }
        let request = try GuestElementRequest.build(operation, params)
        let pid = try verifiedForeground().pid
        let native = vp_ax_element(Int32(pid), request.selector, request.operation)
        return try GuestElementRequest.result(native as? [String: Any])
    }
}
