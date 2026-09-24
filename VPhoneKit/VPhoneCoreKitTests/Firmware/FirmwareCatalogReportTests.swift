import Foundation
import Testing
@testable import VPhoneCoreKit

struct FirmwareCatalogReportTests {
    @Test func `maps every pairing`() {
        let report = VPhoneFirmwareCatalog.report
        #expect(report.device == VPhoneFirmwareCatalog.device)
        #expect(report.pairings.count == VPhoneFirmwareCatalog.pairings.count)

        for (entry, pairing) in zip(report.pairings, VPhoneFirmwareCatalog.pairings) {
            #expect(entry.ios.name == pairing.iosName)
            #expect(entry.ios.url == pairing.iosURL)
            #expect(entry.recommendedCloudOS.name == pairing.cloudosName)
            #expect(entry.recommendedCloudOS.url == pairing.cloudosURL)
        }
    }

    @Test func `round trips JSON`() throws {
        let report = VPhoneFirmwareCatalog.report
        let back = try JSONDecoder().decode(VPhoneFirmwareCatalogReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
    }
}
