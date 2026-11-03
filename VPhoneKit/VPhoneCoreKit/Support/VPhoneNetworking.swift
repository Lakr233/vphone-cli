import Foundation
import SystemConfiguration
import Virtualization

// MARK: - Errors

public enum VPhoneNetworkingError: Error, Equatable {
    /// hostOnly has no native Virtualization.framework attachment.
    case hostOnlyUnsupported
    case peerNATUnsupported
    /// A bridge interface was requested but no such interface exists on the host.
    case bridgeInterfaceNotFound(requested: String, available: [String])
    /// bridged mode was selected but the host exposes no bridgeable interfaces.
    case noBridgeInterfaces
    /// bridged mode was selected, no interface was named, and this process is
    /// not the one that can enumerate them.
    case bridgeInterfaceMustBeNamed
    /// `--bridge-interface` was given without selecting bridged mode.
    case bridgeInterfaceWithoutBridgedMode
    /// A field that must be a dotted IPv4 address is not one.
    case invalidAddress(field: String, value: String)
    case invalidPrefixLength(Int)
    /// The address is the subnet's network or broadcast address, or outside it.
    case addressNotAssignable(address: String, subnet: String)
    /// `nat` and `tunnel` hand out RFC 1918 space only.
    case addressNotPrivate(address: String, mode: String)
    case routerNotAssignable(router: String, subnet: String)
    case routerIsGuestAddress(String)
    /// On a vmnet network the host owns the gateway address; the guest cannot
    /// pick another one.
    case natRouterFixed(expected: String, subnet: String)
    /// A `nat` address has to be on the Mac's shared NAT network.
    case natAddressOffSharedNetwork(address: String, shared: String)
    case tooManyDNSServers(Int)
    /// `--gateway` or `--dns` was given while the address is left to DHCP.
    case settingWithoutAddress(String)
    case invalidMACAddress(String)
    case invalidPortForward(String)
    case duplicatePortForward(String)
    case portForwardNotFound(String)
    case portForwardUnsupported(mode: String)
    /// Not a usable mDNS host name label.
    case invalidLocalHostName(String)
}

extension VPhoneNetworkingError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .hostOnlyUnsupported:
            "Network mode 'hostOnly' is not supported. Use nat, bridged, tunnel, or none."
        case .peerNATUnsupported:
            "This macOS cannot let NAT machines reach each other. Set --nat-peers off and use an address on the isolated NAT network, or use bridged networking."
        case let .bridgeInterfaceNotFound(requested, available):
            "Bridge interface '\(requested)' not found. Available: \(available.isEmpty ? "none" : available.joined(separator: ", "))."
        case .noBridgeInterfaces:
            "Bridged mode needs a host network interface, but none are available. Use nat instead."
        case .bridgeInterfaceMustBeNamed:
            "Bridged mode requires an interface name because vphone-cli cannot list host interfaces. Pass one with --bridge-interface, for example --bridge-interface en0."
        case .bridgeInterfaceWithoutBridgedMode:
            "--bridge-interface is only valid with --network bridged."
        case let .invalidAddress(field, value):
            "'\(value)' is not a valid IPv4 address for \(field). Use the dotted form, for example 192.168.70.10."
        case let .invalidPrefixLength(length):
            "Prefix length \(length) is not supported. Use a value from 8 to 30, for example /24."
        case let .addressNotAssignable(address, subnet):
            "\(address) cannot be given to the guest on \(subnet): it is outside the subnet, or its network or broadcast address."
        case let .addressNotPrivate(address, mode):
            "\(address) is not a private address. \(mode) mode hands out 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16 only."
        case let .routerNotAssignable(router, subnet):
            "Gateway \(router) is not a usable address on \(subnet)."
        case let .routerIsGuestAddress(address):
            "The gateway and the guest cannot both be \(address)."
        case let .natRouterFixed(expected, subnet):
            "In nat mode the Mac is the gateway on \(subnet), at \(expected). Leave --gateway out, or set it to \(expected)."
        case let .natAddressOffSharedNetwork(address, shared):
            "\(address) is not on the Mac's shared NAT network \(shared), which nat mode uses for this machine (a machine that reaches the other NAT machines is on vmnet's second one; see --nat-peers). Pick an address on it, or use tunnel mode for another subnet."
        case let .tooManyDNSServers(count):
            "\(count) DNS servers is more than the guest takes. Give at most 4."
        case let .settingWithoutAddress(option):
            "\(option) needs a fixed address. Set one with --ip, for example --ip 192.168.65.50/24."
        case let .invalidMACAddress(value):
            "'\(value)' is not a usable MAC address. Use aa:bb:cc:dd:ee:ff with the multicast bit clear, or 'random'."
        case let .invalidPortForward(value):
            "'\(value)' is not a valid port forward. Use [tcp|udp:][host-address:]host-port:guest-port, for example tcp:8022:22."
        case let .duplicatePortForward(value):
            "Host port \(value) is forwarded more than once."
        case let .portForwardNotFound(value):
            "No port forward matches '\(value)'. Name it as listed by vm info, or by its host port."
        case let .portForwardUnsupported(mode):
            "Port forwarding works in nat and tunnel modes, not \(mode). Remove the forwards with --clear-forwards, or choose nat or tunnel."
        case let .invalidLocalHostName(name):
            "'\(name)' cannot be an mDNS name. Use 1 to 63 letters, digits and hyphens, not starting or ending with a hyphen, or 'on' for the VM's own name."
        }
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - Host

