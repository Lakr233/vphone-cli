import Foundation
import Testing
import Virtualization
@testable import VPhoneCoreKit

/// Editing, validating and planning a VM's network: fixed addresses, MACs and
/// port forwards, per mode and per host.
struct NetworkPlanTests {
    typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig
    typealias IPv4Config = NetworkConfig.IPv4Config
    typealias PortForward = NetworkConfig.PortForward

    private static let sharedSubnet = VPhoneIPv4Subnet(containing: VPhoneIPv4Address(192, 168, 64, 1), prefixLength: 24)!
    private let host = VPhoneNetworkHost(sharedNATSubnet: sharedSubnet, sharedNATHost: VPhoneIPv4Address(192, 168, 64, 1))

    private func config(_ mode: NetworkConfig.NetworkMode, ip: IPv4Config? = nil, forwards: [PortForward]? = nil, mac: String = "") -> NetworkConfig {
        NetworkConfig(mode: mode, macAddress: mac, bridgeInterface: mode == .bridged ? "en0" : nil, ipv4: ip, portForwards: forwards)
    }

    // MARK: - Parsing

    @Test func `addresses parse with and without a prefix`() throws {
        #expect(try VPhoneNetworking.parseAddress("192.168.64.50") == ("192.168.64.50", 24))
        #expect(try VPhoneNetworking.parseAddress("10.0.5.9/16") == ("10.0.5.9", 16))
        #expect(throws: VPhoneNetworkingError.self) { _ = try VPhoneNetworking.parseAddress("192.168.64") }
        #expect(throws: VPhoneNetworkingError.self) { _ = try VPhoneNetworking.parseAddress("192.168.64.5/x") }
    }

