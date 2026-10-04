// CustomFirmwareVirtualAudioGraphConfigurationsTests.swift — the speaker-chain
// flip in graph_configurations.plist.
//
// The plist's real shape is fixed by the iPadOS image (Configurations →
// speaker_* → chainType "clhs", mic configurations on "dflt"), so the
// synthetic fixtures below mirror it name for name. The patcher's contract
// is what needs holding: every speaker_* flips, nothing else moves, the
// file's format survives, a re-run writes nothing, and anything unexpected
// refuses rather than half-patches.

import Foundation
import Testing
@testable import FirmwarePatcher
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

    @Test("flips every speaker chain and leaves the rest of the file alone")
    func flipsSpeakerChains() throws {
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
        var expectedConfigurations = expected["Configurations"] as! [String: Any]
        for name in ["speaker_ringtone", "speaker_general", "speaker_raw"] {
            var entry = expectedConfigurations[name] as! [String: Any]
            entry["chainType"] = "dflt"
            expectedConfigurations[name] = entry
        }
        expected["Configurations"] = expectedConfigurations
        let difference = PlistComparison.difference(patched ?? [:], expected)
        #expect(difference == nil, "unexpected differences beyond the flipped chainTypes: \(difference ?? "")")
    }

    @Test("keeps the plist's format — binary in, binary out")
    func preservesFormat() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let url = try writeTemporary(Self.tuningSet(), format: format)
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
            let bytes = try Data(contentsOf: url)
            #expect(CustomFirmwareVirtualAudioGraphConfigurations.detectFormat(bytes) == format)
        }
    }

    @Test("is idempotent and honours dry run")
    func idempotentAndDryRun() throws {
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

    @Test("refuses plists it does not understand, not searched past",
          arguments: [
        "not a plist at all",
        "{\"Configurations\": {\"speaker_ringtone\": {\"chainType\": \"sprt\"}}}",
    ])
    func refusesUnexpectedInput(_ text: String) throws {
        let url = try writeTemporary(["placeholder": true])
        try Data(text.utf8).write(to: url)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test("refuses a speaker chain on an unknown chainType")
    func refusesUnknownChainType() throws {
        var plist = Self.tuningSet()
        var configurations = plist["Configurations"] as! [String: Any]
        configurations["speaker_siri"] = ["chainType": "sprt", "graph": "speaker_general"]
        plist["Configurations"] = configurations
        let url = try writeTemporary(plist)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test("refuses a plist with no speaker configurations")
    func refusesNoSpeakerConfigurations() throws {
        let micOnly: [String: Any] = [
            "CommonData": ["tuningPath": "/Library/Audio/Tunings/AID2029/VAD"],
            "Configurations": ["beamformed_mic_general": ["chainType": "dflt", "graph": "beam_mic_general"]],
        ]
        let url = try writeTemporary(micOnly)
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test("refuses a plist without the Configurations dict")
    func refusesMissingConfigurations() throws {
        let url = try writeTemporary(["CommonData": ["tuningPath": "/x"]])
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudioGraphConfigurations.patch(at: url, verbose: false)
        }
    }

    @Test("the anchor keys are the ones the tuning set ships")
    func keysAreStable() {
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.speakerChainType == "clhs")
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.graphChainType == "dflt")
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.configurationsKey == "Configurations")
        #expect(CustomFirmwareVirtualAudioGraphConfigurations.chainTypeKey == "chainType")
    }
}
