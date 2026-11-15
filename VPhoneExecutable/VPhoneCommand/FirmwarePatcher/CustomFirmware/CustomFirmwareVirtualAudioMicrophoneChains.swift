// CustomFirmwareVirtualAudioMicrophoneChains.swift — microphone chains without
// the board's dynamics in graph_configurations.plist.
//
// A tuning set gives each built-in microphone a `<mic>_general` configuration
// for ordinary recording and a `<mic>_measurement` one for
// AVAudioSessionModeMeasurement. On the D47 set (AID8018) the general graph is
// microphone correction, a channel selector, an equalizer, a loudness
// normalizer, a multiband compressor and a limiter; the measurement graph
// stops after the correction, the selector and two equalizers.
//
// The general chain's gain and dynamics are tuned to the sensitivity of the
// board's own microphone. A VM's microphone is the Mac's, which arrives
// already at the level macOS set. Measured on an iPhone guest: the chain adds
// about 8 dB across the whole band, speech reaches the limiter (-0.6 dBFS
// peaks) and the capture's noise floor goes from -47 to -37 dBFS, most of it
// rumble below 120 Hz — a recording that sounds like wind. An iPad guest's
// set (AID2019) routes the same microphone through no processing at all, and
// its recordings are the Mac's capture as it is.
//
// Each `<mic>_general` configuration with a `<mic>_measurement` sibling takes
// the sibling's `graph`, `austrip` and `propstrip`; everything else in the
// entry stays, so the route still finds its channel map and its properties.
// The tuning files themselves are not touched. See
// `Research/Guest/virtio_sound_microphone.md`.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// Points every `<mic>_general` configuration in a `graph_configurations.plist`
/// at its `<mic>_measurement` sibling's tunings.
public enum CustomFirmwareVirtualAudioMicrophoneChains {
    static let configurationsKey = "Configurations"

    /// What marks a microphone configuration (`bottom_mic_general`,
    /// `bottom_mic2_general`; not `speaker_general`), and the suffix of an
    /// ordinary recording configuration and of the measurement one it is
    /// paired with.
    static let microphoneMark = "_mic"
    static let generalSuffix = "_general"
    static let measurementSuffix = "_measurement"

    /// The keys naming a configuration's tuning files.
    static let tuningKeys = ["graph", "austrip", "propstrip"]

    /// What a patch attempt did.
    public enum Outcome: Sendable, Equatable {
        /// The set pairs no general configuration with a measurement one.
        case noPairs
        /// Every paired configuration already names its sibling's tunings.
        case alreadyMeasurementChains([String])
        /// Entries would change but `dryRun` suppressed the write.
        case dryRun(changed: [String])
        /// The file was rewritten with the changed entries.
        case rewritten(changed: [String])

        /// True only when bytes landed on disk.
        public var didWrite: Bool {
            if case .rewritten = self {
                return true
            }
            return false
        }
    }

    // MARK: - Patching

