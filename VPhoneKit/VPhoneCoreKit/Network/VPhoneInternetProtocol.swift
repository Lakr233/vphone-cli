import Foundation

// MARK: - Addresses

/// An IPv4 address held in host order. Deliberately not `Network`/`NWAddress`:
/// this type only has to round-trip through byte arrays.
public struct VPhoneIPv4Address: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var raw: UInt32

    public init(_ raw: UInt32) {
        self.raw = raw
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        raw = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: raw >> 24), UInt8(truncatingIfNeeded: raw >> 16),
         UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
    }

    public var description: String {
        bytes.map(String.init).joined(separator: ".")
    }

    /// `255.255.255.255`
    public static let broadcast = VPhoneIPv4Address(255, 255, 255, 255)
    /// `0.0.0.0`
    public static let any = VPhoneIPv4Address(0, 0, 0, 0)
}

// MARK: - Subnet

/// An IPv4 network, `network/prefixLength`.
public struct VPhoneIPv4Subnet: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The network address, with every host bit clear.
    public let network: VPhoneIPv4Address
    public let prefixLength: Int

    /// The subnet `address` sits in. Nil for a prefix outside 0...32.
    public init?(containing address: VPhoneIPv4Address, prefixLength: Int) {
        guard (0 ... 32).contains(prefixLength) else { return nil }
        self.prefixLength = prefixLength
        network = VPhoneIPv4Address(address.raw & Self.mask(prefixLength))
    }

    /// The subnet named by an address and a dotted mask, nil when the mask's
    /// bits are not contiguous.
    public init?(containing address: VPhoneIPv4Address, mask: VPhoneIPv4Address) {
        let length = mask.raw.nonzeroBitCount
        guard Self.mask(length) == mask.raw else { return nil }
        self.init(containing: address, prefixLength: length)
    }

    private static func mask(_ length: Int) -> UInt32 {
        length == 0 ? 0 : UInt32.max << UInt32(32 - length)
    }

    public var mask: VPhoneIPv4Address {
        VPhoneIPv4Address(Self.mask(prefixLength))
    }

    public var broadcast: VPhoneIPv4Address {
        VPhoneIPv4Address(network.raw | ~Self.mask(prefixLength))
    }

    /// The first assignable address, where `nat` and `tunnel` put the host.
    public var firstHost: VPhoneIPv4Address {
        VPhoneIPv4Address(network.raw &+ 1)
    }

    public func contains(_ address: VPhoneIPv4Address) -> Bool {
        address.raw & Self.mask(prefixLength) == network.raw
    }

    /// Whether `address` can be given to a node: inside, and neither the
    /// network nor the broadcast address.
    public func isAssignable(_ address: VPhoneIPv4Address) -> Bool {
        contains(address) && address != network && address != broadcast
    }

    public func overlaps(_ other: VPhoneIPv4Subnet) -> Bool {
        contains(other.network) || other.contains(network)
    }

    /// RFC 1918 space, the only addresses `nat` and `tunnel` hand out.
    public static let privateRanges = [
        VPhoneIPv4Subnet(containing: VPhoneIPv4Address(10, 0, 0, 0), prefixLength: 8)!,
        VPhoneIPv4Subnet(containing: VPhoneIPv4Address(172, 16, 0, 0), prefixLength: 12)!,
        VPhoneIPv4Subnet(containing: VPhoneIPv4Address(192, 168, 0, 0), prefixLength: 16)!,
    ]

    public var isPrivate: Bool {
        Self.privateRanges.contains { $0.contains(network) && $0.prefixLength <= prefixLength }
    }

    public var description: String {
        "\(network)/\(prefixLength)"
    }
}

// MARK: - Configuration

/// An explicitly-specified SOCKS5 proxy the tunnel redirects guest TCP through.
///
/// The host is kept as written (a dotted IPv4 literal, a bracketed-IPv6 literal
/// with the brackets stripped, or a name) so it can be resolved once when the
/// userspace network starts; the forwarder stack is IPv4-only, so a host that
/// yields no IPv4 address fails closed rather than connecting directly.
public struct VPhoneInterceptEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    /// The raw userinfo fields, still carrying any `${…}` token. Substitution
    /// happens once at `VPhoneUserspaceNetwork.start()` (REQ-001), not here. A
    /// nil `user` means no credentials (no-auth only); `password` is nil when
    /// the userinfo has no `:`.
    public var user: String?
    public var password: String?

    public init(host: String, port: UInt16, user: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
    }
}

