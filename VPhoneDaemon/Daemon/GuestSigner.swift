import Darwin
import Foundation
import VPhoneSign

/// The native IPA installer prepares each executable's guest entitlements.
/// Sign them with the same bundled signer used by the host CLI, without a
/// package-manager supplied ldid executable inside the VM.
@_cdecl("vp_guest_sign_binary")
func vpGuestSignBinary(
    _ path: UnsafePointer<CChar>?,
    _ entitlementsPath: UnsafePointer<CChar>?,
    _ certificatePath: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let path else { return strdup("Missing executable path") }

    do {
        var options = VPhoneSignOptions()
        if let entitlementsPath {
            options.entitlements = try Data(
                contentsOf: URL(fileURLWithPath: String(cString: entitlementsPath)),
                options: .mappedIfSafe
            )
        } else {
            options.mergesExisting = true
        }
        if let certificatePath {
            options.mergesExisting = true
            options.identity = try VPhoneSignIdentity(
                pkcs12: Data(
                    contentsOf: URL(fileURLWithPath: String(cString: certificatePath)),
                    options: .mappedIfSafe
                ),
                password: ""
            )
        }
        try VPhoneSigner.sign(fileAt: URL(fileURLWithPath: String(cString: path)), options: options)
        return nil
    } catch {
        return strdup(String(describing: error))
    }
}