/// What the host contributes to a network plan, separated out so tests can
/// describe a host other than the one they run on.
public struct VPhoneNetworkHost: Equatable, Sendable {
    /// The shared network vmnet runs for `VZNATNetworkDeviceAttachment`.
    public var sharedNATSubnet: VPhoneIPv4Subnet
    /// The Mac's own address on it: the guest's gateway and DNS proxy.
    public var sharedNATHost: VPhoneIPv4Address

    public init(sharedNATSubnet: VPhoneIPv4Subnet, sharedNATHost: VPhoneIPv4Address) {
        self.sharedNATSubnet = sharedNATSubnet
        self.sharedNATHost = sharedNATHost
    }

    /// The network vmnet runs for the machines that reach each other
    /// (`reachesPeers`): a NAT attachment without interface isolation joins a
    /// second shared network, the block right after the first one (192.168.65.0/24
    /// beside 192.168.64.0/24), with the Mac at its first host.
    public var peerNATSubnet: VPhoneIPv4Subnet {
        VPhoneIPv4Subnet(containing: VPhoneIPv4Address(sharedNATSubnet.broadcast.raw &+ 1), prefixLength: sharedNATSubnet.prefixLength)
            ?? sharedNATSubnet
    }

    public var peerNATHost: VPhoneIPv4Address {
        peerNATSubnet.firstHost
    }

    /// The network a `nat` guest is on, and the Mac's address there.
    public func natNetwork(reachesPeers: Bool) -> (subnet: VPhoneIPv4Subnet, host: VPhoneIPv4Address) {
        reachesPeers ? (peerNATSubnet, peerNATHost) : (sharedNATSubnet, sharedNATHost)
    }

    /// vmnet's own default, used unless the host's preferences move it.
    public static let defaultSharedNATHost = VPhoneIPv4Address(192, 168, 64, 1)

    /// This Mac. The shared network can be moved with `Shared_Net_Address`
    /// and `Shared_Net_Mask` in vmnet's preferences, so they are read rather
    /// than assumed.
    public static var current: VPhoneNetworkHost {
        let plist = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist")
        let values = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let host = (values?["Shared_Net_Address"] as? String).flatMap(VPhoneIPv4Address.init(dotted:))
            ?? defaultSharedNATHost
        let mask = (values?["Shared_Net_Mask"] as? String).flatMap(VPhoneIPv4Address.init(dotted:))
            ?? VPhoneIPv4Address(255, 255, 255, 0)
        let subnet = VPhoneIPv4Subnet(containing: host, mask: mask)
            ?? VPhoneIPv4Subnet(containing: host, prefixLength: 24)!
        return VPhoneNetworkHost(sharedNATSubnet: subnet, sharedNATHost: host)
    }
}

// MARK: - Guest IPv4

/// What vphoned should leave the guest's `en0` configured as.
public enum VPhoneGuestIPv4Setting: Equatable, Sendable, CustomStringConvertible {
    /// DHCP. Only undoes a manual configuration vphoned set itself; one the
    /// user made inside the guest is left alone.
    case dhcp
    case manual(address: VPhoneIPv4Address, subnet: VPhoneIPv4Subnet, router: VPhoneIPv4Address, dns: [VPhoneIPv4Address])

    /// The parameters of vphoned's `network.ipv4.set`.
    public var parameters: [String: Any] {
        switch self {
        case .dhcp:
            ["method": "dhcp"]
        case let .manual(address, subnet, router, dns):
            [
                "method": "manual",
                "address": address.description,
                "subnet_mask": subnet.mask.description,
                "router": router.description,
                "dns": dns.map(\.description),
            ]
        }
    }

    public var description: String {
        switch self {
        case .dhcp:
            "dhcp"
        case let .manual(address, subnet, router, dns):
            "\(address)/\(subnet.prefixLength) via \(router) dns \(dns.map(\.description).joined(separator: ","))"
        }
    }
}