/// Addressing for the userspace network.
///
/// The default subnet deliberately differs from vmnet's `192.168.64.0/24` so
/// `tunnel` and `nat` can coexist on one host without their DHCP servers
/// answering each other. It also sits inside `192.168.0.0/16`, which every
/// mainstream VPN keeps out of its tunnel. A VM's `ipv4` setting replaces it.
public struct VPhoneUserspaceNetworkConfiguration: Sendable, Equatable {
    /// The address the host answers ARP for, serves DHCP from, and later
    /// appears to be the DNS resolver. Also the DHCP `server-id`.
    public var hostAddress: VPhoneIPv4Address
    /// The lease handed to the guest. One address is enough: one guest per VM.
    public var guestAddress: VPhoneIPv4Address
    /// The guest's subnet, advertised as DHCP option 1.
    public var prefixLength: Int
    /// Resolvers advertised as DHCP option 6. Empty means `hostAddress`, whose
    /// port 53 is answered by the host's own resolver.
    public var dnsServers: [VPhoneIPv4Address]
    /// Advertised through DHCP option 26, and the ceiling for everything we send
    /// the guest.
    ///
    /// 1500, not the 1280 the v1.x tunnel work used. That 1280 was chosen so the
    /// guest's segments would fit a VPN tunnel without fragmenting -- but the
    /// guest's frames reach the host over a socket pair and leave through a host
    /// socket whose kernel does its own segmentation, so the tunnel's MTU never
    /// applied here. Copying it had a real cost: QUIC sends 1280-byte payloads,
    /// which with UDP and IP headers come to 1308, past the advertised 1280. Every
    /// one of them was too big to hand the guest, and Safari -- which prefers
    /// HTTP/3 -- spent its time retrying rather than loading.
    public var mtu: Int
    /// An explicitly-specified SOCKS5 upstream to redirect guest TCP through, or
    /// nil for direct connect. Resolved once at `VPhoneUserspaceNetwork.start()`.
    /// Never sourced from the Mac's system proxy setting (NFR-004).
    public var intercept: VPhoneInterceptEndpoint?
    /// Drop guest UDP to port 443 so QUIC apps fall back to interceptable TCP.
    public var blockQUIC: Bool
    /// The VM's name (the `.vphone` bundle directory name without extension),
    /// the source for a `${vm.name}` token in `intercept` userinfo. Plumbed from
    /// the `plan()` caller, which holds the bundle.
    public var vmName: String
    /// The VM's predicted UDID (`VPhoneRestoreOperations.resolveUDID`), the
    /// source for a `${vm.id}` token. Nil when there is no predicted UDID, which
    /// makes a `${vm.id}` token undefined and fails resolution closed.
    public var vmID: String?

    public static let `default` = VPhoneUserspaceNetworkConfiguration(
        hostAddress: VPhoneIPv4Address(192, 168, 127, 1),
        guestAddress: VPhoneIPv4Address(192, 168, 127, 3),
        mtu: 1500,
    )

    public init(
        hostAddress: VPhoneIPv4Address,
        guestAddress: VPhoneIPv4Address,
        prefixLength: Int = 24,
        dnsServers: [VPhoneIPv4Address] = [],
        mtu: Int = 1500,
        intercept: VPhoneInterceptEndpoint? = nil,
        blockQUIC: Bool = false,
        vmName: String = "",
        vmID: String? = nil,
    ) {
        self.hostAddress = hostAddress
        self.guestAddress = guestAddress
        self.prefixLength = prefixLength
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.intercept = intercept
        self.blockQUIC = blockQUIC
        self.vmName = vmName
        self.vmID = vmID
    }

    /// The guest's subnet.
    public var subnet: VPhoneIPv4Subnet {
        VPhoneIPv4Subnet(containing: guestAddress, prefixLength: prefixLength)
            ?? VPhoneIPv4Subnet(containing: guestAddress, prefixLength: 24)!
    }

