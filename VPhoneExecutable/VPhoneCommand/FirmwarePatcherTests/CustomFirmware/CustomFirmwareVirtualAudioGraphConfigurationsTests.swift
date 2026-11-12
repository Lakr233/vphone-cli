// CustomFirmwareVirtualAudioGraphConfigurationsTests.swift — the speaker-chain
// flip in graph_configurations.plist.
//
// The plist's real shape is fixed by the iPadOS image (Configurations →
// speaker_* → chainType "clhs", mic configurations on "dflt"), so the
// synthetic fixtures below mirror it name for name. The patcher's contract
// is what needs holding: every speaker_* flips, nothing else moves, the
// file's format survives, a re-run writes nothing, a set with no speaker
// configuration is left alone, and anything unexpected refuses rather than
// half-patches.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("CustomFirmwareVirtualAudioGraphConfigurations")
struct CustomFirmwareVirtualAudioGraphConfigurationsTests {
    /// The shape the tuning set ships: CommonData, the speaker configurations
    /// on `clhs`, mic configurations on `dflt` — names as the real plist
    /// carries them, so the prefix match is exercised against the exact keys
    /// it will meet on a guest.
    static func tuningSet() -> [String: Any] {
        func configuration(_ chainType: String, graph: String) -> [String: Any] {
            ["chainType": chainType, "graph": graph, "austrip": graph,
             "busChannelCounts": [[2, 8]], "properties": [["ID": "iods"]]]
        }
        return [
            "CommonData": [
                "presetPath": "/Library/Audio/Tunings/AID2029/AU",
                "tuningPath": "/Library/Audio/Tunings/AID2029/VAD",
                "tuningFilePrefix": "",
            ],
            "Configurations": [
                "speaker_ringtone": configuration("clhs", graph: "speaker_general"),
                "speaker_general": configuration("clhs", graph: "speaker_general"),
                "speaker_raw": configuration("clhs", graph: "speaker_raw"),
                "beamformed_mic_general": configuration("dflt", graph: "beam_mic_general"),
                "stereo_recording": configuration("dflt", graph: "stereo_recording_no_tap"),
            ],
        ]
    }

    private func writeTemporary(_ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> URL {
        let directory = try CustomFirmwarePatchFixtures.makeTemporaryDirectory()
        let url = directory.appending(path: "graph_configurations.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url)
        return url
    }

    @Test
    func `flips every speaker chain and leaves the rest of the file alone`() throws {
        let url = try writeTemporary(Self.tuningSet())
        let outcome = try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        #expect(outcome == .rewritten(changed: ["speaker_general", "speaker_raw", "speaker_ringtone"]))

        let patched = try PlistComparison.load(url) as? [String: Any]
        let configurations = patched?["Configurations"] as? [String: Any]
        #expect((configurations?["speaker_ringtone"] as? [String: Any])?["chainType"] as? String == "dflt")
        #expect((configurations?["speaker_raw"] as? [String: Any])?["chainType"] as? String == "dflt")
        // A mic configuration already on dflt, and a speaker graph, are untouched.
        #expect((configurations?["beamformed_mic_general"] as? [String: Any])?["chainType"] as? String == "dflt")
        #expect((configurations?["speaker_ringtone"] as? [String: Any])?["graph"] as? String == "speaker_general")
        // CommonData is carried as it went in.
        #expect((patched?["CommonData"] as? [String: Any])?.count == 3)

        // The only difference from the input is the flipped chainTypes.
        var expected = Self.tuningSet()
        var expectedConfigurations = try #require(expected["Configurations"] as? [String: Any])
        for name in ["speaker_ringtone", "speaker_general", "speaker_raw"] {
            var entry = try #require(expectedConfigurations[name] as? [String: Any])
            entry["chainType"] = "dflt"
            expectedConfigurations[name] = entry
        }
        expected["Configurations"] = expectedConfigurations
        let difference = PlistComparison.difference(patched ?? [:], expected)
        #expect(difference == nil, "unexpected differences beyond the flipped chainTypes: \(difference ?? "")")
    }

    @Test
    func `keeps the plist's format — binary in, binary out`() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let url = try writeTemporary(Self.tuningSet(), format: format)
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
            let bytes = try Data(contentsOf: url)
            #expect(CustomFirmwareVirtualAudioGraphConfigurations.detectFormat(bytes) == format)
        }
    }

    @Test
    func `is idempotent and honours dry run`() throws {
        let url = try writeTemporary(Self.tuningSet())
        let dry = try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, dryRun: true, verbose: false)
        #expect(dry == .dryRun(changed: ["speaker_general", "speaker_raw", "speaker_ringtone"]))
        let untouched = try Data(contentsOf: url)

        try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        let written = try Data(contentsOf: url)
        #expect(written != untouched)

