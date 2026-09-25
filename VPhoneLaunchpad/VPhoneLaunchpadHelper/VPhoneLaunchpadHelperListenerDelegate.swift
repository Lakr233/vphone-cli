import Foundation

/// Accepts only connections from a process that satisfies the same
/// requirement SMJobBless used to authorize the installer: the app's
/// identifier, signed by the same team.
final class VPhoneLaunchpadHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = Self.clientRequirement() else {
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VPhoneLaunchpadHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneLaunchpadHelperClientProtocol.self)
        connection.exportedObject = VPhoneLaunchpadHelperService(connection: connection)
        connection.resume()
        return true
    }

    /// The first SMAuthorizedClients entry of the helper's embedded
    /// Info.plist. Reusing it keeps one requirement string for both checks.
    static func clientRequirement() -> String? {
        let clients = Bundle.main.object(forInfoDictionaryKey: "SMAuthorizedClients") as? [String]
        return clients?.first
    }
}