    /// What DHCP option 6 carries.
    public var advertisedDNSServers: [VPhoneIPv4Address] {
        dnsServers.isEmpty ? [hostAddress] : dnsServers
    }
}

/// A 48-bit Ethernet address. The host side uses a locally administered address
/// of its own; the tunnel learns the guest's from the first frame it sends, so
/// it works whether or not the manifest names one.
public struct VPhoneMACAddress: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Parse `aa:bb:cc:dd:ee:ff` (or with `-`), nil for anything else.
    public init?(string: String) {
        let parts = string.split(omittingEmptySubsequences: false) { $0 == ":" || $0 == "-" }
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2, let value = UInt8(part, radix: 16) else { return nil }
            bytes.append(value)
        }
        self.init(bytes)
    }

    /// A random unicast, locally administered address: the kind no vendor
    /// assigns, so it cannot collide with real hardware.
    public static func randomLocallyAdministered() -> VPhoneMACAddress {
        var bytes = (0 ..< 6).map { _ in UInt8.random(in: 0 ... 255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return VPhoneMACAddress(bytes)
    }

    /// The gateway's address. Locally administered, unicast, and unlikely to
    /// collide with anything.
    public static let gateway = VPhoneMACAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])

    /// Not a group address. A NIC with the multicast bit set is not reachable.
    public var isUnicast: Bool {
        bytes.count == 6 && bytes[0] & 0x01 == 0
    }

    public var isZero: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public var description: String {
        hexString
    }
}

// MARK: - Checksums

enum VPhoneInternetChecksum {
    /// RFC 1071 internet checksum. `seed` carries a pseudo-header for UDP/TCP.
    static func compute(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt16 {
        var sum = seed
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }
}

// MARK: - Ethernet

enum VPhoneEtherType: UInt16 {
    case ipv4 = 0x0800
    case arp = 0x0806
}

struct VPhoneEthernetFrame {
    var destination: VPhoneMACAddress
    var source: VPhoneMACAddress
    var etherType: UInt16
    var payload: [UInt8]

    init(destination: VPhoneMACAddress, source: VPhoneMACAddress, etherType: VPhoneEtherType, payload: [UInt8]) {
        self.destination = destination
        self.source = source
        self.etherType = etherType.rawValue
        self.payload = payload
    }

    var bytes: [UInt8] {
        destination.bytes + source.bytes + [UInt8(etherType >> 8), UInt8(etherType & 0xFF)] + payload
    }

    /// Parse, or nil if the frame is malformed or too short to address.
    init?(bytes: [UInt8]) {
        guard bytes.count >= 14 else { return nil }
        destination = VPhoneMACAddress(Array(bytes[0 ..< 6]))
        source = VPhoneMACAddress(Array(bytes[6 ..< 12]))
        etherType = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
        payload = Array(bytes[14...])
    }
}

// MARK: - IPv4

enum VPhoneIPProtocol: UInt8 {
    case icmp = 1
    case tcp = 6
    case udp = 17
}

struct VPhoneIPv4Packet {
    var source: VPhoneIPv4Address
    var destination: VPhoneIPv4Address
    var proto: UInt8
    var ttl: UInt8
    var identification: UInt16
    var payload: [UInt8]

    /// Fragment offset in eight-byte units. Non-zero only in fragments after the
    /// first.
    var fragmentOffset: UInt16 = 0
    /// Set on every fragment but the last.
    var moreFragments = false

    init(
        source: VPhoneIPv4Address,
        destination: VPhoneIPv4Address,
        proto: VPhoneIPProtocol,
        ttl: UInt8 = 64,
        identification: UInt16 = 0,
        payload: [UInt8],
    ) {
        self.source = source
        self.destination = destination
        self.proto = proto.rawValue
        self.ttl = ttl
        self.identification = identification
        self.payload = payload
    }

