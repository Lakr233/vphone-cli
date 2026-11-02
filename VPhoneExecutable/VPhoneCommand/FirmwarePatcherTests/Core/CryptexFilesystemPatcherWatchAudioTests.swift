// CryptexFilesystemPatcherWatchAudioTests.swift — selection coverage for
// `filesystem-exp-watch_audio`.
//
// The watch speaker payload is gated by CryptexFilesystemPatcher.applies(_:),
// which answers `guestFamily == .watch` for this step. This asserts that the
// product gate records the payload only for a watch restore image and never for
// an iPhone, an Apple TV, an unknown product, or a missing manifest. The
// preset-to-plan side of selection lives in FirmwarePatchSetCatalogTests; the
// VirtualAudio executable bypasses live in CustomFirmwareVirtualAudioTests.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Watch speaker payload selection")
struct CryptexFilesystemPatcherWatchAudioTests {

    @Test("The watch speaker payload is recorded only for a watch restore image")
    func watchAudioRequiresWatchImage() throws {
        let identifier = FirmwareRestoreImagePatchSet.watchAudio
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = root.appending(path: "iPhone-BuildManifest.plist")
        for product in ["Watch7,18", "iPhone17,3", "AppleTV5,3", "unknown"] {
            try PropertyListSerialization.data(
                fromPropertyList: ["SupportedProductTypes": [product]], format: .xml, options: 0,
            ).write(to: manifest)
            let records = try makePatcher(root).findAll()
            #expect(records.contains { $0.patchID == identifier } == (product == "Watch7,18"))
        }

        try FileManager.default.removeItem(at: manifest)
        #expect(try !makePatcher(root).findAll().contains { $0.patchID == identifier })
    }
}
