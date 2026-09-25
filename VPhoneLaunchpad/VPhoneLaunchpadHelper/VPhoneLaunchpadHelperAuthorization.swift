import Foundation
import Security

/// Per-user authorization for every privileged verb. The XPC code-signing
/// requirement only proves the caller is vphone-launchpad; it says nothing
/// about which user runs it. Each verb therefore also needs the caller's
/// AuthorizationRef to hold `VPhoneLaunchpadHelperIdentity.privilegedRight`,
/// which only an administrator can obtain.
enum VPhoneLaunchpadHelperAuthorization {
    private static let right = VPhoneLaunchpadHelperIdentity.privilegedRight

    private static let comment = "Used by vphone-launchpad to run its privileged helper as root."

    /// Anyone may add a right that does not exist yet (`config.add.` is
    /// `allow`), so the rule is written as root on every start, replacing
    /// whatever is there. Only root or an administrator can modify it later.
    private static var definition: [String: Any] {
        [
            "class": "user",
            "group": "admin",
            "authenticate-user": true,
            "timeout": 300,
            "shared": false,
            "version": 1,
            "comment": comment,
        ]
    }

    // MARK: - Rule

    @discardableResult
    static func registerRight() -> Bool {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else {
            return false
        }
        defer { AuthorizationFree(authorization, []) }
        let status = AuthorizationRightSet(
            authorization,
            right,
            definition as CFDictionary,
            comment as CFString,
            nil,
            nil,
        )
        return status == errAuthorizationSuccess
    }

    /// True when the stored rule still asks for an administrator with no
    /// shared credential.
    private static func ruleIsIntact() -> Bool {
        var stored: CFDictionary?
        guard AuthorizationRightGet(right, &stored) == errAuthorizationSuccess,
              let rule = stored as? [String: Any]
        else { return false }
        return rule["class"] as? String == "user"
            && rule["group"] as? String == "admin"
            && rule["authenticate-user"] as? Bool != false
            && rule["shared"] as? Bool == false
            && (rule["timeout"] as? Int).map { $0 <= 300 } == true
            && rule["rule"] == nil
            && rule["allow-root"] as? Bool != true
    }

    // MARK: - Check

    /// Throws unless `external` is an AuthorizationExternalForm whose
    /// authorization holds the privileged right, prompting through the
    /// caller's session when its credential has expired.
    static func require(_ external: Data) throws {
        guard ruleIsIntact() || (registerRight() && ruleIsIntact()) else {
            throw VPhoneLaunchpadHelperError("The helper's authorization rule has been changed. Reinstall the helper, then try again.")
        }
        guard external.count == Int(kAuthorizationExternalFormLength) else {
            throw VPhoneLaunchpadHelperError("The request did not include administrator authorization.")
        }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form.bytes) { external.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        var status = AuthorizationCreateFromExternalForm(&form, &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw VPhoneLaunchpadHelperError("The request's administrator authorization is not valid.")
        }
        defer { AuthorizationFree(authorization, []) }

        status = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            throw VPhoneLaunchpadHelperError(
                status == errAuthorizationCanceled
                    ? "Administrator authorization was canceled."
                    : "This action needs an administrator. Enter an administrator's name and password, then try again.",
            )
        }
    }
}