    /// Split so every fragment's IP datagram fits `mtu`.
    ///
    /// Only the sending side implements this: the guest reassembles, and it is
    /// the only side that has to. Slices are multiples of eight because the
    /// header's offset field counts eight-byte units, and the last fragment
    /// carries the payload's remainder however it falls.
    func fragmented(toFit mtu: Int) -> [[UInt8]] {
        let headerSize = 20
        guard totalLength > mtu, !payload.isEmpty else { return [bytes] }
        let maxSlice = ((mtu - headerSize) / 8) * 8
        guard maxSlice > 0 else { return [bytes] }

        let identifier = identification == 0 ? UInt16.random(in: 1 ... UInt16.max) : identification
        var fragments: [[UInt8]] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxSlice, payload.count)
            let isLast = end >= payload.count
            var fragment = VPhoneIPv4Packet(
                source: source,
                destination: destination,
                proto: VPhoneIPProtocol(rawValue: proto) ?? .icmp,
                ttl: ttl,
                identification: identifier,
                payload: Array(payload[offset ..< end]),
            )
            fragment.fragmentOffset = UInt16(offset / 8)
            fragment.moreFragments = !isLast
            fragments.append(fragment.bytes)
            offset = end
        }
        return fragments
    }

    var totalLength: Int {
        20 + payload.count
    }

    /// True when this is one piece of a larger datagram. Nothing here reassembles,
    /// so such a packet cannot be handled and has to be dropped rather than
    /// misread: only the first fragment even carries the transport header.
    var isFragment: Bool {
        moreFragments || fragmentOffset != 0
    }

    /// Bit 0x2000 marks a fragment that is not the last; bits 0..12 hold the
    /// offset in eight-byte units. A single unfragmented packet leaves both zero.
    private var flagsAndFragmentOffset: UInt16 {
        (moreFragments ? 0x2000 : 0) | (fragmentOffset & 0x1FFF)
    }

    var bytes: [UInt8] {
        var header: [UInt8] = [
            0x45, 0x00,
            UInt8(truncatingIfNeeded: totalLength >> 8), UInt8(truncatingIfNeeded: totalLength),
            UInt8(truncatingIfNeeded: identification >> 8), UInt8(truncatingIfNeeded: identification),
            UInt8(flagsAndFragmentOffset >> 8), UInt8(truncatingIfNeeded: flagsAndFragmentOffset),
            ttl, proto,
        ]
        header += [0, 0] // checksum placeholder
        header += source.bytes + destination.bytes
        let sum = VPhoneInternetChecksum.compute(header)
        header[10] = UInt8(sum >> 8)
        header[11] = UInt8(sum & 0xFF)
        return header + payload
    }

    /// Parse, or nil for anything we cannot answer: fragments, options, IPv6.
    init?(bytes: [UInt8]) {
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        guard headerLength >= 20, bytes.count >= headerLength else { return nil }
        // Fragments are parsed rather than refused, so that the fields survive a
        // round trip and the caller decides. Carrying one is not something this
        // side can do -- nothing here reassembles -- so whoever handles the
        // packet has to drop a fragment it cannot complete.
        fragmentOffset = UInt16(bytes[6] & 0x1F) << 8 | UInt16(bytes[7])
        moreFragments = bytes[6] & 0x20 != 0
        let declared = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        guard declared >= headerLength, bytes.count >= declared else { return nil }

        source = VPhoneIPv4Address(UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))
        destination = VPhoneIPv4Address(UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19]))
        proto = bytes[9]
        ttl = bytes[8]
        identification = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        payload = Array(bytes[headerLength ..< declared])
    }
}

// MARK: - UDP

struct VPhoneUDPDatagram {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]

    init(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    func bytes(source: VPhoneIPv4Address, destination: VPhoneIPv4Address) -> [UInt8] {
        let length = 8 + payload.count
        var header: [UInt8] = [
            UInt8(sourcePort >> 8), UInt8(truncatingIfNeeded: sourcePort),
            UInt8(destinationPort >> 8), UInt8(truncatingIfNeeded: destinationPort),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
            0, 0,
        ]
        let datagram = header + payload
        let sum = VPhoneInternetChecksum.compute(
            datagram,
            seed: VPhoneInternetChecksum.pseudoHeader(source: source, destination: destination, proto: 17, length: length),
        )
        // A computed zero is transmitted as all ones (RFC 768).
        header[6] = UInt8((sum == 0 ? 0xFFFF : sum) >> 8)
        header[7] = UInt8((sum == 0 ? 0xFFFF : sum) & 0xFF)
        return header + payload
    }

    init?(bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        sourcePort = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        destinationPort = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let length = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        guard length >= 8, bytes.count >= length else { return nil }
        payload = Array(bytes[8 ..< length])
    }
}