    /// Give every `<mic>_general` configuration at `url` its
    /// `<mic>_measurement` sibling's tunings.
    ///
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when the file is not a
    ///   plist, its root is not a dictionary, `Configurations` is missing or
    ///   not a dictionary, or one of a pair is not a dictionary or names no
    ///   `graph`. A set with no pairs is not an error: not every board has
    ///   them.
    @discardableResult
    public static func patch(
        at url: URL,
        dryRun: Bool = false,
        verbose: Bool = true,
    ) throws -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOfFileToRewrite: url)
        } catch {
            throw PatcherError.fileNotFound(url.path)
        }
        let format = CustomFirmwareBuildVersion.detectFormat(data)

        guard let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            throw PatcherError.invalidFormat("cannot parse as plist: \(url.path)")
        }
        guard let plist = parsed as? [String: Any] else {
            throw PatcherError.invalidFormat("top-level plist is \(type(of: parsed)), expected dict: \(url.path)")
        }
        guard var configurations = plist[configurationsKey] as? [String: Any] else {
            throw PatcherError.invalidFormat("no '\(configurationsKey)' dict present: \(url.path)")
        }

        func entry(_ name: String) throws -> [String: Any] {
            guard let entry = configurations[name] as? [String: Any] else {
                throw PatcherError.invalidFormat(
                    "configuration '\(name)' is \(type(of: configurations[name])), expected dict: \(url.path)",
                )
            }
            guard entry["graph"] is String else {
                throw PatcherError.invalidFormat("configuration '\(name)' has no 'graph' string: \(url.path)")
            }
            return entry
        }

        var paired: [String] = []
        var changed: [String] = []
        for name in configurations.keys.sorted() where name.contains(microphoneMark) && name.hasSuffix(generalSuffix) {
            let sibling = String(name.dropLast(generalSuffix.count)) + measurementSuffix
            guard configurations[sibling] != nil else { continue }
            paired.append(name)
            var general = try entry(name)
            let measurement = try entry(sibling)
            var differs = false
            for key in tuningKeys {
                let wanted = measurement[key] as? String
                guard general[key] as? String != wanted else { continue }
                differs = true
                general[key] = wanted
            }
            guard differs else { continue }
            changed.append(name)
            configurations[name] = general
            if verbose {
                VPhoneConsole.shared.line("  [+] \(url.lastPathComponent): \(name) takes the tunings of \(sibling)")
            }
        }

        if paired.isEmpty {
            if verbose {
                VPhoneConsole.shared.line("  [.] \(url.lastPathComponent): no general microphone chain has a measurement sibling")
            }
            return .noPairs
        }
        if changed.isEmpty {
            if verbose {
                VPhoneConsole.shared.line("  [.] \(url.lastPathComponent): \(paired.count) microphone chains already on measurement tunings")
            }
            return .alreadyMeasurementChains(paired)
        }
        if dryRun {
            if verbose {
                VPhoneConsole.shared.line("  [.] dry-run — not writing back")
            }
            return .dryRun(changed: changed)
        }

        var patched = plist
        patched[configurationsKey] = configurations
        let output = try PropertyListSerialization.data(fromPropertyList: patched, format: format, options: 0)
        try output.write(to: url)
        return .rewritten(changed: changed)
    }

    // MARK: - Measurement gain

    /// One equalizer whose global gain `neutralizeGain` set to 0 dB.
    public struct GainChange: Sendable, Equatable {
        /// The effect's `displayname` in the strip.
        public let effect: String
        /// The gain it had, in decibels.
        public let before: Float
    }

    /// `aufx`/`nbeq`: AUNBandEQ, whose parameter 0 is its global gain.
    static let bandEqualizerSubtype: UInt32 = 0x6E62_6571
    static let globalGainParameter: UInt32 = 0

    /// Set the global gain of every AUNBandEQ in the `.austrip` at `url` to
    /// 0 dB, and return the ones that changed.
    ///
    /// A measurement strip's equalizers shape nothing the Mac's microphone
    /// needs, but one of them carries the digital gain of the board's own
    /// microphone: +18 dB on the D47's `bottom_mic_measurement`. The Mac's
    /// capture is already at the level macOS set, so with that gain speech
    /// passes full scale (measured: +14 dBFS peaks) and the recording clips.
    ///
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when the file is not a
    ///   plist of `strips` → `effects`, or an equalizer's preset data is not
    ///   whole (scope, element, count, then `count` parameter pairs) records.
    @discardableResult
    public static func neutralizeGain(
        at url: URL,
        dryRun: Bool = false,
        verbose: Bool = true,
    ) throws -> [GainChange] {
        let data: Data
        do {
            data = try Data(contentsOfFileToRewrite: url)
        } catch {
            throw PatcherError.fileNotFound(url.path)
        }
        let format = CustomFirmwareBuildVersion.detectFormat(data)
        guard
            var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
            var strips = plist["strips"] as? [[String: Any]]
        else {
            throw PatcherError.invalidFormat("not a plist with a 'strips' array: \(url.path)")
        }

        var changes: [GainChange] = []
        for stripIndex in strips.indices {
            guard var effects = strips[stripIndex]["effects"] as? [[String: Any]] else {
                throw PatcherError.invalidFormat("strip \(stripIndex) has no 'effects' array: \(url.path)")
            }
            for effectIndex in effects.indices {
                guard
                    let unit = effects[effectIndex]["unit"] as? [String: Any],
                    (unit["subtype"] as? NSNumber)?.uint32Value == bandEqualizerSubtype,
                    var preset = effects[effectIndex]["aupreset"] as? [String: Any],
                    let state = preset["data"] as? Data
                else { continue }
                let name = effects[effectIndex]["displayname"] as? String ?? "effect \(effectIndex)"
                guard let (patched, before) = try withoutGlobalGain(state, effect: name, path: url.path) else {
                    continue
                }
                preset["data"] = patched
                effects[effectIndex]["aupreset"] = preset
                changes.append(GainChange(effect: name, before: before))
                if verbose {
                    VPhoneConsole.shared.line("  [+] \(url.lastPathComponent): \(name) global gain \(before) dB -> 0 dB")
                }
            }
            strips[stripIndex]["effects"] = effects
        }

        if changes.isEmpty {
            if verbose {
                VPhoneConsole.shared.line("  [.] \(url.lastPathComponent): no equalizer gain to remove")
            }
            return []
        }
        if dryRun {
            if verbose {
                VPhoneConsole.shared.line("  [.] dry-run — not writing back")
            }
            return changes
        }
        plist["strips"] = strips
        let output = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try output.write(to: url)
        return changes
    }

    /// `state` with the global-scope gain parameter at 0, and the gain it had;
    /// nil when it is already 0 or the preset does not carry it.
    ///
    /// An AU's saved parameters are big-endian records: scope, element, count,
    /// then `count` pairs of parameter ID and Float32 value.
    static func withoutGlobalGain(_ state: Data, effect: String, path: String) throws -> (Data, Float)? {
        var bytes = [UInt8](state)
        func word(_ offset: Int) -> UInt32 {
            bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        var found: Float?
        var offset = 0
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else {
                throw PatcherError.invalidFormat("\(effect): parameter data ends inside a record header: \(path)")
            }
            let scope = word(offset)
            let count = Int(word(offset + 8))
            offset += 12
            guard count <= (bytes.count - offset) / 8 else {
                throw PatcherError.invalidFormat("\(effect): parameter data ends inside a record: \(path)")
            }
            for _ in 0 ..< count {
                if scope == 0, word(offset) == globalGainParameter {
                    let gain = Float(bitPattern: word(offset + 4))
                    if gain != 0 {
                        found = gain
                        bytes.replaceSubrange(offset + 4 ..< offset + 8, with: [0, 0, 0, 0])
                    }
                }
                offset += 8
            }
        }
        return found.map { (Data(bytes), $0) }
    }
}