    @Test func `port forwards parse in every spelling`() throws {
        #expect(try VPhoneNetworking.parsePortForward("8022:22") == PortForward(hostPort: 8022, guestPort: 22))
        #expect(try VPhoneNetworking.parsePortForward("udp:5353:53") == PortForward(transport: .udp, hostPort: 5353, guestPort: 53))
        #expect(
            try VPhoneNetworking.parsePortForward("tcp:0.0.0.0:8080:80")
                == PortForward(transport: .tcp, hostAddress: "0.0.0.0", hostPort: 8080, guestPort: 80),
        )
        #expect(try VPhoneNetworking.parsePortForward("8022:22").description == "tcp:127.0.0.1:8022:22")
        for bad in ["22", "tcp:0:22", "tcp:8022:70000", "sctp:1:2", "x.y:1:2"] {
            #expect(throws: VPhoneNetworkingError.self) { _ = try VPhoneNetworking.parsePortForward(bad) }
        }
    }

    @Test func `MAC addresses are normalized and screened`() throws {
        #expect(try VPhoneNetworking.normalizeMACAddress("02-AA-bb-0C-dd-EE") == "02:aa:bb:0c:dd:ee")
        // Multicast, all zero, malformed, and the tunnel gateway's own.
        for bad in ["01:00:5e:00:00:01", "00:00:00:00:00:00", "02:aa:bb", "02:00:00:00:00:01"] {
            #expect(throws: VPhoneNetworkingError.self) { _ = try VPhoneNetworking.normalizeMACAddress(bad) }
        }
        let random = VPhoneMACAddress.randomLocallyAdministered()
        #expect(random.isUnicast)
        #expect(random.bytes[0] & 0x02 == 0x02)
    }

    @Test func `subnets know their edges`() throws {
        let subnet = try #require(VPhoneIPv4Subnet(containing: VPhoneIPv4Address(10, 1, 2, 3), prefixLength: 16))
        #expect(subnet.description == "10.1.0.0/16")
        #expect(subnet.mask == VPhoneIPv4Address(255, 255, 0, 0))
        #expect(subnet.broadcast == VPhoneIPv4Address(10, 1, 255, 255))
        #expect(subnet.firstHost == VPhoneIPv4Address(10, 1, 0, 1))
        #expect(!subnet.isAssignable(subnet.network))
        #expect(!subnet.isAssignable(subnet.broadcast))
        #expect(subnet.isPrivate)
        #expect(VPhoneIPv4Subnet(containing: VPhoneIPv4Address(8, 8, 8, 8), prefixLength: 24)?.isPrivate == false)
        #expect(VPhoneIPv4Subnet(containing: .any, mask: VPhoneIPv4Address(255, 0, 255, 0)) == nil)
    }

    // MARK: - nat

    /// On the shared network the guest keeps the shared gateway, and vphoned
    /// is asked to hold the address; no network of its own is needed.
    @Test func `a nat address on the shared network is set in the guest`() throws {
        let plan = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "192.168.64.50", prefixLength: 24)), host: host)
        #expect(plan.attachment == .sharedNAT)
        #expect(plan.forwardingAddress == VPhoneIPv4Address(192, 168, 64, 50))
        guard case let .manual(address, subnet, router, dns) = plan.guestIPv4 else {
            Issue.record("expected a manual setting, got \(String(describing: plan.guestIPv4))")
            return
        }
        #expect(address == VPhoneIPv4Address(192, 168, 64, 50))
        #expect(subnet.mask == VPhoneIPv4Address(255, 255, 255, 0))
        #expect(router == VPhoneIPv4Address(192, 168, 64, 1))
        #expect(dns == [router])
    }

    /// Only the shared network: a subnet of the VM's own stays reserved after
    /// the VM exits, so it would work for one launch. A machine that reaches
    /// its peers is held to vmnet's second shared network.
    @Test func `a nat address off the shared network is refused`() {
        #expect(throws: VPhoneNetworkingError.natAddressOffSharedNetwork(address: "192.168.70.10", shared: "192.168.65.0/24")) {
            _ = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "192.168.70.10", prefixLength: 24)), host: host)
        }
        #expect(throws: VPhoneNetworkingError.natAddressOffSharedNetwork(address: "192.168.64.50", shared: "192.168.64.0/24")) {
            _ = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "192.168.64.50", prefixLength: 16)), host: host)
        }
    }

    /// A Mac whose shared network was moved in vmnet's preferences.
    @Test func `a moved shared network is followed`() throws {
        let moved = try VPhoneNetworkHost(
            sharedNATSubnet: #require(VPhoneIPv4Subnet(containing: VPhoneIPv4Address(10, 0, 5, 1), prefixLength: 24)),
            sharedNATHost: VPhoneIPv4Address(10, 0, 5, 1),
        )
        let plan = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "10.0.5.20", prefixLength: 24)), host: moved)
        guard case let .manual(_, _, router, _) = plan.guestIPv4 else {
            Issue.record("expected a manual setting")
            return
        }
        #expect(router == VPhoneIPv4Address(10, 0, 5, 1))
    }

    @Test func `nat refuses a gateway the host does not hold`() {
        #expect(throws: VPhoneNetworkingError.natRouterFixed(expected: "192.168.64.1", subnet: "192.168.64.0/24")) {
            _ = try VPhoneNetworking.plan(
                config(.nat, ip: IPv4Config(address: "192.168.64.50", prefixLength: 24, router: "192.168.64.2")),
                host: host,
            )
        }
    }

    @Test func `nat refuses public and unusable addresses`() {
        #expect(throws: VPhoneNetworkingError.addressNotPrivate(address: "8.8.8.8", mode: "nat")) {
            _ = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "8.8.8.8", prefixLength: 24)), host: host)
        }
        #expect(throws: VPhoneNetworkingError.addressNotAssignable(address: "192.168.64.255", subnet: "192.168.64.0/24")) {
            _ = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "192.168.64.255", prefixLength: 24)), host: host)
        }
        #expect(throws: VPhoneNetworkingError.routerIsGuestAddress("192.168.64.1")) {
            _ = try VPhoneNetworking.plan(config(.nat, ip: IPv4Config(address: "192.168.64.1", prefixLength: 24)), host: host)
        }
    }

    @Test func `nat without an address stays on DHCP`() throws {
        let plan = try VPhoneNetworking.plan(config(.nat, forwards: [PortForward(hostPort: 8022, guestPort: 22)]), host: host)
        #expect(plan.attachment == .sharedNAT)
        #expect(plan.guestIPv4 == .dhcp)
        // Forwards follow the address the guest reports.
        #expect(plan.forwardingAddress == nil)
        #expect(plan.portForwards.count == 1)
    }

    // MARK: - tunnel, bridged, none

    /// The tunnel serves the address itself, so the guest stays on DHCP.
    @Test func `a tunnel address is served by the tunnel's DHCP`() throws {
        let plan = try VPhoneNetworking.plan(
            config(.tunnel, ip: IPv4Config(address: "10.20.0.5", prefixLength: 16, dns: ["1.1.1.1"])),
            host: host,
        )
        guard case let .tunnel(configuration) = plan.attachment else {
            Issue.record("expected tunnel")
            return
        }
        #expect(configuration.guestAddress == VPhoneIPv4Address(10, 20, 0, 5))
        #expect(configuration.hostAddress == VPhoneIPv4Address(10, 20, 0, 1))
        #expect(configuration.subnet.mask == VPhoneIPv4Address(255, 255, 0, 0))
        #expect(configuration.advertisedDNSServers == [VPhoneIPv4Address(1, 1, 1, 1)])
        #expect(plan.guestIPv4 == .dhcp)
        #expect(plan.forwardingAddress == configuration.guestAddress)
    }

    @Test func `a tunnel without an address keeps the default`() throws {
        let plan = try VPhoneNetworking.plan(config(.tunnel), host: host)
        #expect(plan.attachment == .tunnel(.default))
        #expect(VPhoneUserspaceNetworkConfiguration.default.advertisedDNSServers == [VPhoneIPv4Address(192, 168, 127, 1)])
    }

    @Test func `bridged takes any address and the gateway it is given`() throws {
        let plan = try VPhoneNetworking.plan(
            config(.bridged, ip: IPv4Config(address: "203.0.113.20", prefixLength: 24, router: "203.0.113.254", dns: ["203.0.113.53"])),
            host: host,
        )
        #expect(plan.attachment == .bridged(interface: "en0"))
        guard case let .manual(_, _, router, dns) = plan.guestIPv4 else {
            Issue.record("expected a manual setting")
            return
        }
        #expect(router == VPhoneIPv4Address(203, 0, 113, 254))
        #expect(dns == [VPhoneIPv4Address(203, 0, 113, 53)])
    }

    @Test func `forwards are refused where they cannot work`() {
        let forward = [PortForward(hostPort: 8022, guestPort: 22)]
        #expect(throws: VPhoneNetworkingError.portForwardUnsupported(mode: "bridged")) {
            _ = try VPhoneNetworking.plan(config(.bridged, forwards: forward), host: host)
        }
        #expect(throws: VPhoneNetworkingError.portForwardUnsupported(mode: "none")) {
            _ = try VPhoneNetworking.plan(config(.off, forwards: forward), host: host)
        }
    }

    @Test func `a host port is forwarded once per address`() {
        let clashing = [
            PortForward(hostPort: 8022, guestPort: 22),
            PortForward(hostAddress: "0.0.0.0", hostPort: 8022, guestPort: 2222),
        ]
        #expect(throws: VPhoneNetworkingError.duplicatePortForward("tcp:8022")) {
            _ = try VPhoneNetworking.plan(config(.nat, forwards: clashing), host: host)
        }
        let distinct = [
            PortForward(hostPort: 8022, guestPort: 22),
            PortForward(transport: .udp, hostPort: 8022, guestPort: 22),
        ]
        #expect(throws: Never.self) { _ = try VPhoneNetworking.plan(config(.nat, forwards: distinct), host: host) }
    }

    @Test func `none plans no device`() throws {
        let plan = try VPhoneNetworking.plan(config(.off, ip: IPv4Config(address: "192.168.64.50", prefixLength: 24)), host: host)
        #expect(plan.attachment == .none)
        #expect(plan.guestIPv4 == nil)
    }

    // MARK: - Editing

    @Test func `edits set, keep and clear the address`() throws {
        var current = try VPhoneNetworking.merge(
            into: .default,
            edit: VPhoneNetworkEdit(address: .fixed(address: "192.168.64.50", prefixLength: 24), dns: .some(["1.1.1.1"])),
            host: host,
        )
        #expect(current.ipv4 == IPv4Config(address: "192.168.64.50", prefixLength: 24, dns: ["1.1.1.1"]))

        // A new address on the same subnet keeps the resolvers.
        current = try VPhoneNetworking.merge(
            into: current,
            edit: VPhoneNetworkEdit(address: .fixed(address: "192.168.64.60", prefixLength: 24)),
            host: host,
        )
        #expect(current.ipv4?.dns == ["1.1.1.1"])

        // A new subnet drops them (tunnel, which takes any private subnet).
        current = try VPhoneNetworking.merge(
            into: current,
            edit: VPhoneNetworkEdit(mode: .tunnel, address: .fixed(address: "192.168.70.10", prefixLength: 24)),
            host: host,
        )
        #expect(current.ipv4?.dns == nil)

        current = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(address: .dhcp), host: host)
        #expect(current.ipv4 == nil)
    }

    @Test func `gateway and DNS need an address`() {
        #expect(throws: VPhoneNetworkingError.settingWithoutAddress("--gateway")) {
            _ = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(router: .some("192.168.64.1")), host: host)
        }
        #expect(throws: VPhoneNetworkingError.settingWithoutAddress("--dns")) {
            _ = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(dns: .some(["1.1.1.1"])), host: host)
        }
    }

    /// `--gateway auto` and `--dns auto` on a DHCP machine have nothing to undo.
    @Test func `returning the gateway and DNS to their defaults needs no address`() throws {
        let edit = VPhoneNetworkEdit(router: .some(nil), dns: .some(nil))
        #expect(try VPhoneNetworking.merge(into: .default, edit: edit, host: host) == .default)
    }

    @Test func `a forward that is already there is not added again`() throws {
        let forward = PortForward(hostPort: 8022, guestPort: 22)
        let once = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(addForwards: [forward]), host: host)
        let twice = try VPhoneNetworking.merge(into: once, edit: VPhoneNetworkEdit(addForwards: [forward, forward]), host: host)
        #expect(twice.portForwards == [forward])
    }

    @Test func `edits add, remove and clear forwards`() throws {
        var current = try VPhoneNetworking.merge(
            into: .default,
            edit: VPhoneNetworkEdit(addForwards: [
                PortForward(hostPort: 8022, guestPort: 22),
                PortForward(transport: .udp, hostPort: 5353, guestPort: 53),
            ]),
            host: host,
        )
        #expect(current.portForwards?.count == 2)

        current = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(removeForwards: ["8022"]), host: host)
        #expect(current.portForwards == [PortForward(transport: .udp, hostPort: 5353, guestPort: 53)])

        #expect(throws: VPhoneNetworkingError.portForwardNotFound("9999")) {
            _ = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(removeForwards: ["9999"]), host: host)
        }

        current = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(clearForwards: true), host: host)
        #expect(current.portForwards == nil)
    }

    @Test func `edits set and reset the MAC`() throws {
        var current = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(mac: .fixed("02:AA:BB:CC:DD:EE")), host: host)
        #expect(current.macAddress == "02:aa:bb:cc:dd:ee")
        current = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(mac: .random), host: host)
        #expect(current.macAddress != "02:aa:bb:cc:dd:ee")
        #expect(VPhoneMACAddress(string: current.macAddress)?.isUnicast == true)
        current = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(mac: .automatic), host: host)
        #expect(current.macAddress.isEmpty)
    }

    // MARK: - mDNS name

    @Test func `VM names become DNS labels`() {
        #expect(VPhoneNetworking.localHostName(forVMName: "pcc-research-01") == "pcc-research-01")
        #expect(VPhoneNetworking.localHostName(forVMName: "ipad_pro.13") == "ipad-pro-13")
        #expect(VPhoneNetworking.localHostName(forVMName: "__lab__vm__") == "lab-vm")
        #expect(VPhoneNetworking.localHostName(forVMName: "___") == "vphone")
        #expect(VPhoneNetworking.localHostName(forVMName: String(repeating: "a", count: 80)).count == 63)
    }

    @Test func `mDNS names are single labels`() throws {
        #expect(try VPhoneNetworking.validLocalHostName("lab-phone") == "lab-phone")
        #expect(try VPhoneNetworking.validLocalHostName("lab-phone.local") == "lab-phone")
        for bad in ["", "-lab", "lab-", "lab.phone", "lab_phone", String(repeating: "a", count: 64)] {
            #expect(throws: VPhoneNetworkingError.invalidLocalHostName(bad)) {
                _ = try VPhoneNetworking.validLocalHostName(bad)
            }
        }
    }

    @Test func `edits set and clear the mDNS name`() throws {
        var current = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(localHostName: .some("lab-phone.local")), host: host)
        #expect(current.localHostName == "lab-phone")
        let plan = try VPhoneNetworking.plan(current, host: host)
        #expect(plan.localHostName == "lab-phone")
        current = try VPhoneNetworking.merge(into: current, edit: VPhoneNetworkEdit(localHostName: .some(nil)), host: host)
        #expect(current.localHostName == nil)
        #expect(throws: VPhoneNetworkingError.invalidLocalHostName("lab_phone")) {
            _ = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(localHostName: .some("lab_phone")), host: host)
        }
    }

    /// The guest also announces over its USB link to the Mac, so the name
    /// applies without a NIC too.
    @Test func `a VM without a NIC keeps its mDNS name`() throws {
        let plan = try VPhoneNetworking.plan(NetworkConfig(mode: .off, macAddress: "", localHostName: "lab-phone"), host: host)
        #expect(plan.localHostName == "lab-phone")
    }

    // MARK: - The Mac's name in the guest

    @Test func `the Mac's name points where the guest reaches the Mac`() throws {
        // A nat guest reaches its peers by default, on vmnet's second network.
        let nat = try VPhoneNetworking.plan(config(.nat), host: host)
        #expect(VPhoneNetworking.macStaticNames(plan: nat, macName: "Lab-Mac") == [
            .init(address: VPhoneIPv4Address(192, 168, 65, 1), names: ["Lab-Mac.local"]),
        ])
        let tunnel = try VPhoneNetworking.plan(config(.tunnel), host: host)
        #expect(VPhoneNetworking.macStaticNames(plan: tunnel, macName: "Lab-Mac").first?.address == VPhoneIPv4Address(192, 168, 127, 1))
        let bridged = try VPhoneNetworking.plan(config(.bridged), host: host)
        #expect(VPhoneNetworking.macStaticNames(plan: bridged, macName: "Lab-Mac").isEmpty)
        #expect(VPhoneNetworking.macStaticNames(plan: bridged, macName: "Lab-Mac", bridgedAddress: VPhoneIPv4Address(10, 0, 0, 7)).first?.address == VPhoneIPv4Address(10, 0, 0, 7))
        let none = try VPhoneNetworking.plan(config(.off), host: host)
        #expect(VPhoneNetworking.macStaticNames(plan: none, macName: "Lab-Mac").isEmpty)
        #expect(VPhoneNetworking.macStaticNames(plan: nat, macName: nil).isEmpty)
    }

    /// On by default and stored as an absent key, so only `off` reaches the plist.
    @Test func `the Mac's name can be turned off`() throws {
        let off = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(resolvesMacName: false), host: host)
        #expect(off.resolvesMacName == false)
        #expect(try VPhoneNetworking.macStaticNames(plan: VPhoneNetworking.plan(off, host: host), macName: "Lab-Mac").isEmpty)
        let on = try VPhoneNetworking.merge(into: off, edit: VPhoneNetworkEdit(resolvesMacName: true), host: host)
        #expect(on.resolvesMacName == nil)
        #expect(try VPhoneNetworking.plan(on, host: host).resolvesMacName)
    }

    /// NAT machines reach each other unless one opts out; the switch is
    /// stored like the Mac's name, and only `nat` has it.
    @Test func `nat machines reach each other unless one opts out`() throws {
        #expect(try VPhoneNetworking.plan(.default, host: host).reachesPeers)
        let off = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(reachesPeers: false), host: host)
        #expect(off.reachesPeers == false)
        #expect(try !VPhoneNetworking.plan(off, host: host).reachesPeers)
        let on = try VPhoneNetworking.merge(into: off, edit: VPhoneNetworkEdit(reachesPeers: true), host: host)
        #expect(on.reachesPeers == true)
        let tunnel = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(mode: .tunnel), host: host)
        #expect(try !VPhoneNetworking.plan(tunnel, host: host).reachesPeers)
    }

    /// Peers are on vmnet's second shared network, the block after the first.
    @Test func `a machine that reaches its peers is on the second shared network`() throws {
        #expect(host.peerNATSubnet.description == "192.168.65.0/24")
        #expect(host.peerNATHost == VPhoneIPv4Address(192, 168, 65, 1))
        #expect(try VPhoneNetworking.plan(.default, host: host).macAddressForGuest == host.peerNATHost)
        let off = try VPhoneNetworking.merge(into: .default, edit: VPhoneNetworkEdit(reachesPeers: false), host: host)
        #expect(try VPhoneNetworking.plan(off, host: host).macAddressForGuest == host.sharedNATHost)

        // A fixed address follows: on the second network with peers, on the
        // first without.
        let peer = try VPhoneNetworking.merge(
            into: .default, edit: VPhoneNetworkEdit(address: .fixed(address: "192.168.65.50", prefixLength: 24)), host: host,
        )
        #expect(try VPhoneNetworking.plan(peer, host: host).reachesPeers)
        #expect(throws: VPhoneNetworkingError.self) {
            try VPhoneNetworking.merge(into: off, edit: VPhoneNetworkEdit(address: .fixed(address: "192.168.65.50", prefixLength: 24)), host: host)
        }

        // A fixed address on the first network, set before peers existed,
        // keeps that machine isolated, unless it asks for its peers.
        let shared = try VPhoneNetworking.merge(
            into: .default, edit: VPhoneNetworkEdit(address: .fixed(address: "192.168.64.50", prefixLength: 24)), host: host,
        )
        #expect(try !VPhoneNetworking.plan(shared, host: host).reachesPeers)
        #expect(!VPhoneNetworking.reachesPeers(shared, host: host))
        #expect(throws: VPhoneNetworkingError.self) {
            try VPhoneNetworking.merge(into: shared, edit: VPhoneNetworkEdit(reachesPeers: true), host: host)
        }
    }

    @Test func `a NAT attachment can drop its isolation`() throws {
        let nat = VZNATNetworkDeviceAttachment()
        #expect(nat.responds(to: NSSelectorFromString("_setInterfaceIsolationEnabled:")))
        try VPhoneNetworking.setInterfaceIsolation(false, of: nat)
        let device = try VPhoneNetworking.makeNetworkDevice(VPhoneNetworking.plan(.default, host: host))
        #expect(device.configuration?.attachment is VZNATNetworkDeviceAttachment)
    }

    // MARK: - Guest setting

    @Test func `the guest setting carries what vphoned needs`() throws {
        let subnet = try #require(VPhoneIPv4Subnet(containing: VPhoneIPv4Address(192, 168, 64, 0), prefixLength: 24))
        let setting = VPhoneGuestIPv4Setting.manual(
            address: VPhoneIPv4Address(192, 168, 64, 50),
            subnet: subnet,
            router: VPhoneIPv4Address(192, 168, 64, 1),
            dns: [VPhoneIPv4Address(1, 1, 1, 1)],
        )
        let parameters = setting.parameters
        #expect(parameters["method"] as? String == "manual")
        #expect(parameters["address"] as? String == "192.168.64.50")
        #expect(parameters["subnet_mask"] as? String == "255.255.255.0")
        #expect(parameters["router"] as? String == "192.168.64.1")
        #expect(parameters["dns"] as? [String] == ["1.1.1.1"])
        #expect(VPhoneGuestIPv4Setting.dhcp.parameters["method"] as? String == "dhcp")
    }

    // MARK: - Manifest

    /// A config.plist from before these fields loads, and writes them back
    /// only once they are set.
    @Test func `older network configs still decode`() throws {
        let old = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>mode</key><string>nat</string><key>macAddress</key><string></string></dict></plist>
        """.utf8)
        let decoded = try PropertyListDecoder().decode(NetworkConfig.self, from: old)
        #expect(decoded == .default)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let plain = try String(decoding: encoder.encode(decoded), as: UTF8.self)
        #expect(!plain.contains("ipv4"))
        #expect(!plain.contains("portForwards"))

        let full = NetworkConfig(
            mode: .nat,
            macAddress: "02:aa:bb:cc:dd:ee",
            ipv4: IPv4Config(address: "192.168.64.50", prefixLength: 24),
            portForwards: [PortForward(transport: .udp, hostPort: 5353, guestPort: 53)],
        )
        let written = try encoder.encode(full)
        #expect(String(decoding: written, as: UTF8.self).contains("<key>protocol</key>"))
        #expect(try PropertyListDecoder().decode(NetworkConfig.self, from: written) == full)
    }

    // MARK: - TASK-002: intercept is tunnel-only (REQ-002)

    @Test func `intercept outside tunnel mode is rejected`() throws {
        for mode in [NetworkConfig.NetworkMode.nat, .bridged, .off] {
            let withEndpoint = config(mode).with(intercept: "127.0.0.1:1080")
            #expect(throws: VPhoneNetworkingError.self) {
                _ = try VPhoneNetworking.plan(withEndpoint, host: host)
            }
            do {
                _ = try VPhoneNetworking.plan(withEndpoint, host: host)
                Issue.record("expected plan() to throw for intercept in \(mode)")
            } catch let error as VPhoneNetworkingError {
                #expect(error.description.contains("tunnel mode"))
                #expect(error.description.contains("--network tunnel"))
            }
            // interceptBlockQUIC alone (no intercept) is equally tunnel-only.
            let withQUIC = config(mode).with(interceptBlockQUIC: true)
            do {
                _ = try VPhoneNetworking.plan(withQUIC, host: host)
                Issue.record("expected plan() to throw for interceptBlockQUIC in \(mode)")
            } catch let error as VPhoneNetworkingError {
                #expect(error.description.contains("tunnel mode"))
                #expect(error.description.contains("--network tunnel"))
            }
        }
    }

    @Test func `intercept in tunnel mode is accepted`() throws {
        let cfg = config(.tunnel).with(intercept: "127.0.0.1:1080", interceptBlockQUIC: true)
        #expect(throws: Never.self) { _ = try VPhoneNetworking.plan(cfg, host: host) }
    }

    /// A set-but-unparseable `intercept` on a tunnel manifest throws the
    /// already-redacted `networkConfig.intercept:` error — it NEVER fails open
    /// to a nil upstream / direct connect, and builds no userspace network.
    /// The redacted message never leaks a literal password (`s3cret`).
    @Test func `unparseable intercept in tunnel mode fails closed`() throws {
        for bad in ["http://h:1", "socks5://${bogus}@h:1", "socks5://u:s3cret@h:0"] {
            let cfg = config(.tunnel).with(intercept: bad)
            do {
                _ = try VPhoneNetworking.plan(cfg, host: host)
                Issue.record("expected plan() to throw for intercept \"\(bad)\"")
            } catch let error as VPhoneVirtualMachineManifest.NetworkConfig.InterceptParseError {
                #expect(error.description.contains("networkConfig.intercept:"))
                #expect(!error.description.contains("s3cret"))
            }
            // A fail-open path would still build the tunnel device; assert it
            // throws instead, so no userspace network / forwarder is created.
            #expect(throws: VPhoneVirtualMachineManifest.NetworkConfig.InterceptParseError.self) {
                _ = try VPhoneNetworking.makeNetworkDevice(cfg)
            }
        }
    }

    // MARK: - interception edits (TASK-006)

    /// `--intercept host:port` sets the endpoint, `--no-intercept` clears it,
    /// and an edit that touches neither leaves it as it was.
    @Test func `an edit sets and clears the intercept endpoint`() throws {
        let base = config(.tunnel)
        let set = try VPhoneNetworking.merge(into: base, edit: VPhoneNetworkEdit(intercept: .some("127.0.0.1:1080")), host: host)
        #expect(set.intercept == "127.0.0.1:1080")

        let cleared = try VPhoneNetworking.merge(into: set, edit: VPhoneNetworkEdit(intercept: .some(nil)), host: host)
        #expect(cleared.intercept == nil)

        let untouched = try VPhoneNetworking.merge(into: set, edit: VPhoneNetworkEdit(), host: host)
        #expect(untouched.intercept == "127.0.0.1:1080")
    }

    /// `--intercept-block-quic` / `--no-intercept-block-quic` toggle the flag; an
    /// edit that touches neither leaves it.
    @Test func `an edit toggles QUIC blocking`() throws {
        let base = config(.tunnel)
        let on = try VPhoneNetworking.merge(into: base, edit: VPhoneNetworkEdit(interceptBlockQUIC: true), host: host)
        #expect(on.blockQUIC)

        let off = try VPhoneNetworking.merge(into: on, edit: VPhoneNetworkEdit(interceptBlockQUIC: false), host: host)
        #expect(!off.blockQUIC)

        let untouched = try VPhoneNetworking.merge(into: on, edit: VPhoneNetworkEdit(), host: host)
        #expect(untouched.blockQUIC)
    }

    /// The grammar the CLI validates `--intercept` against: host:port with a
    /// 1-65535 port, IPv6 in brackets; everything else is rejected.
    @Test func `the intercept grammar accepts host colon port and rejects the rest`() throws {
        typealias Cfg = VPhoneVirtualMachineManifest.NetworkConfig
        #expect(try Cfg.parseInterceptEndpoint("127.0.0.1:1080").port == 1080)
        #expect(try Cfg.parseInterceptEndpoint("[::1]:8080").host == "::1")
        for bad in ["bad", "host:", ":80", "host:0", "host:70000", "host:-1", "host:x"] {
            #expect(throws: (any Error).self) { try Cfg.parseInterceptEndpoint(bad) }
        }
    }

    // MARK: - TASK-006: edit-path validation, redaction, tunnel-exit, secret warning

    /// The edit path validates `--intercept` with the same guard `plan()` uses:
    /// a `socks5://` URL with credentials is accepted; a non-socks5 scheme and
    /// an unrecognised `${…}` token are rejected, leaving the config unchanged.
    @Test func `the edit path accepts a credentialed URL and rejects bad schemes and tokens`() throws {
        let base = config(.tunnel)
        let set = try VPhoneNetworking.merge(
            into: base, edit: VPhoneNetworkEdit(intercept: .some("socks5://u:p@127.0.0.1:1080")), host: host,
        )
        #expect(set.intercept == "socks5://u:p@127.0.0.1:1080")

        for bad in ["http://h:1", "socks5://${bogus}@h:1"] {
            #expect(throws: (any Error).self) {
                _ = try VPhoneNetworking.merge(into: base, edit: VPhoneNetworkEdit(intercept: .some(bad)), host: host)
            }
            // The config is unchanged: the throwing merge produced no value.
            #expect(base.intercept == nil)
        }
    }

    /// The edit path builds its own usage error, and it is redacted: a literal
    /// password never reaches the message (asserted here independently of the
    /// TASK-001 parse test).
    @Test func `the edit path redacts the password in its usage error`() throws {
        for bad in ["socks5://u:s3cret@h:abc", "socks5://u:s3cret@:1080"] {
            do {
                _ = try VPhoneNetworking.resolveInterceptEdit(
                    current: config(.tunnel), edit: VPhoneNetworkEdit(intercept: .some(bad)), newMode: .tunnel,
                )
                Issue.record("expected resolveInterceptEdit to throw for \"\(bad)\"")
            } catch {
                #expect("\(error)".contains("***"))
                #expect(!"\(error)".contains("s3cret"))
            }
        }
    }

    /// A literal password is accepted but flags the Secret-policy warning, which
    /// names both exposures and the safer form; a `${env:NAME}` password does not.
    @Test func `a literal password warns and an env token does not`() throws {
        let literal = try VPhoneNetworking.resolveInterceptEdit(
            current: config(.tunnel), edit: VPhoneNetworkEdit(intercept: .some("socks5://u:s3cret@127.0.0.1:1080")),
            newMode: .tunnel,
        )
        #expect(literal.plaintextCredentialWarning)

        let token = try VPhoneNetworking.resolveInterceptEdit(
            current: config(.tunnel), edit: VPhoneNetworkEdit(intercept: .some("socks5://u:${env:PW}@127.0.0.1:1080")),
            newMode: .tunnel,
        )
        #expect(!token.plaintextCredentialWarning)

        let noPassword = try VPhoneNetworking.resolveInterceptEdit(
            current: config(.tunnel), edit: VPhoneNetworkEdit(intercept: .some("socks5://u@127.0.0.1:1080")),
            newMode: .tunnel,
        )
        #expect(!noPassword.plaintextCredentialWarning)

        let warning = VPhoneNetworking.plaintextInterceptPasswordWarning
        #expect(warning.contains("command line"))
        #expect(warning.contains("manifest"))
        #expect(warning.contains("${env:NAME}"))
    }

    /// Moving a VM with `intercept` set from tunnel to nat clears both intercept
    /// fields and signals proxying-disabled; a tunnel→tunnel edit keeps them.
    @Test func `leaving tunnel mode clears interception and signals it`() throws {
        let set = config(.tunnel).with(intercept: "127.0.0.1:1080", interceptBlockQUIC: true)

        let toNat = try VPhoneNetworking.merge(into: set, edit: VPhoneNetworkEdit(mode: .nat), host: host)
        #expect(toNat.intercept == nil)
        #expect(!toNat.blockQUIC)

        let signal = try VPhoneNetworking.resolveInterceptEdit(
            current: set, edit: VPhoneNetworkEdit(mode: .nat), newMode: .nat,
        )
        #expect(signal.proxyingDisabled)
        #expect(signal.intercept == nil)
        #expect(!signal.interceptBlockQUIC)

        let stayTunnel = try VPhoneNetworking.merge(into: set, edit: VPhoneNetworkEdit(mode: .tunnel), host: host)
        #expect(stayTunnel.intercept == "127.0.0.1:1080")
        #expect(stayTunnel.blockQUIC)
    }

    /// Setting `--intercept` or `--intercept-block-quic` while the resulting mode
    /// is not tunnel is a usage error naming the remedy; on tunnel it is accepted.
    @Test func `setting interception off tunnel is rejected and on tunnel accepted`() throws {
        for mode in [NetworkConfig.NetworkMode.nat, .bridged, .off] {
            let base = config(mode)
            for edit in [VPhoneNetworkEdit(intercept: .some("127.0.0.1:1080")), VPhoneNetworkEdit(interceptBlockQUIC: true)] {
                do {
                    _ = try VPhoneNetworking.resolveInterceptEdit(current: base, edit: edit, newMode: mode)
                    Issue.record("expected a tunnel-only rejection in \(mode)")
                } catch let error as VPhoneNetworkingError {
                    #expect(error.description.contains("tunnel mode"))
                    #expect(error.description.contains("--network tunnel"))
                }
                // merge rejects the same way, leaving the config untouched.
                #expect(throws: VPhoneNetworkingError.self) {
                    _ = try VPhoneNetworking.merge(into: base, edit: edit, host: host)
                }
                #expect(base.intercept == nil)
                #expect(!base.blockQUIC)
            }
        }

        let tunnel = config(.tunnel)
        let withEndpoint = try VPhoneNetworking.merge(
            into: tunnel, edit: VPhoneNetworkEdit(intercept: .some("127.0.0.1:1080")), host: host,
        )
        #expect(withEndpoint.intercept == "127.0.0.1:1080")
        let withQUIC = try VPhoneNetworking.merge(into: tunnel, edit: VPhoneNetworkEdit(interceptBlockQUIC: true), host: host)
        #expect(withQUIC.blockQUIC)
    }

    /// The edit layer's conflict is the same usage error `plan()` guards, and a
    /// changed intercept field signals that it takes effect on the next VM start.
    @Test func `the edit layer reports the tunnel conflict and the next-start signal`() throws {
        let conflict = "interception requires tunnel mode; set --network tunnel"
        for mode in [NetworkConfig.NetworkMode.nat, .bridged, .off] {
            do {
                _ = try VPhoneNetworking.resolveInterceptEdit(
                    current: config(mode), edit: VPhoneNetworkEdit(intercept: .some("127.0.0.1:1080")), newMode: mode,
                )
                Issue.record("expected a tunnel-only rejection in \(mode)")
            } catch let error as VPhoneNetworkingError {
                #expect(error.description == conflict)
            }
        }

        let base = config(.tunnel)
        let changed = try VPhoneNetworking.resolveInterceptEdit(
            current: base, edit: VPhoneNetworkEdit(intercept: .some("127.0.0.1:1080")), newMode: .tunnel,
        )
        #expect(changed.takesEffectNextStart)

        let same = try VPhoneNetworking.resolveInterceptEdit(
            current: base.with(intercept: "127.0.0.1:1080"),
            edit: VPhoneNetworkEdit(intercept: .some("127.0.0.1:1080")), newMode: .tunnel,
        )
        #expect(!same.takesEffectNextStart)
    }

    /// `--no-intercept` clears only `intercept` and leaves `interceptBlockQUIC`.
    @Test func `clearing intercept leaves QUIC blocking alone`() throws {
        let set = config(.tunnel).with(intercept: "127.0.0.1:1080", interceptBlockQUIC: true)
        let cleared = try VPhoneNetworking.merge(into: set, edit: VPhoneNetworkEdit(intercept: .some(nil)), host: host)
        #expect(cleared.intercept == nil)
        #expect(cleared.blockQUIC)
    }
}
