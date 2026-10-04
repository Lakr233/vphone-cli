// CustomFirmwareVirtualAudioGraphConfigurations.swift — speaker chains to the
// generic graph path in graph_configurations.plist.
//
// VirtualAudio builds each route's DSP chain through a factory that switches
// on the chain's `chainType`. Every `speaker_*` configuration ships with
// `clhs` — the HAL SpeakerProtection chain, whose construction looks a
// physical "Speaker" device up in the device registry and throws
// `Could not lock weak ptr` when the registry has none. A VM has no speaker
// hardware, so with the route walk otherwise fixed, the chain factory is what
// still kills every speaker route: RoutingManager catches the throw, logs
// "Failed to activate a route list", and the guest stays silent.
//
// The `dflt` chainType takes the generic graph chain instead — the same path
// every `beam_mic_*` and `omni_mic_*` configuration already uses. It needs no
// device: it loads the configuration's `graph` DSP file, which the tuning set
// ships for every speaker configuration. Flipping the speaker entries to
// `dflt` moves speaker routes onto that path; the tuning files themselves are
// not touched.
//
// The plist lives at `/Library/Audio/Tunings/<acoustic ID>/VAD/` on the
// sealed system volume, so the change rides the offline install; the patcher
// itself only ever sees a staged copy.

import Foundation
import VPhonePatchKit

/// Rewrites every `speaker_*` entry in a `graph_configurations.plist` from
/// the `clhs` HAL chain to the `dflt` generic graph chain.
public enum CustomFirmwareVirtualAudioGraphConfigurations {
    /// The key holding the per-configuration chain table.
    static let configurationsKey = "Configurations"

    /// The key inside each configuration naming its DSP chain type.
    static let chainTypeKey = "chainType"

    /// The HAL SpeakerProtection chain a physical speaker would use.
    static let speakerChainType = "clhs"

    /// The generic graph chain every mic configuration already uses.
    static let graphChainType = "dflt"

    /// What a patch attempt did.
    public enum Outcome: Sendable, Equatable {
        /// Entries already on the generic chain; nothing to write.
        case alreadyGraphChains([String])
        /// Entries would flip but `dryRun` suppressed the write.
        case dryRun(changed: [String])
        /// The file was rewritten with the flipped entries.
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

    /// Flip every `speaker_*` configuration's `chainType` to `dflt` at `url`.
    ///
    /// - Throws: ``PatcherError/invalidFormat(_:)`` when the file is not a
    ///   plist, its root is not a dictionary, `Configurations` is missing or
    ///   not a dictionary, a speaker configuration is not a dictionary, its
    ///   `chainType` is missing or not one of the two strings this patch
    ///   knows, or no speaker configuration is present at all. Each is a
    ///   reason to stop the install rather than write a half-understood file
    ///   back to a mounted guest volume.
    @discardableResult
    public static func patch(
        at url: URL,
        dryRun: Bool = false,
        verbose: Bool = true,
    ) throws -> Outcome {
        let data = try readFile(at: url)
        let format = detectFormat(data)

        guard let parsed = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil,
        ) else {
            throw PatcherError.invalidFormat("cannot parse as plist: \(url.path)")
        }

        guard let plist = parsed as? [String: Any] else {
            throw PatcherError.invalidFormat(
                "top-level plist is \(type(of: parsed)), expected dict: \(url.path)"
            )
        }

        guard let configurations = plist[configurationsKey] as? [String: Any] else {
            throw PatcherError.invalidFormat(
                "no '\(configurationsKey)' dict present: \(url.path)"
            )
        }

        let speakerNames = configurations.keys.filter { $0.hasPrefix("speaker_") }.sorted()
        guard !speakerNames.isEmpty else {
            throw PatcherError.invalidFormat(
                "no 'speaker_' configurations in '\(configurationsKey)': \(url.path)"
            )
        }

        var changed: [String] = []
        for name in speakerNames {
            let configuration = configurations[name]
            guard let entry = configuration as? [String: Any] else {
                throw PatcherError.invalidFormat(
                    "configuration '\(name)' is \(type(of: configuration)), expected dict: \(url.path)"
                )
            }
            guard let chainType = entry[chainTypeKey] as? String else {
                throw PatcherError.invalidFormat(
                    "configuration '\(name)' has no '\(chainTypeKey)' string: \(url.path)"
                )
            }
            switch chainType {
            case graphChainType:
                continue
            case speakerChainType:
                changed.append(name)
            default:
                throw PatcherError.invalidFormat(
                    "configuration '\(name)' has chainType '\(chainType)', expected "
                        + "'\(speakerChainType)' or '\(graphChainType)': \(url.path)"
                )
            }
        }

        if changed.isEmpty {
            if verbose {
                print("  [.] \(url.lastPathComponent): \(speakerNames.count) speaker chains already '\(graphChainType)'")
            }
            return .alreadyGraphChains(speakerNames)
        }

        if verbose {
            for name in changed {
                print("  [+] \(url.lastPathComponent): \(name) chainType '\(speakerChainType)' -> '\(graphChainType)'")
            }
        }

        if dryRun {
            if verbose {
                print("  [.] dry-run — not writing back")
            }
            return .dryRun(changed: changed)
        }

        var patched = plist
        var patchedConfigurations = configurations
        for name in changed {
            var entry = patchedConfigurations[name] as! [String: Any]
            entry[chainTypeKey] = graphChainType
            patchedConfigurations[name] = entry
        }
        patched[configurationsKey] = patchedConfigurations

        let output = try PropertyListSerialization.data(
            fromPropertyList: patched,
            format: format,
            options: 0,
        )
        try output.write(to: url)
        return .rewritten(changed: changed)
    }

    // MARK: - Format detection

    /// XML plists start with `<?xml` or `<plist`; binary plists start with
    /// `bplist00`. Same sniff as `CustomFirmwareBuildVersion`, so the two
    /// plist patchers keep provably identical format behaviour.
    static func detectFormat(_ data: Data) -> PropertyListSerialization.PropertyListFormat {
        CustomFirmwareBuildVersion.detectFormat(data)
    }

    private static func readFile(at url: URL) throws -> Data {
        do {
            return try Data(contentsOfFileToRewrite: url)
        } catch {
            throw PatcherError.fileNotFound(url.path)
        }
    }
}