extension VPhoneInternetChecksum {
    /// The UDP/TCP pseudo-header, folded into the running sum.
    static func pseudoHeader(source: VPhoneIPv4Address, destination: VPhoneIPv4Address, proto: UInt8, length: Int) -> UInt32 {
        var sum: UInt32 = 0
        let sourceBytes = source.bytes
        let destinationBytes = destination.bytes
        for index in stride(from: 0, to: 4, by: 2) {
            sum += UInt32(sourceBytes[index]) << 8 | UInt32(sourceBytes[index + 1])
            sum += UInt32(destinationBytes[index]) << 8 | UInt32(destinationBytes[index + 1])
        }
        sum += UInt32(proto)
        sum += UInt32(length)
        return sum
    }
}

// MARK: - TCP

/// The control bits this stack looks at, as they appear in the segment's flags
/// byte.
enum VPhoneTCPFlags {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10
}

/// A TCP segment, header and payload.
///
/// Only the fields this stack needs. Incoming options are parsed past but not
/// retained: a guest is free to send SACK-permitted or a timestamp, and the
/// correct response from a peer that never offered them is to ignore them —
/// which is what discarding them amounts to. We never send options.
struct VPhoneTCPSegment {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequenceNumber: UInt32
    var acknowledgmentNumber: UInt32
    var flags: UInt8
    var windowSize: UInt16
    var payload: [UInt8]
    /// The peer's maximum segment size, when its SYN carried option 2.
    ///
    /// Not optional by accident: without it we have to assume RFC 1122's default
    /// of 536, which is safe but slow. With it we know how large a segment the
    /// guest will accept, which is the whole reason this stack can send anything
    /// larger than one MTU at a time.
    var maximumSegmentSize: Int?
    /// Our own MSS, advertised on SYN-ACK. Set when we build the handshake.
    var advertisedMSS: Int?
    /// The peer's window scale, when its SYN carried option 3.
    ///
    /// Window scaling exists because a 16-bit field cannot express a window large
    /// enough for a fat, long path. Both ends must offer it or neither uses it,
    /// so a peer that finds no option 3 in our SYN-ACK has to keep its receive
    /// window under 65535 -- and that ceiling, divided by the round-trip time, is
    /// the most this connection can ever carry.
    var windowScale: Int?
    /// Our own window scale, advertised on SYN-ACK so the guest may use a large
    /// window. Only set when the guest offered one too.
    var advertisedWindowScale: Int?

