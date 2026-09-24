import Foundation
import Testing
import Virtualization
@testable import VPhoneCoreKit

struct NetworkingTests {
    typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig

    @Test func `merge sets mode`() throws {
        let out = try VPhoneNetworking.merge(into: .default, mode: .off, bridgeInterface: nil)
        #expect(out.mode == .off)
        #expect(out.bridgeInterface == nil)
    }

    @Test func `merge without mode preserves current`() throws {
        let current = NetworkConfig(mode: .off, macAddress: "")
        let out = try VPhoneNetworking.merge(into: current, mode: nil, bridgeInterface: nil)
        #expect(out.mode == .off)
    }

    @Test func `merge rejects host only`() {
        #expect(throws: VPhoneNetworkingError.hostOnlyUnsupported) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .hostOnly, bridgeInterface: nil)
        }
    }

    @Test func `merge rejects bridge interface without bridged mode`() {
        #expect(throws: VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .nat, bridgeInterface: "en0")
        }
    }

    /// The test binary is unsigned, so no interfaces are available for bridging:
    /// selecting bridged must fail loudly rather than silently produce a dead NIC.
    @Test func `bridged without available interfaces throws`() {
        guard VPhoneNetworking.availableBridgeInterfaces().isEmpty else { return }
        #expect(throws: VPhoneNetworkingError.self) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .bridged, bridgeInterface: nil)
        }
        #expect(throws: VPhoneNetworkingError.self) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .bridged, bridgeInterface: "en0")
        }
    }

    @Test func `make network device off is nil`() throws {
        let dev = try VPhoneNetworking.makeNetworkDevice(NetworkConfig(mode: .off, macAddress: ""))
        #expect(dev == nil)
    }

    @Test func `make network device NAT has attachment`() throws {
        let dev = try VPhoneNetworking.makeNetworkDevice(NetworkConfig(mode: .nat, macAddress: ""))
        #expect(dev != nil)
        #expect(dev?.attachment is VZNATNetworkDeviceAttachment)
    }
}
