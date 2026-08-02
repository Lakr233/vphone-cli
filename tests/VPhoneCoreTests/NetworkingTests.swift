@testable import VPhoneCore
import Foundation
import Testing
import Virtualization

struct NetworkingTests {
    typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig

    @Test func mergeSetsMode() throws {
        let out = try VPhoneNetworking.merge(into: .default, mode: .off, bridgeInterface: nil)
        #expect(out.mode == .off)
        #expect(out.bridgeInterface == nil)
    }

    @Test func mergeWithoutModePreservesCurrent() throws {
        let current = NetworkConfig(mode: .off, macAddress: "")
        let out = try VPhoneNetworking.merge(into: current, mode: nil, bridgeInterface: nil)
        #expect(out.mode == .off)
    }

    @Test func mergeRejectsHostOnly() {
        #expect(throws: VPhoneNetworkingError.hostOnlyUnsupported) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .hostOnly, bridgeInterface: nil)
        }
    }

    @Test func mergeRejectsBridgeInterfaceWithoutBridgedMode() {
        #expect(throws: VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .nat, bridgeInterface: "en0")
        }
    }

    // The test binary is unsigned, so no interfaces are available for bridging:
    // selecting bridged must fail loudly rather than silently produce a dead NIC.
    @Test func bridgedWithoutAvailableInterfacesThrows() {
        guard VPhoneNetworking.availableBridgeInterfaces().isEmpty else { return }
        #expect(throws: VPhoneNetworkingError.self) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .bridged, bridgeInterface: nil)
        }
        #expect(throws: VPhoneNetworkingError.self) {
            _ = try VPhoneNetworking.merge(into: .default, mode: .bridged, bridgeInterface: "en0")
        }
    }

    @Test func makeNetworkDeviceOffIsNil() throws {
        let dev = try VPhoneNetworking.makeNetworkDevice(NetworkConfig(mode: .off, macAddress: ""))
        #expect(dev == nil)
    }

    @Test func makeNetworkDeviceNATHasAttachment() throws {
        let dev = try VPhoneNetworking.makeNetworkDevice(NetworkConfig(mode: .nat, macAddress: ""))
        #expect(dev != nil)
        #expect(dev?.attachment is VZNATNetworkDeviceAttachment)
    }
}