// MARK: - Plan

/// Everything boot needs to build the guest's network, decided from the
/// manifest without touching Virtualization so it can be tested.
public struct VPhoneNetworkPlan: Equatable, Sendable {
    public typealias PortForward = VPhoneVirtualMachineManifest.NetworkConfig.PortForward

    public enum Attachment: Equatable, Sendable {
        case none
        /// `VZNATNetworkDeviceAttachment`, the Mac's shared vmnet network.
        case sharedNAT
        case bridged(interface: String)
        case tunnel(VPhoneUserspaceNetworkConfiguration)
    }

    public let attachment: Attachment
    /// Nil leaves the MAC to Virtualization.
    public let macAddress: VPhoneMACAddress?
    /// Nil when there is no NIC to configure.
    public let guestIPv4: VPhoneGuestIPv4Setting?
    public let portForwards: [PortForward]
    /// The guest's mDNS name, without `.local`; nil leaves the guest's own.
    /// The guest announces it in every mode, `none` included: besides its
    /// NIC it has the virtual iPhone's USB network link to the Mac (`en1` in
    /// the guest, a 169.254 address on the Mac), where mDNS runs too.
    public let localHostName: String?
    /// Whether vphoned registers this Mac's `.local` name with the guest's
    /// mDNSResponder, pointing at `macAddressForGuest`.
    public let resolvesMacName: Bool
    /// In `nat`: whether the guest and the other machines on the shared
    /// network reach each other (vmnet's interface isolation off).
    public var reachesPeers = false
    /// The address the guest reaches this Mac at: the shared network's host
    /// address in `nat`, the gateway in `tunnel` (which carries it to the
    /// Mac's loopback). Nil in `bridged`, where it is the Mac's address on the
    /// bridged interface and only known at boot, and without a NIC.
    public let macAddressForGuest: VPhoneIPv4Address?
    /// Where forwarded ports go in `nat`: the fixed address, or nil to use
    /// whatever the guest reports. In `tunnel` the guest's lease.
    public let forwardingAddress: VPhoneIPv4Address?
}

// MARK: - Edits

/// A partial change to a `NetworkConfig`, as `vm config` and Launchpad make
/// it. Nil fields are left as they are.
public struct VPhoneNetworkEdit: Equatable, Sendable {
    public typealias NetworkMode = VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode
    public typealias PortForward = VPhoneVirtualMachineManifest.NetworkConfig.PortForward

    public enum MACChange: Equatable, Sendable {
        /// Clear it; the next boot generates and saves a new one.
        case automatic
        /// Generate a new one now.
        case random
        case fixed(String)
    }

    public enum AddressChange: Equatable, Sendable {
        case dhcp
        case fixed(address: String, prefixLength: Int)
    }

    public var mode: NetworkMode?
    public var bridgeInterface: String?
    public var mac: MACChange?
    public var address: AddressChange?
    /// `.some(nil)` returns the gateway to its default.
    public var router: String??
    /// `.some(nil)` returns DNS to its default.
    public var dns: [String]??
    /// `.some(nil)` stops managing the guest's mDNS name.
    public var localHostName: String??
    /// Turn the guest's local record for the Mac's name on or off.
    public var resolvesMacName: Bool?
    /// Let the guest reach the other machines on the shared network, or not.
    public var reachesPeers: Bool?
    public var addForwards: [PortForward]
    /// Forwards to drop, named as `vm info` lists them or by host port.
    public var removeForwards: [String]
    public var clearForwards: Bool

    public init(
        mode: NetworkMode? = nil,
        bridgeInterface: String? = nil,
        mac: MACChange? = nil,
        address: AddressChange? = nil,
        router: String?? = nil,
        dns: [String]?? = nil,
        localHostName: String?? = nil,
        resolvesMacName: Bool? = nil,
        reachesPeers: Bool? = nil,
        addForwards: [PortForward] = [],
        removeForwards: [String] = [],
        clearForwards: Bool = false,
    ) {
        self.mode = mode
        self.bridgeInterface = bridgeInterface
        self.mac = mac
        self.address = address
        self.router = router
        self.dns = dns
        self.localHostName = localHostName
        self.resolvesMacName = resolvesMacName
        self.reachesPeers = reachesPeers
        self.addForwards = addForwards
        self.removeForwards = removeForwards
        self.clearForwards = clearForwards
    }

    public var isEmpty: Bool {
        self == VPhoneNetworkEdit()
    }
}

// MARK: - Networking helpers