    init(
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: UInt8,
        windowSize: UInt16,
        payload: [UInt8] = [],
        maximumSegmentSize: Int? = nil,
        advertisedMSS: Int? = nil,
        windowScale: Int? = nil,
        advertisedWindowScale: Int? = nil,
    ) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.sequenceNumber = sequenceNumber
        self.acknowledgmentNumber = acknowledgmentNumber
        self.flags = flags
        self.windowSize = windowSize
        self.payload = payload
        self.maximumSegmentSize = maximumSegmentSize
        self.advertisedMSS = advertisedMSS
        self.windowScale = windowScale
        self.advertisedWindowScale = advertisedWindowScale
    }

    var hasSYN: Bool {
        flags & VPhoneTCPFlags.syn != 0
    }

    var hasACK: Bool {
        flags & VPhoneTCPFlags.ack != 0
    }

    var hasFIN: Bool {
        flags & VPhoneTCPFlags.fin != 0
    }

    var hasRST: Bool {
        flags & VPhoneTCPFlags.rst != 0
    }

    /// Sequence space this segment occupies. A SYN or FIN each cost one, which
    /// matters when acknowledging them.
    var sequenceLength: UInt32 {
        UInt32(payload.count) + (hasSYN ? 1 : 0) + (hasFIN ? 1 : 0)
    }

    func bytes(source: VPhoneIPv4Address, destination: VPhoneIPv4Address) -> [UInt8] {
        // Option 2 (maximum segment size) and option 3 (window scale), each only
        // when asked. The list is padded to a 32-bit boundary, which is what the
        // data offset counts in.
        var options: [UInt8] = []
        if let advertisedMSS {
            options += [2, 4, UInt8(truncatingIfNeeded: advertisedMSS >> 8), UInt8(truncatingIfNeeded: advertisedMSS)]
        }
        if let advertisedWindowScale {
            options += [3, 3, UInt8(truncatingIfNeeded: advertisedWindowScale)]
            while options.count % 4 != 0 {
                options.append(1)
            } // NOP padding
        }
        let headerLength = 20 + options.count
        var header: [UInt8] = [
            UInt8(sourcePort >> 8), UInt8(truncatingIfNeeded: sourcePort),
            UInt8(destinationPort >> 8), UInt8(truncatingIfNeeded: destinationPort),
            UInt8(truncatingIfNeeded: sequenceNumber >> 24), UInt8(truncatingIfNeeded: sequenceNumber >> 16),
            UInt8(truncatingIfNeeded: sequenceNumber >> 8), UInt8(truncatingIfNeeded: sequenceNumber),
            UInt8(truncatingIfNeeded: acknowledgmentNumber >> 24), UInt8(truncatingIfNeeded: acknowledgmentNumber >> 16),
            UInt8(truncatingIfNeeded: acknowledgmentNumber >> 8), UInt8(truncatingIfNeeded: acknowledgmentNumber),
            UInt8(headerLength / 4) << 4, // data offset, in 32-bit words
            flags,
            UInt8(windowSize >> 8), UInt8(truncatingIfNeeded: windowSize),
            0, 0, // checksum
            0, 0, // urgent pointer
        ]
        header += options
        let whole = header + payload
        let sum = VPhoneInternetChecksum.compute(
            whole,
            seed: VPhoneInternetChecksum.pseudoHeader(source: source, destination: destination, proto: 6, length: whole.count),
        )
        // A computed zero is transmitted as all ones (RFC 793).
        let checksum = sum == 0 ? 0xFFFF : sum
        header[16] = UInt8(checksum >> 8)
        header[17] = UInt8(checksum & 0xFF)
        return header + payload
    }

    init?(bytes: [UInt8]) {
        guard bytes.count >= 20 else { return nil }
        sourcePort = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        destinationPort = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        sequenceNumber = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        acknowledgmentNumber = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        let headerLength = Int(bytes[12] >> 4) * 4
        guard headerLength >= 20, bytes.count >= headerLength else { return nil }
        flags = bytes[13]
        windowSize = UInt16(bytes[14]) << 8 | UInt16(bytes[15])
        payload = Array(bytes[headerLength...])
        let parsed = Self.options(in: Array(bytes[20 ..< headerLength]))
        maximumSegmentSize = parsed.mss
        windowScale = parsed.windowScale
    }

    /// The options we care about, read in one pass.
    ///
    /// Option 2 carries the peer's MSS and option 3 its window scale; everything
    /// else is skipped by its length. A malformed list ends the walk rather than
    /// guessing -- a peer that sends a broken option gets the RFC 1122 MSS
    /// default and no window scaling, which is the safe direction both times.
    private static func options(in options: [UInt8]) -> (mss: Int?, windowScale: Int?) {
        var mss: Int?
        var windowScale: Int?
        var index = 0
        while index < options.count {
            let kind = options[index]
            if kind == 0 {
                break
            } // end of options
            if kind == 1 {
                index += 1; continue
            } // no-op padding
            guard index + 1 < options.count else { break }
            let length = Int(options[index + 1])
            guard length >= 2, index + length <= options.count else { break }
            if kind == 2, length == 4 {
                mss = Int(UInt16(options[index + 2]) << 8 | UInt16(options[index + 3]))
            } else if kind == 3, length == 3 {
                windowScale = Int(options[index + 2])
            }
            index += length
        }
        return (mss, windowScale)
    }
}
