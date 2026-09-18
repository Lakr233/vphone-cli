import Foundation
import Virtualization

// MARK: - Errors

public enum VPhoneNetworkingError: Error, Equatable {
    /// hostOnly has no native Virtualization.framework attachment.
    case hostOnlyUnsupported
    /// A bridge interface was requested but no such interface exists on the host.
    case bridgeInterfaceNotFound(requested: String, available: [String])
    /// bridged mode was selected but the host exposes no bridgeable interfaces.
    case noBridgeInterfaces
    /// `--bridge-interface` was given without selecting bridged mode.
    case bridgeInterfaceWithoutBridgedMode
    /// `tunnel` mode pins to a helper process, so it needs a session, not a bare device.
    case tunnelModeNeedsSession
}

extension VPhoneNetworkingError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .hostOnlyUnsupported:
            "network mode 'hostOnly' is not supported (Virtualization.framework has no host-only attachment); use nat, bridged, or none"
        case let .bridgeInterfaceNotFound(requested, available):
            "bridge interface '\(requested)' not found; available: \(available.isEmpty ? "(none)" : available.joined(separator: ", "))"
        case .noBridgeInterfaces:
            "bridged mode requires a host interface, but none are available for bridging"
        case .bridgeInterfaceWithoutBridgedMode:
            "--bridge-interface is only valid with --network bridged"
        case .tunnelModeNeedsSession:
            """
            network mode 'tunnel' is backed by a helper process; build it with \
            VPhoneNetworking.makeNetworkSession(_:) rather than makeNetworkDevice(_:)
            """
        }
    }
    public var errorDescription: String? { description }
}

// MARK: - Networking helpers

/// Host-side helpers for validating and realizing a VM's `NetworkConfig`.
/// Shared between config-time editing (`VPhoneBundleOps.updateConfig`) and boot-time
/// device construction so both agree on validation and interface resolution.
public enum VPhoneNetworking {
    public typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig
    public typealias NetworkMode = NetworkConfig.NetworkMode

    /// Identifiers of host interfaces available for bridging (empty without the
    /// `com.apple.vm.networking` entitlement, e.g. in unsigned test binaries).
    public static func availableBridgeInterfaces() -> [String] {
        VZBridgedNetworkInterface.networkInterfaces.map(\.identifier)
    }

    /// Resolve the concrete bridge interface to persist for bridged mode.
    /// - `requested`: an explicit `--bridge-interface`, validated against the host.
    /// - `current`: the interface already stored on the bundle, kept if still present.
    /// - otherwise the first available interface is auto-picked.
    public static func resolveBridgeInterface(requested: String?, current: String?) throws -> String {
        let available = availableBridgeInterfaces()
        if let requested {
            guard available.contains(requested) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(requested: requested, available: available)
            }
            return requested
        }
        if let current, available.contains(current) {
            return current
        }
        guard let first = available.first else {
            throw VPhoneNetworkingError.noBridgeInterfaces
        }
        return first
    }

    /// Merge partial edits onto an existing config, validating the result.
    /// A nil argument leaves that field unchanged.
    public static func merge(
        into current: NetworkConfig,
        mode: NetworkMode?,
        bridgeInterface: String?
    ) throws -> NetworkConfig {
        let newMode = mode ?? current.mode
        if newMode == .hostOnly {
            throw VPhoneNetworkingError.hostOnlyUnsupported
        }
        let newBridge: String?
        if newMode == .bridged {
            newBridge = try resolveBridgeInterface(requested: bridgeInterface, current: current.bridgeInterface)
        } else {
            if bridgeInterface != nil {
                throw VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode
            }
            newBridge = current.bridgeInterface
        }
        return NetworkConfig(mode: newMode, macAddress: current.macAddress, bridgeInterface: newBridge)
    }

    /// Build the VZ network device for a config, or nil for `.off` (no NIC).
    /// The MAC is left framework-assigned; a forced MAC breaks guest networking.
    /// Throws if the config cannot be realized (missing bridge interface, hostOnly).
    ///
    /// `.tunnel` cannot be realized without a helper process — use `makeNetworkSession`.
    public static func makeNetworkDevice(_ cfg: NetworkConfig) throws -> VZVirtioNetworkDeviceConfiguration? {
        switch cfg.mode {
        case .off:
            return nil
        case .hostOnly:
            throw VPhoneNetworkingError.hostOnlyUnsupported
        case .tunnel:
            throw VPhoneNetworkingError.tunnelModeNeedsSession
        case .nat:
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            return net
        case .bridged:
            guard let id = cfg.bridgeInterface else {
                throw VPhoneNetworkingError.noBridgeInterfaces
            }
            guard let iface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == id }) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(
                    requested: id, available: availableBridgeInterfaces())
            }
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
            return net
        }
    }

    /// Realize `cfg` for a boot. Unlike `makeNetworkDevice`, this also starts whatever
    /// host-side helper the mode needs, and returns a session that owns that lifetime.
    /// Callers must `stop()` the session when the VM goes away.
    public static func makeNetworkSession(
        _ cfg: NetworkConfig,
        tunnelNetworkOptions: VPhoneTunnelNetwork.Options = .default
    ) throws -> VPhoneNetworkSession {
        guard cfg.mode == .tunnel else {
            return VPhoneNetworkSession(mode: cfg.mode, device: try makeNetworkDevice(cfg))
        }
        let network = VPhoneTunnelNetwork(options: tunnelNetworkOptions)
        let device = VZVirtioNetworkDeviceConfiguration()
        do {
            device.attachment = try network.start()
        } catch {
            network.stop()
            throw error
        }
        return VPhoneNetworkSession(mode: .tunnel, device: device, tunnelNetwork: network)
    }
}

// MARK: - Session

/// A realized network backend for one boot: the device to attach into the VM
/// configuration plus anything that has to be torn down with it. Today only
/// `tunnel` mode owns a host process; the other modes are device-only.
public final class VPhoneNetworkSession {
    public typealias NetworkMode = VPhoneNetworking.NetworkConfig.NetworkMode

    public let mode: NetworkMode
    /// NIC for `VZVirtualMachineConfiguration.networkDevices`; nil for `.off`.
    public let device: VZVirtioNetworkDeviceConfiguration?
    private let tunnelNetwork: VPhoneTunnelNetwork?

    init(mode: NetworkMode, device: VZVirtioNetworkDeviceConfiguration?, tunnelNetwork: VPhoneTunnelNetwork? = nil) {
        self.mode = mode
        self.device = device
        self.tunnelNetwork = tunnelNetwork
    }

    /// Idempotent: terminates a helper process and removes its sockets.
    public func stop() {
        tunnelNetwork?.stop()
    }

    deinit {
        stop()
    }
}
