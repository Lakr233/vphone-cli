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

/// The watch speaker patches on watchOS 27 files: `VPHONE_WATCH27_VIRTUALAUDIO`
/// is the arm64e `VirtualAudio` of a watchOS 27 image, `VPHONE_WATCH27_GRAPH`
/// its `AID4017/VAD/graph_configurations.plist` (Watch7,18 27.2 24S116 ships
/// no HALSPP graph). Xcode passes them as `TEST_RUNNER_<name>`.
@Suite("Watch speaker payload on watchOS 27")
struct CryptexFilesystemPatcherWatchAudio27Tests {

    static let environment = ProcessInfo.processInfo.environment

    @Test("watchOS 27 has no HALSPP graph, so the plain graph is the fallback")
    func graphPreference() {
        #expect(CryptexFilesystemPatcher.watchAudioGraphFiles == [
            "graph_configurations_halspp.plist", "graph_configurations.plist",
        ])
    }

    @Test(.enabled(if: Self.environment["VPHONE_WATCH27_VIRTUALAUDIO"] != nil))
    func routingGatesAreFound() throws {
        var data = try Data(contentsOf: URL(filePath: try #require(Self.environment["VPHONE_WATCH27_VIRTUALAUDIO"])))
        try CustomFirmwareVirtualAudio.patchSpeakerProtectionGate(&data, handler: .playback, reattest: false, log: nil)
        try CustomFirmwareVirtualAudio.patchVolumeModePrecondition(&data, reattest: false, log: nil)
        try CustomFirmwareVirtualAudio.patchInactiveSpeakerProtection(&data, reattest: false, log: nil)
    }

    @Test(.enabled(if: Self.environment["VPHONE_WATCH27_GRAPH"] != nil))
    func speakerGraphsFlip() throws {
        let source = URL(filePath: try #require(Self.environment["VPHONE_WATCH27_GRAPH"]))
        let copy = FileManager.default.temporaryDirectory.appending(path: "graph-\(UUID().uuidString).plist")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let outcome = try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: copy, verbose: false)
        guard case let .rewritten(changed) = outcome else {
            Issue.record("nothing rewritten: \(outcome)")
            return
        }
        #expect(changed.count == 8)
        #expect(changed.allSatisfy { $0.hasPrefix("speaker_") })
    }
}
