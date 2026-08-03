@testable import VPhoneCore
import Foundation
import Testing

struct BundleReportTests {
    @Test func mapsManifestFields() throws {
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 6, memorySize: 4 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        let bundle = VPhoneBundle(url: URL(fileURLWithPath: "/tmp/myvm"), manifest: manifest)

        let report = VPhoneBundleReport(bundle: bundle)
        #expect(report.name == "myvm")
        #expect(report.cpuCount == 6)
        #expect(report.memoryMB == 4096)
        #expect(report.network.mode == .nat)
    }

    @Test func carriesNetworkConfig() throws {
        let net = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .bridged, macAddress: "00:11:22:33:44:55", bridgeInterface: "en0")
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 2 * 1024 * 1024 * 1024,
            networkConfig: net,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        let report = VPhoneBundleReport(
            bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/b"), manifest: manifest))
        #expect(report.network.mode == .bridged)
        #expect(report.network.bridgeInterface == "en0")

        let back = try JSONDecoder().decode(
            VPhoneBundleReport.self, from: try JSONEncoder().encode(report))
        #expect(back.network == net)
    }

    @Test func encodesToJSON() throws {
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 2 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        let report = VPhoneBundleReport(
            bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/x"), manifest: manifest))
        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(VPhoneBundleReport.self, from: data)
        #expect(back == report)
    }
}
