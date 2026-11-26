import Foundation
import Testing
@testable import VPhoneCoreKit

struct BundleReportTests {
    @Test func `reports effective peers for a legacy fixed NAT address`() throws {
        let fixed = VPhoneNetworking.reachesPeers(.default)
        let address = VPhoneNetworkHost.current.sharedNATSubnet.firstHost
        let network = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .nat, macAddress: "00:11:22:33:44:55",
            ipv4: .init(address: VPhoneIPv4Address(address.raw + 10).description, prefixLength: VPhoneNetworkHost.current.sharedNATSubnet.prefixLength)
        )
        let manifest = VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 2 << 30, networkConfig: network, romImages: nil)
        let report = VPhoneBundleReport(bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/report"), manifest: manifest))
        #expect(network.reachesPeers == nil)
        #expect(report.network.reachesPeers == false)
        #expect(fixed)
        let decoded = try JSONDecoder().decode(VPhoneBundleReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.network.reachesPeers == false)
    }

    @Test func `maps manifest fields`() {
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 6,
            memorySize: 4 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: URL(fileURLWithPath: "/tmp/myvm"), manifest: manifest)

        let report = VPhoneBundleReport(bundle: bundle)
        #expect(report.name == "myvm")
        #expect(report.cpuCount == 6)
        #expect(report.memoryMB == 4096)
        #expect(report.network.mode == .nat)
        // Not cloned from a template.
        #expect(report.template == nil && report.templateMatch == nil)
    }

    @Test func `carries network config`() throws {
        let net = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .bridged,
            macAddress: "00:11:22:33:44:55",
            bridgeInterface: "en0",
        )
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 2 * 1024 * 1024 * 1024,
            networkConfig: net,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let report = VPhoneBundleReport(bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/b"), manifest: manifest))
        #expect(report.network.mode == .bridged)
        #expect(report.network.bridgeInterface == "en0")

        let back = try JSONDecoder().decode(VPhoneBundleReport.self, from: JSONEncoder().encode(report))
        #expect(back.network == net)
    }

    @Test func `redacts the intercept password`() throws {
        let net = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .tunnel, macAddress: "", intercept: "socks5://user:secret@host:1080",
        )
        let manifest = VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 2 << 30, networkConfig: net, romImages: nil)
        let report = VPhoneBundleReport(bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/r"), manifest: manifest))
        #expect(report.network.intercept == "socks5://user:***@host:1080")
        let json = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("secret"))
        #expect(manifest.networkConfig.intercept == "socks5://user:secret@host:1080")
    }

    @Test func `reports no intercept when none is set`() {
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 2 << 30,
            networkConfig: .init(mode: .tunnel, macAddress: ""), romImages: nil,
        )
        let report = VPhoneBundleReport(bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/r"), manifest: manifest))
        #expect(report.network.intercept == nil)
    }

    @Test func `encodes to JSON`() throws {
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 2 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let report = VPhoneBundleReport(bundle: VPhoneBundle(url: URL(fileURLWithPath: "/tmp/x"), manifest: manifest))
        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(VPhoneBundleReport.self, from: data)
        #expect(back == report)
    }
}
