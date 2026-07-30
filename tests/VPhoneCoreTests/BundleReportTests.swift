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