/// Host-side helpers for validating and realizing a VM's `NetworkConfig`.
/// Shared between config-time editing (`VPhoneBundleOperations.updateConfig`) and boot-time
/// device construction so both agree on validation and interface resolution.
public enum VPhoneNetworking {
    public typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig
    public typealias NetworkMode = NetworkConfig.NetworkMode
    public typealias IPv4Config = NetworkConfig.IPv4Config
    public typealias PortForward = NetworkConfig.PortForward

    /// More than iOS keeps, and more than one DHCP option carries comfortably.
    static let maximumDNSServers = 4

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

        // An empty list is ambiguous: either the host really has nothing
        // bridgeable, or this process is not entitled to ask. Since vphone-cli
        // deliberately carries no entitlements, the second case is now the
        // normal one, and rejecting a perfectly good interface name on the
        // strength of a list we know is unreliable would break bridged mode
        // outright. So when we cannot enumerate, we record what we were told
        // and let vphone-vm — which is entitled — decide at boot, where the
        // error can name the real problem.
        guard !available.isEmpty else {
            if let requested {
                return requested
            }
            if let current {
                return current
            }
            throw VPhoneNetworkingError.bridgeInterfaceMustBeNamed
        }

        if let requested {
            guard available.contains(requested) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(requested: requested, available: available)
            }
            return requested
        }
        if let current, available.contains(current) {
            return current
        }
        return available[0] // non-empty, guarded above
    }

    // MARK: - Parsing

    /// `192.168.70.10/24`, or a bare address, which means /24.
    public static func parseAddress(_ text: String) throws -> (address: String, prefixLength: Int) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = parts.first.flatMap({ VPhoneIPv4Address(dotted: String($0)) }) else {
            throw VPhoneNetworkingError.invalidAddress(field: "--ip", value: text)
        }
        guard parts.count == 2 else { return (address.description, 24) }
        guard let length = Int(parts[1]) else {
            throw VPhoneNetworkingError.invalidAddress(field: "--ip", value: text)
        }
        return (address.description, length)
    }

    /// `[tcp|udp:][host-address:]host-port:guest-port`.
    public static func parsePortForward(_ text: String) throws -> PortForward {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var transport = PortForward.TransportProtocol.tcp
        if let first = parts.first, let named = PortForward.TransportProtocol(rawValue: first.lowercased()) {
            transport = named
            parts.removeFirst()
        }
        var hostAddress: String?
        if parts.count == 3 {
            guard let address = VPhoneIPv4Address(dotted: parts[0]) else {
                throw VPhoneNetworkingError.invalidPortForward(text)
            }
            hostAddress = address.description
            parts.removeFirst()
        }
        guard parts.count == 2,
              let hostPort = Int(parts[0]), (1 ... 65535).contains(hostPort),
              let guestPort = Int(parts[1]), (1 ... 65535).contains(guestPort)
        else {
            throw VPhoneNetworkingError.invalidPortForward(text)
        }
        return PortForward(transport: transport, hostAddress: hostAddress, hostPort: hostPort, guestPort: guestPort)
    }

    /// The canonical spelling of a MAC, or an error naming the value.
    public static func normalizeMACAddress(_ text: String) throws -> String {
        guard let mac = VPhoneMACAddress(string: text), mac.isUnicast, !mac.isZero, mac != .gateway else {
            throw VPhoneNetworkingError.invalidMACAddress(text)
        }
        return mac.description
    }

    // MARK: - mDNS names

    /// The mDNS name `--mdns on` gives a VM: its name with everything but
    /// letters and digits turned into hyphens, as a DNS label allows.
    public static func localHostName(forVMName name: String) -> String {
        var label = ""
        for scalar in name.unicodeScalars {
            let allowed = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if allowed {
                label.unicodeScalars.append(scalar)
            } else if !label.hasSuffix("-") {
                label += "-"
            }
        }
        label = String(label.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return label.isEmpty ? "vphone" : label
    }

    /// `name`, if it is one DNS label: 1 to 63 letters, digits and hyphens,
    /// with no hyphen at either end. A trailing `.local` is dropped.
    public static func validLocalHostName(_ name: String) throws -> String {
        let label = name.lowercased().hasSuffix(".local") ? String(name.dropLast(6)) : name
        let allowed = label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        guard (1 ... 63).contains(label.count), allowed, !label.hasPrefix("-"), !label.hasSuffix("-") else {
            throw VPhoneNetworkingError.invalidLocalHostName(name)
        }
        return label
    }

    // MARK: - The Mac's name in the guest

    /// A name vphoned has the guest resolve locally (`GuestStaticNames`).
    public struct StaticName: Equatable, Sendable {
        public let address: VPhoneIPv4Address
        public let names: [String]

        /// As vphoned's `network.static_names.set` takes it.
        public var parameters: [String: Any] {
            ["address": address.description, "names": names]
        }
    }

    /// This Mac's mDNS name, as `scutil --get LocalHostName` prints it.
    public static func macLocalHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    /// The first IPv4 address of a host interface, for `bridged`.
    public static func ipv4Address(ofInterface name: String) -> VPhoneIPv4Address? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var entry = list
        while let interface = entry {
            defer { entry = interface.pointee.ifa_next }
            guard String(cString: interface.pointee.ifa_name) == name,
                  let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return VPhoneIPv4Address(UInt32(bigEndian: raw))
        }
        return nil
    }

    /// The names vphoned should have the guest resolve locally: this Mac's
    /// `<LocalHostName>.local` at the address the guest reaches it at. Empty
    /// when the plan does not resolve the Mac's name or no address is known,
    /// which withdraws them.
    ///
    /// Over mDNS alone an IPv4 lookup of the Mac's name can fail: the guest
    /// also hears the Mac on the virtual iPhone's USB link, where the Mac has
    /// no IPv4 address and answers "no such record", and the fastest answer
    /// wins. See Research/Host/network_fixed_address.md.
    public static func macStaticNames(
        plan: VPhoneNetworkPlan,
        macName: String?,
        bridgedAddress: VPhoneIPv4Address? = nil,
    ) -> [StaticName] {
        guard plan.resolvesMacName, let macName, !macName.isEmpty,
              let address = plan.macAddressForGuest ?? bridgedAddress
        else { return [] }
        return [StaticName(address: address, names: ["\(macName).local"])]
    }

    // MARK: - Editing

    /// Merge partial edits onto an existing config, validating the result.
    /// A nil argument leaves that field unchanged.
    public static func merge(
        into current: NetworkConfig,
        mode: NetworkMode?,
        bridgeInterface: String?,
        resolvesMacName: Bool? = nil,
    ) throws -> NetworkConfig {
        try merge(
            into: current,
            edit: VPhoneNetworkEdit(mode: mode, bridgeInterface: bridgeInterface, resolvesMacName: resolvesMacName),
        )
    }

    public static func merge(
        into current: NetworkConfig,
        edit: VPhoneNetworkEdit,
        host: VPhoneNetworkHost = .current,
    ) throws -> NetworkConfig {
        let newMode = edit.mode ?? current.mode
        if newMode == .hostOnly {
            throw VPhoneNetworkingError.hostOnlyUnsupported
        }
        let newBridge: String?
        if newMode == .bridged {
            newBridge = try resolveBridgeInterface(requested: edit.bridgeInterface, current: current.bridgeInterface)
        } else {
            if edit.bridgeInterface != nil {
                throw VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode
            }
            newBridge = current.bridgeInterface
        }

        let mac: String = switch edit.mac {
        case nil: current.macAddress
        case .automatic: ""
        case .random: VPhoneMACAddress.randomLocallyAdministered().description
        case let .fixed(value): try normalizeMACAddress(value)
        }

        var ipv4 = current.ipv4
        switch edit.address {
        case nil:
            break
        case .dhcp:
            ipv4 = nil
        case let .fixed(address, prefixLength):
            // A gateway or resolver chosen for the old subnet means nothing on
            // a new one, so they follow the address only while it stays put.
            let sameSubnet = ipv4.map { old in
                old.prefixLength == prefixLength
                    && subnet(of: old.address, prefixLength) == subnet(of: address, prefixLength)
            } ?? false
            ipv4 = IPv4Config(
                address: address,
                prefixLength: prefixLength,
                router: sameSubnet ? ipv4?.router : nil,
                dns: sameSubnet ? ipv4?.dns : nil,
            )
        }
        // Returning either to its default (`auto`) changes nothing without a
        // fixed address; naming one needs the address.
        if let router = edit.router {
            if let base = ipv4 {
                ipv4 = IPv4Config(address: base.address, prefixLength: base.prefixLength, router: router, dns: base.dns)
            } else if router != nil {
                throw VPhoneNetworkingError.settingWithoutAddress("--gateway")
            }
        }
        if let dns = edit.dns {
            let servers = dns.flatMap { $0.isEmpty ? nil : $0 }
            if let base = ipv4 {
                ipv4 = IPv4Config(address: base.address, prefixLength: base.prefixLength, router: base.router, dns: servers)
            } else if servers != nil {
                throw VPhoneNetworkingError.settingWithoutAddress("--dns")
            }
        }

        var forwards = edit.clearForwards ? [] : current.portForwards ?? []
        for name in edit.removeForwards {
            let before = forwards.count
            forwards.removeAll { forward in
                forward.description == name
                    || String(forward.hostPort) == name
                    || name == "\(forward.transport.rawValue):\(forward.hostPort)"
                    || (try? parsePortForward(name)) == forward
            }
            if forwards.count == before {
                throw VPhoneNetworkingError.portForwardNotFound(name)
            }
        }
        // Asking again for a forward that is already there changes nothing.
        for forward in edit.addForwards where !forwards.contains(forward) {
            forwards.append(forward)
        }

        let merged = try NetworkConfig(
            mode: newMode,
            macAddress: mac,
            bridgeInterface: newBridge,
            ipv4: ipv4,
            portForwards: forwards.isEmpty ? nil : forwards,
            localHostName: edit.localHostName.map { try $0.map(validLocalHostName) } ?? current.localHostName,
            // On is the default, so it is stored as an absent key.
            resolvesMacName: edit.resolvesMacName.map { $0 ? nil : false } ?? current.resolvesMacName,
            // Stored as set: its default depends on the address.
            reachesPeers: edit.reachesPeers ?? current.reachesPeers,
        )
        try validate(merged, host: host)
        return merged
    }

    private static func subnet(of address: String, _ prefixLength: Int) -> VPhoneIPv4Subnet? {
        VPhoneIPv4Address(dotted: address).flatMap { VPhoneIPv4Subnet(containing: $0, prefixLength: prefixLength) }
    }

    // MARK: - Validation

    /// The guest's addressing once defaults are filled in.
    struct ResolvedIPv4: Equatable {
        let address: VPhoneIPv4Address
        let subnet: VPhoneIPv4Subnet
        let router: VPhoneIPv4Address
        /// Empty when none were configured, which each mode reads its own way.
        let dns: [VPhoneIPv4Address]
    }

    /// Whether `cfg` fixes the guest's address on the first shared network.
    /// Such a machine keeps the isolation it was configured under unless it
    /// asks to reach its peers: those are on vmnet's second shared network,
    /// where its address does not exist.
    static func hasFixedSharedAddress(_ cfg: NetworkConfig, host: VPhoneNetworkHost) -> Bool {
        guard let address = cfg.ipv4.flatMap({ VPhoneIPv4Address(dotted: $0.address) }) else { return false }
        return host.sharedNATSubnet.contains(address)
    }

    /// Whether a `nat` guest of `cfg` reaches the other NAT machines.
    public static func reachesPeers(_ cfg: NetworkConfig, host: VPhoneNetworkHost = .current) -> Bool {
        cfg.mode == .nat && (cfg.reachesPeers ?? !hasFixedSharedAddress(cfg, host: host))
    }

    static func resolve(_ ipv4: IPv4Config, mode: NetworkMode, host: VPhoneNetworkHost, reachesPeers: Bool = false) throws -> ResolvedIPv4 {
        guard let address = VPhoneIPv4Address(dotted: ipv4.address) else {
            throw VPhoneNetworkingError.invalidAddress(field: "the guest address", value: ipv4.address)
        }
        guard (8 ... 30).contains(ipv4.prefixLength),
              let subnet = VPhoneIPv4Subnet(containing: address, prefixLength: ipv4.prefixLength)
        else {
            throw VPhoneNetworkingError.invalidPrefixLength(ipv4.prefixLength)
        }
        guard subnet.isAssignable(address) else {
            throw VPhoneNetworkingError.addressNotAssignable(address: ipv4.address, subnet: subnet.description)
        }
        if mode == .nat || mode == .tunnel, !subnet.isPrivate {
            throw VPhoneNetworkingError.addressNotPrivate(address: ipv4.address, mode: mode.rawValue)
        }

        // `nat` stays on the Mac's shared network, the one
        // `VZNATNetworkDeviceAttachment` uses, where the Mac is the gateway. A
        // vmnet network of the VM's own (`vmnet_network_create`, macOS 26)
        // would allow any subnet, but InternetSharing keeps such a subnet
        // reserved after the VM process exits, and later launches on it fail
        // (still 40 minutes on); see Research/Host/network_fixed_address.md.
        // A guest that reaches its peers is on vmnet's second shared network.
        var defaultRouter = subnet.firstHost
        if mode == .nat {
            let network = host.natNetwork(reachesPeers: reachesPeers)
            guard subnet == network.subnet else {
                throw VPhoneNetworkingError.natAddressOffSharedNetwork(
                    address: ipv4.address,
                    shared: network.subnet.description,
                )
            }
            defaultRouter = network.host
        }

        let router: VPhoneIPv4Address
        if let text = ipv4.router {
            guard let parsed = VPhoneIPv4Address(dotted: text) else {
                throw VPhoneNetworkingError.invalidAddress(field: "the gateway", value: text)
            }
            router = parsed
        } else {
            router = defaultRouter
        }
        if mode == .nat, router != defaultRouter {
            throw VPhoneNetworkingError.natRouterFixed(expected: defaultRouter.description, subnet: subnet.description)
        }
        guard subnet.isAssignable(router) else {
            throw VPhoneNetworkingError.routerNotAssignable(router: router.description, subnet: subnet.description)
        }
        guard router != address else {
            throw VPhoneNetworkingError.routerIsGuestAddress(address.description)
        }

        let dnsText = ipv4.dns ?? []
        guard dnsText.count <= maximumDNSServers else {
            throw VPhoneNetworkingError.tooManyDNSServers(dnsText.count)
        }
        let dns = try dnsText.map { text in
            guard let server = VPhoneIPv4Address(dotted: text) else {
                throw VPhoneNetworkingError.invalidAddress(field: "DNS", value: text)
            }
            return server
        }
        return ResolvedIPv4(address: address, subnet: subnet, router: router, dns: dns)
    }

    /// Throws when `cfg` cannot be realized on `host`. Runs when a config is
    /// edited and again at boot, because a hand-edited or imported
    /// `config.plist` reaches boot without going through an edit.
    public static func validate(_ cfg: NetworkConfig, host: VPhoneNetworkHost = .current) throws {
        _ = try plan(cfg, host: host)
    }

    static func validatePortForwards(_ forwards: [PortForward], mode: NetworkMode) throws {
        guard !forwards.isEmpty else { return }
        guard mode == .nat || mode == .tunnel else {
            throw VPhoneNetworkingError.portForwardUnsupported(mode: mode == .off ? "none" : mode.rawValue)
        }
        var seen: [PortForward] = []
        for forward in forwards {
            guard (1 ... 65535).contains(forward.hostPort), (1 ... 65535).contains(forward.guestPort),
                  forward.hostAddress.map({ VPhoneIPv4Address(dotted: $0) != nil }) ?? true
            else {
                throw VPhoneNetworkingError.invalidPortForward(forward.description)
            }
            // Two listeners on one port clash when either takes every address.
            let clash = seen.contains { other in
                other.transport == forward.transport && other.hostPort == forward.hostPort
                    && (other.listenAddress == forward.listenAddress
                        || other.listenAddress == "0.0.0.0" || forward.listenAddress == "0.0.0.0")
            }
            if clash {
                throw VPhoneNetworkingError.duplicatePortForward("\(forward.transport.rawValue):\(forward.hostPort)")
            }
            seen.append(forward)
        }
    }

    // MARK: - Planning

    /// Decide how `cfg` is realized on `host`.
    ///
    /// The fixed address reaches the guest one of two ways. `tunnel` serves it
    /// over its own DHCP, so the guest stays on DHCP. Everywhere else the host
    /// has no say in the DHCP server, so vphoned writes the address into the
    /// guest's network preferences (`guestIPv4`).
    public static func plan(_ cfg: NetworkConfig, host: VPhoneNetworkHost = .current) throws -> VPhoneNetworkPlan {
        if cfg.mode == .hostOnly {
            throw VPhoneNetworkingError.hostOnlyUnsupported
        }
        let mac: VPhoneMACAddress? = cfg.macAddress.isEmpty
            ? nil
            : try VPhoneMACAddress(string: normalizeMACAddress(cfg.macAddress))
        let reachesPeers = reachesPeers(cfg, host: host)
        let resolved = try cfg.ipv4.map { try resolve($0, mode: cfg.mode, host: host, reachesPeers: reachesPeers) }
        let forwards = cfg.portForwards ?? []
        try validatePortForwards(forwards, mode: cfg.mode)
        let localHostName = try cfg.localHostName.map(validLocalHostName)
        let resolvesMacName = cfg.resolvesMacName ?? true

        func manual(_ ipv4: ResolvedIPv4) -> VPhoneGuestIPv4Setting {
            .manual(
                address: ipv4.address,
                subnet: ipv4.subnet,
                router: ipv4.router,
                dns: ipv4.dns.isEmpty ? [ipv4.router] : ipv4.dns,
            )
        }

        switch cfg.mode {
        case .hostOnly:
            throw VPhoneNetworkingError.hostOnlyUnsupported

        case .off:
            return VPhoneNetworkPlan(attachment: .none, macAddress: nil, guestIPv4: nil, portForwards: [], localHostName: localHostName,
                                     resolvesMacName: false, macAddressForGuest: nil, forwardingAddress: nil)

        case .nat:
            let natHost = host.natNetwork(reachesPeers: reachesPeers).host
            guard let resolved else {
                return VPhoneNetworkPlan(
                    attachment: .sharedNAT, macAddress: mac, guestIPv4: .dhcp,
                    portForwards: forwards, localHostName: localHostName,
                    resolvesMacName: resolvesMacName, reachesPeers: reachesPeers,
                    macAddressForGuest: natHost, forwardingAddress: nil,
                )
            }
            return VPhoneNetworkPlan(
                attachment: .sharedNAT, macAddress: mac, guestIPv4: manual(resolved),
                portForwards: forwards, localHostName: localHostName,
                resolvesMacName: resolvesMacName, reachesPeers: reachesPeers,
                macAddressForGuest: natHost, forwardingAddress: resolved.address,
            )

        case .bridged:
            guard let interface = cfg.bridgeInterface else {
                throw VPhoneNetworkingError.noBridgeInterfaces
            }
            return VPhoneNetworkPlan(
                attachment: .bridged(interface: interface), macAddress: mac,
                guestIPv4: resolved.map(manual) ?? .dhcp, portForwards: [], localHostName: localHostName,
                resolvesMacName: resolvesMacName, macAddressForGuest: nil, forwardingAddress: nil,
            )

        case .tunnel:
            let configuration = resolved.map {
                VPhoneUserspaceNetworkConfiguration(
                    hostAddress: $0.router,
                    guestAddress: $0.address,
                    prefixLength: $0.subnet.prefixLength,
                    dnsServers: $0.dns,
                )
            } ?? .default
            return VPhoneNetworkPlan(
                attachment: .tunnel(configuration), macAddress: mac, guestIPv4: .dhcp,
                portForwards: forwards, localHostName: localHostName,
                resolvesMacName: resolvesMacName, macAddressForGuest: configuration.hostAddress, forwardingAddress: configuration.guestAddress,
            )
        }
    }

    // MARK: - Devices

    /// The guest's NIC and whatever has to outlive it.
    public struct NetworkDevice {
        /// Nil for `.off`: no NIC at all.
        public let configuration: VZVirtioNetworkDeviceConfiguration?
        /// Non-nil only for `.tunnel`, where the network is implemented in this
        /// process. Its sockets live as long as the last holder, so the caller
        /// must keep it for the whole time the VM runs, and `start()` it once
        /// the VM does.
        public let userspaceNetwork: VPhoneUserspaceNetwork?
    }

    /// vmnet isolates each guest on the shared network from the others, and
    /// Virtualization has no public switch for it. A VM with isolation off
    /// shares the bridge with the others without its private flag, so they
    /// reach each other directly (Bonjour included). A Virtualization without
    /// the private setter cannot realize the peer network; fail before boot
    /// rather than use the isolated network with the peer network's addresses.
    static func setInterfaceIsolation(_ enabled: Bool, of attachment: VZNATNetworkDeviceAttachment) throws {
        let selector = NSSelectorFromString("_setInterfaceIsolationEnabled:")
        guard attachment.responds(to: selector), let method = class_getInstanceMethod(type(of: attachment), selector) else {
            throw VPhoneNetworkingError.peerNATUnsupported
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(attachment, selector, enabled)
    }

    /// Build the VZ network device for a config, or nil for `.off` (no NIC).
    /// Throws if the config cannot be realized (missing bridge interface, hostOnly).
    public static func makeNetworkDevice(_ cfg: NetworkConfig) throws
        -> (device: VZVirtioNetworkDeviceConfiguration?, backend: VPhoneUserspaceNetwork?)
    {
        let device = try makeNetworkDevice(plan(cfg))
        return (device.configuration, device.userspaceNetwork)
    }

    public static func makeNetworkDevice(_ plan: VPhoneNetworkPlan) throws -> NetworkDevice {
        let attachment: VZNetworkDeviceAttachment
        var userspaceNetwork: VPhoneUserspaceNetwork?

        switch plan.attachment {
        case .none:
            return NetworkDevice(configuration: nil, userspaceNetwork: nil)
        case .sharedNAT:
            let nat = VZNATNetworkDeviceAttachment()
            if plan.reachesPeers {
                try setInterfaceIsolation(false, of: nat)
            }
            attachment = nat
        case let .tunnel(configuration):
            let network = try VPhoneUserspaceNetwork(configuration: configuration)
            userspaceNetwork = network
            attachment = network.networkAttachment
        case let .bridged(id):
            guard let iface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == id }) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(
                    requested: id,
                    available: availableBridgeInterfaces(),
                )
            }
            attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
        }

        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = attachment
        if let mac = plan.macAddress, let address = VZMACAddress(string: mac.description) {
            device.macAddress = address
        }
        return NetworkDevice(configuration: device, userspaceNetwork: userspaceNetwork)
    }
}