        let again = try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        #expect(again == .alreadyGraphChains(["speaker_general", "speaker_raw", "speaker_ringtone"]))
        #expect(try Data(contentsOf: url) == written)
    }

    @Test(
        arguments: [
            "not a plist at all",
            "{\"Configurations\": {\"speaker_ringtone\": {\"chainType\": \"sprt\"}}}",
        ],
    )
    func `refuses plists it does not understand, not searched past`(_ text: String) throws {
        let url = try writeTemporary(["placeholder": true])
        try Data(text.utf8).write(to: url)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test
    func `leaves a set with only microphone chains alone`() throws {
        let url = try writeTemporary([
            "Configurations": [
                "back_mic_general": ["chainType": "dflt", "graph": "back_mic_general"],
                "beamformed_mic_general": ["chainType": "dflt", "graph": "beam_mic_general"],
            ],
        ])
        let before = try Data(contentsOf: url)
        let outcome = try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        #expect(outcome == .alreadyGraphChains([]))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test
    func `refuses a speaker chain on an unknown chainType`() throws {
        var plist = Self.tuningSet()
        var configurations = try #require(plist["Configurations"] as? [String: Any])
        configurations["speaker_siri"] = ["chainType": "sprt", "graph": "speaker_general"]
        plist["Configurations"] = configurations
        let url = try writeTemporary(plist)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test
    func `refuses a plist without the Configurations dict`() throws {
        let url = try writeTemporary(["CommonData": ["tuningPath": "/x"]])
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test
    func `the anchor keys are the ones the tuning set ships`() {
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.speakerChainType == "clhs")
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.graphChainType == "dflt")
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.configurationsKey == "Configurations")
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.chainTypeKey == "chainType")
    }

    // MARK: - Raw speaker chain

    /// The D47 set's speaker configurations: each names a chain by its
    /// tunings and by the graph parameter its volume goes to.
    static func speakerSet(raw: Bool = true) -> [String: Any] {
        func speaker(graph: String, austrip: String, volume: String) -> [String: Any] {
            ["chainType": "dflt", "graph": graph, "austrip": austrip, "propstrip": graph,
             "volumeCommands": [volume], "properties": [["ID": "spim"]]]
        }
        var configurations: [String: Any] = [
            "speaker_general": speaker(graph: "speaker_general", austrip: "speaker_general", volume: "vtvs"),
            "speaker_ringtone": speaker(graph: "speaker_general", austrip: "speaker_ringtone", volume: "vtvs"),
            "speaker_measurement": speaker(graph: "speaker_measurement", austrip: "speaker_measurement", volume: "vugd"),
            "bottom_mic_general": ["chainType": "dflt", "graph": "bottom_mic_general"],
        ]
        if raw {
            configurations["speaker_raw"] = speaker(graph: "speaker_raw", austrip: "speaker_measurement", volume: "vugd")
        }
        return ["Configurations": configurations]
    }

    static func configurations(at url: URL) throws -> [String: [String: Any]] {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require((plist as? [String: Any])?["Configurations"] as? [String: [String: Any]])
    }

    static func writeSpeakerSet(_ set: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-speaker-\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: set, format: .binary, options: 0).write(to: url)
        return url
    }

    @Test func `every speaker chain becomes the raw one`() throws {
        let url = try Self.writeSpeakerSet(Self.speakerSet())
        defer { try? FileManager.default.removeItem(at: url) }

        let changed = try CustomFirmwareVirtualAudioGraphConfigurations.useRawSpeakerChain(at: url, verbose: false)
        #expect(changed == ["speaker_general", "speaker_ringtone"])

        let patched = try Self.configurations(at: url)
        let original = try #require(Self.speakerSet()["Configurations"] as? [String: [String: Any]])
        for name in changed {
            #expect(patched[name]?["graph"] as? String == "speaker_raw")
            #expect(patched[name]?["austrip"] as? String == "speaker_measurement")
            #expect(patched[name]?["propstrip"] as? String == "speaker_raw")
            #expect(patched[name]?["volumeCommands"] as? [String] == ["vugd"])
            // What is not the chain stays the configuration's own.
            #expect((patched[name]?["properties"] as? [[String: Any]])?.count == 1)
            #expect(patched[name]?["chainType"] as? String == "dflt")
        }
        for name in ["speaker_raw", "speaker_measurement", "bottom_mic_general"] {
            #expect(try NSDictionary(dictionary: #require(patched[name])) == NSDictionary(dictionary: #require(original[name])))
        }
    }

    @Test func `a second run on raw speaker chains writes nothing`() throws {
        let url = try Self.writeSpeakerSet(Self.speakerSet())
        defer { try? FileManager.default.removeItem(at: url) }
        try CustomFirmwareVirtualAudioGraphConfigurations.useRawSpeakerChain(at: url, verbose: false)
        let once = try Data(contentsOf: url)

        #expect(try CustomFirmwareVirtualAudioGraphConfigurations.useRawSpeakerChain(at: url, verbose: false).isEmpty)
        #expect(try Data(contentsOf: url) == once)
    }

    @Test func `a set with no raw speaker chain is left alone`() throws {
        let url = try Self.writeSpeakerSet(Self.speakerSet(raw: false))
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(try CustomFirmwareVirtualAudioGraphConfigurations.useRawSpeakerChain(at: url, verbose: false).isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func `a dry run names the speaker chains and writes nothing`() throws {
        let url = try Self.writeSpeakerSet(Self.speakerSet())
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        let changed = try CustomFirmwareVirtualAudioGraphConfigurations.useRawSpeakerChain(at: url, dryRun: true, verbose: false)
        #expect(changed == ["speaker_general", "speaker_ringtone"])
        #expect(try Data(contentsOf: url) == before)
    }
}
