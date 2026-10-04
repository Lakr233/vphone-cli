// CustomFirmwareVirtualAudio.swift — keep `No default VAD present` from
// terminating audiomxd.
//
// VirtualAudio walks the current port list applying speaker protection and the
// DSP chain whenever a property write arrives that touches the route (most
// visibly MediaExperience's VAD serialization listener, which pushes saved
// route and volume state on every launch and on every route change). The
// walker needs a `vdef` virtual audio device to apply anything to; when the
// speaker port is published by a device that is not one of VirtualAudio's own
// — the virtio sound device publishing as `PuffinOutput`, whose `pspk` speaker
// port is what makes playback routable in a vphone guest at all — the list it
// is handed can hold no `vdef`, and the walker answers that with
// `throw std::runtime_error("No default VAD present")`.
//
// The throw sits inside an AudioServerPlugIn property callback, which is a C
// boundary that cannot propagate C++ exceptions: the exception reaches
// `std::terminate` and audiomxd aborts. The saved serialization state then
// replays the same write into every later launch, so one abort becomes a
// crash loop until the guest is rebooted.
//
// The walker holds five exception sites — "No default VAD present", two
// "Could not construct" (each behind a routing-mutex assertion), "Unexpected
// HAL speaker protection ... *VP* speaker protection", and a generic
// "Precondition failure." — every one unreachable on real hardware, where the
// built-in speaker is a codec the routing layer grew up with. A guest whose
// speaker arrives any other way reaches them all.
//
// The patch rewrites the first instruction of each throw block — the `mov w0,
// #<size>` that sizes the exception allocation — into a branch to the
// function's own epilogue, so each condition degrades to "apply nothing and
// return". The diagnostic logs that precede the throws are left intact.
//
// Anchoring
// ---------
// Nothing is a literal address. The site is found from the C string
// `No default VAD present`, which the code references exactly twice: once as
// the os_log format's argument (x3) and once as the `runtime_error`
// constructor's message argument (x1), the second reference being the throw
// site. Both references must resolve, and the ctor reference must be the one
// whose `add` is followed by a call. The throw block is then read backwards
// from there: `bl` (the exception allocation) preceded by `movz w0, #imm`.
// The epilogue is found forwards from the `___cxa_throw` call as the stack-
// guard-checked pop sequence ending in `retab`, and its shape is verified
// instruction by instruction before the branch is encoded.
//
// The mute-set throw
// ------------------
// Establishing the route also asks the HAL device itself to unmute:
// Device_HAL_Common's set wrapper pushes `kAudioDevicePropertyMute` through
// `AudioObjectSetPropertyData` and reads it back. iOS's HAL server rejects a
// device-level mute on a plugin device with 'what' without ever forwarding
// the selector to the driver — ASDAudioDevice's dispatch has no case for it
// — and the wrapper answers any failed set by throwing a CAException out of
// the callback. RoutingManager catches it and abandons the route, which
// leaves the vdef's aggregate on Null_Device and the guest silent. Every
// caller of the wrapper ignores its return value, so skipping the throw is
// safe: the FAIL and EXCEPTION diagnostics still log, and the route proceeds
// as if the mute had held.
//
// Anchored on the mute-set log ("Set mute value of %u on HAL device"), whose
// single `__text` reference sits in the wrapper's selector dispatch. Within
// the wrapper, the site is the CAException throw block — the exception
// allocation, the status stored into the object, the throw call — that has
// the "Unable to set property data." EXCEPTION log a few instructions above
// it; iOS 27's wrapper holds a second, unrelated CAException (the
// deactivated-device throw), and that log window is what tells them apart.
// The epilogue is the wrapper's single `retab`, walked back to its entry.
//
// The speaker-protection gate
// ---------------------------
// With the walker and the mute-set throw quieted, a route change still
// declines at the last step: RoutingHandler_Playback_GenericConfig1 builds
// the whole route — virtual stream, DSP chain, format match — and then
// rejects it because the route's device list calls for HAL Speaker
// Protection, a capability only a physical codec reports. The capability
// query never leaves VirtualAudio, so no plugin can provide it. The decline
// is a log line and a branch to the handler's failure path, which leaves the
// vdef's output stream on Null_Device: every "playing" signature is genuine
// and nothing is audible, volume included.
//
// Anchored on the decline's log format, a message three routing handlers
// share — ours is the handler whose log block also names
// RoutingHandler_Playback_GenericConfig1.cpp. The gate's branch is left as
// it is; what changes is the log block it jumps to, whose opening
// instruction — the `mov w0, #<size>` sizing the os_log — becomes a branch
// back to the gate's own fall-through. A taken gate now lands on the
// success path the handler already built, which never reads the verdict
// the gate tested, on either supported build. The block is entered only by
// the gate's jump — the instruction above its head is an unconditional
// branch, checked before anything is written — so no fall-through is
// orphaned, and leaving the gate's branch intact is what lets the anchor
// find the site again on an already-patched binary.
//
// RoutingHandler_PlaybackAndRecord_GenericConfig1 holds the same gate in the
// same shape, and a route that plays and records ('cpar', what a recording
// app asks for) is declined by it once the guest has a microphone port to
// build that route with. It is the patch's second site, found by that
// handler's own file name. Its volume-mode test is a plain branch between
// two ways of building the route, not a precondition, and needs nothing.
//
// The volume-mode precondition
// ----------------------------
// The gate opened; the route survives its own construction and dies one
// step later on a precondition. The handler asks the volume-mode lookup for
// the route's default scope and requires a packed (present,
// kHardwareOnlyReadOnly) pair back; a device whose software volume runs any
// other mode — the virtio plugin's reports SoftwareHardwareMix — fails the
// test, and the handler answers a `std::logic_error` that unwinds into
// RoutingManager, which fails the route and tears the session down onto
// Null_Device. Same silence as the gate produced, one layer later: by then
// the route had already built its DSP chain, its virtual stream and an
// IOProc on the virtio aggregate.
//
// The precondition's own text survives only in the iOS 27 build
// ("softwareVolumeModeForPerDefaultScope.has_value() && … ==
// kHardwareOnlyReadOnly"); iPadOS 26 stripped it to a bare "Precondition
// failure.". What identifies the site on both builds is the test itself:
// the handler masks the lookup's return with the 33-bit packing mask
// (`and xN, xM, #0x1ffffffff` — a present flag in bit 32 above the mode's
// low 32 bits), compares it against the expected pair, and branches to the
// decline on inequality. Two sibling preconditions in the same handler
// branch off plain flag tests, so the mask is what tells the declines
// apart. The write is the one the speaker-protection gate performs: the
// comparison stays intact, and the decline's log block head becomes a
// branch back to the comparison's fall-through, which reloads everything
// it reads from memory and never re-reads the value the test examined, on
// either supported build.

import Foundation
import VPhonePatchKit

/// Turns VirtualAudio's `No default VAD present` exception into a no-op
/// return, so a speaker route published by the virtio device cannot abort
/// audiomxd.
public enum CustomFirmwareVirtualAudio {
    // MARK: - Identity

    /// The exception message, and the anchor string.
    public static let message = "No default VAD present"

    /// The fault log that precedes the walker's direct `std::terminate` call.
    public static let terminateFault = "Speaker Protection is not active on speaker route"

    /// Component name for the patch records.
    public static let component = "virtualaudio"

    /// Record identity, tying the emitted record to its patch-set declaration.
    public static let patchID = "system-virtualaudio-cfw-speaker_route_throws"

    /// The mute-set log format, and the anchor for the set wrapper's patch.
    /// Its full text carries the selector and scope; the needle stops where
    /// the format stays stable across builds.
    public static let muteSetMessage = "Set mute value of %u on HAL device"

    /// The EXCEPTION diagnostic whose log must sit just above the mute-set
    /// throw, telling it apart from the wrapper's other CAException (the
    /// deactivated-device throw iOS 27 builds in).
    public static let muteSetException = "Unable to set property data."

    /// Record identity for the mute-set patch.
    public static let muteSetPatchID = "system-virtualaudio-cfw-mute_set_throw"

    /// The route-decline log format, and the anchor for the SP-gate patch.
    /// Its full text carries the route it declines; the needle stops where
    /// the format stays stable across builds.
    public static let spGateMessage = "HAL Speaker Protection is missing. Failing route"

    /// The routing handler the SP-gate patch targets, named by its own log:
    /// three handlers share the decline's format, and this file's string is
    /// the one the ringtone ('crnp') reconfiguration route runs through.
    public static let spGateFile = "RoutingHandler_Playback_GenericConfig1.cpp"

    /// The handlers whose SP gate the patch opens. A route that plays and
    /// records ('cpar', what a recording app asks for) runs through the
    /// second, which declines it for the same missing capability once a
    /// microphone port makes the route buildable at all.
    public enum SPGateHandler: String, Sendable, CaseIterable {
        case playback
        case playbackAndRecord

        /// The handler's source-file string, which its log blocks reference.
        public var file: String {
            switch self {
            case .playback: spGateFile
            case .playbackAndRecord: "RoutingHandler_PlaybackAndRecord_GenericConfig1.cpp"
            }
        }

        /// The record this handler's write emits: the declaration's own
        /// identifier, or a site of it.
        public var patchID: String {
            switch self {
            case .playback: spGatePatchID
            case .playbackAndRecord: spGatePatchID + ".playback_and_record"
            }
        }
    }

    /// Record identity for the SP-gate patch.
    public static let spGatePatchID = "system-virtualaudio-cfw-speaker_protection_gate"

    /// The precondition log format the volume-mode decline opens with, and
    /// one anchor of the volume-gate patch. Three declines in this handler
    /// share it; the packing-mask comparison picks ours out.
    public static let volumePreconditionFormat = "PRECONDITION FAILURE (std::logic_error)"

    /// The 33-bit packing mask the handler compares the volume-mode lookup
    /// under — a present flag in bit 32 above the mode's low 32 bits. The
    /// semantic constant the site is recognised by, beside the strings.
    public static let volumeModePackingMask = 0x1ffffffff

    /// Record identity for the volume-gate patch.
    public static let volumeGatePatchID = "system-virtualaudio-cfw-volume_mode_precondition"

    /// Where progress goes when the caller does not say.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Results

    public enum Outcome: String, Sendable, Equatable {
        /// The throw block already branched to the epilogue. Nothing was written.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The branch was written and its page re-attested.
        case patched
    }

    /// The resolved pair the patch writes between.
    public struct Anchor: Sendable, Equatable {
        /// `movz w0, #imm` — the first instruction of the throw block.
        public let throwBlockFileOffset: Int
        public let throwBlockVMA: UInt64
        /// The `ldur` that begins the function's epilogue.
        public let epilogueFileOffset: Int
        public let epilogueVMA: UInt64
    }

    public struct Report: Sendable {
        public let outcome: Outcome
        public let anchor: Anchor
        public let records: [PatchRecord]
        public let slotRehashes: [CustomFirmwareSlotRehash]
    }

    /// The resolved pair the mute-set patch writes between.
    public struct MuteSetAnchor: Sendable, Equatable {
        /// `mov w0, #<size>` — the first instruction of the throw block.
        public let throwBlockFileOffset: Int
        public let throwBlockVMA: UInt64
        /// The guarded canary load (or first pop) that begins the wrapper's
        /// epilogue.
        public let epilogueFileOffset: Int
        public let epilogueVMA: UInt64
    }

    public struct MuteSetReport: Sendable {
        public let outcome: Outcome
        public let anchor: MuteSetAnchor
        public let records: [PatchRecord]
        public let slotRehashes: [CustomFirmwareSlotRehash]
    }

    /// The resolved pair the SP-gate patch writes between.
    public struct SPGateAnchor: Sendable, Equatable {
        /// The branch that jumps into the decline's log block — left as it is.
        public let branchFileOffset: Int
        public let branchVMA: UInt64
        /// The log block's entry — the instruction the patch rewrites into a
        /// branch back to the gate's own fall-through.
        public let blockHeadFileOffset: Int
        public let blockHeadVMA: UInt64
    }

    public struct SPGateReport: Sendable {
        public let outcome: Outcome
        public let anchor: SPGateAnchor
        public let records: [PatchRecord]
        public let slotRehashes: [CustomFirmwareSlotRehash]
    }

    /// The resolved pair the volume-gate patch writes between.
    public struct VolumeGateAnchor: Sendable, Equatable {
        /// The conditional branch that jumps into the decline's log block —
        /// left as it is.
        public let branchFileOffset: Int
        public let branchVMA: UInt64
        /// The log block's entry — the instruction the patch rewrites into a
        /// branch back to the comparison's own fall-through.
        public let blockHeadFileOffset: Int
        public let blockHeadVMA: UInt64
    }

    public struct VolumeGateReport: Sendable {
        public let outcome: Outcome
        public let anchor: VolumeGateAnchor
        public let records: [PatchRecord]
        public let slotRehashes: [CustomFirmwareSlotRehash]
    }

    // MARK: - Patching

    /// Patch the VirtualAudio Mach-O at `url` in place.
    ///
    /// Idempotent: a second run recognises its own branch, reports
    /// ``Outcome/alreadyPatched`` and leaves the file byte-identical.
    ///
    /// - Parameters:
    ///   - url: the `VirtualAudio` plugin binary.
    ///   - reattest: recompute the code-directory slot hash of the touched
    ///     page. `false` when the caller re-signs the whole binary right
    ///     after, which is what both install paths do.
    ///   - dryRun: locate and report, write nothing.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patch(&data, reattest: reattest, dryRun: dryRun, log: log)
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form of ``patch(fileAt:reattest:dryRun:log:)``.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let located = try locate(in: data)
        log?("  [.] speaker-route walker 0x\(hex(located.walkerStartVMA)) … 0x\(hex(located.walkerEndVMA))"
            + "; epilogue 0x\(hex(located.epilogueVMA)); \(located.sites.count) throw site(s)")

        var records: [PatchRecord] = []
        var written: [Int] = []
        var alreadyPatched = 0
        for site in located.sites {
            let siteVMA = located.vma(site)
            let siteInstruction = located.disasm.disassembleOne(in: data, at: site, address: siteVMA)
            if let insn = siteInstruction, insn.isJump, !insn.isCall,
               let word = wordAt(data, site),
               let target = ARM64Encoder.decodeBranchTarget(insn: word, pc: siteVMA),
               target == located.epilogueVMA {
                alreadyPatched += 1
                continue
            }
            guard isExceptionSizeMove(siteInstruction) || siteInstruction?.isCall == true else {
                throw PatcherError.invalidFormat(
                    "\(component): site 0x\(hex(siteVMA)) is neither `mov w0, #<size>` nor a call",
                )
            }
            guard let branch = ARM64Encoder.encodeB(from: Int(siteVMA), to: Int(located.epilogueVMA)) else {
                throw PatcherError.patchSiteNotFound(
                    "\(component): the epilogue at 0x\(hex(located.epilogueVMA)) is out of "
                        + "branch range of the throw block at 0x\(hex(siteVMA))",
                )
            }
            let original = Data(data[site ..< site + 4])
            if dryRun {
                log?("      [.] dry-run — would branch 0x\(hex(siteVMA)) -> 0x\(hex(located.epilogueVMA))")
                continue
            }
            data.replaceSubrange(site ..< site + 4, with: branch)
            written.append(site)
            records.append(PatchRecord(
                patchID: patchID,
                component: component,
                fileOffset: site,
                virtualAddress: siteVMA,
                originalBytes: original,
                patchedBytes: branch,
                beforeDisasm: siteInstruction?.description ?? "",
                afterDisasm: branch.map { String(format: "%02x", $0) }.joined(separator: " "),
                description: "speaker-route walker throw -> epilogue",
            ))
            log?("      [+] 0x\(hex(siteVMA)): \(siteInstruction?.description ?? "") -> b 0x\(hex(located.epilogueVMA))")
        }

        if records.isEmpty, !dryRun {
            log?("      [=] all \(alreadyPatched) throw site(s) already branch to the epilogue")
        }

        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest, !written.isEmpty {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: written)
            if !rehashes.isEmpty {
                log?("      [+] re-attested \(rehashes.count) stale slot(s)")
            }
        }
        let outcome: Outcome = dryRun ? .wouldPatch : (records.isEmpty ? .alreadyPatched : .patched)
        return Report(
            outcome: outcome,
            anchor: Anchor(
                throwBlockFileOffset: located.sites.first ?? 0,
                throwBlockVMA: located.sites.isEmpty ? 0 : located.vma(located.sites[0]),
                epilogueFileOffset: located.epilogueOffset,
                epilogueVMA: located.epilogueVMA,
            ),
            records: records,
            slotRehashes: rehashes,
        )
    }

    private static func wordAt(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    // MARK: - Mute-set patching

    /// Patch the VirtualAudio Mach-O at `url` in place, turning the mute-set
    /// CAException into a quiet return through the wrapper's epilogue.
    ///
    /// Idempotent: a second run recognises its own branch, reports
    /// ``Outcome/alreadyPatched`` and leaves the file byte-identical.
    ///
    /// - Parameters:
    ///   - url: the `VirtualAudio` plugin binary.
    ///   - reattest: recompute the code-directory slot hash of the touched
    ///     page. `false` when the caller re-signs the whole binary right
    ///     after, which is what both install paths do.
    ///   - dryRun: locate and report, write nothing.
    @discardableResult
    public static func patchMuteSet(
        fileAt url: URL,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> MuteSetReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patchMuteSet(&data, reattest: reattest, dryRun: dryRun, log: log)
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form of ``patchMuteSet(fileAt:reattest:dryRun:log:)``.
    @discardableResult
    public static func patchMuteSet(
        _ data: inout Data,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> MuteSetReport {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let located = try locateMuteSet(in: data)
        let site = located.site
        let siteVMA = located.vma(site)
        log?("  [.] mute-set wrapper 0x\(hex(located.functionStartVMA)) … 0x\(hex(located.functionEndVMA))"
            + "; epilogue 0x\(hex(located.epilogueVMA)); throw 0x\(hex(siteVMA))")

        let anchor = MuteSetAnchor(
            throwBlockFileOffset: site,
            throwBlockVMA: siteVMA,
            epilogueFileOffset: located.epilogueOffset,
            epilogueVMA: located.epilogueVMA,
        )
        let siteInstruction = located.disasm.disassembleOne(in: data, at: site, address: siteVMA)
        if let insn = siteInstruction, insn.isJump, !insn.isCall,
           let word = wordAt(data, site),
           let target = ARM64Encoder.decodeBranchTarget(insn: word, pc: siteVMA),
           target == located.epilogueVMA {
            log?("      [=] the mute-set throw already branches to the epilogue")
            return MuteSetReport(outcome: .alreadyPatched, anchor: anchor, records: [], slotRehashes: [])
        }
        guard isExceptionSizeMove(siteInstruction) else {
            throw PatcherError.invalidFormat(
                "\(component): the mute-set throw at 0x\(hex(siteVMA)) is not `mov w0, #<size>`",
            )
        }
        guard let branch = ARM64Encoder.encodeB(from: Int(siteVMA), to: Int(located.epilogueVMA)) else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the epilogue at 0x\(hex(located.epilogueVMA)) is out of "
                    + "branch range of the mute-set throw at 0x\(hex(siteVMA))",
            )
        }
        let original = Data(data[site ..< site + 4])
        if dryRun {
            log?("      [.] dry-run — would branch 0x\(hex(siteVMA)) -> 0x\(hex(located.epilogueVMA))")
            return MuteSetReport(outcome: .wouldPatch, anchor: anchor, records: [], slotRehashes: [])
        }
        data.replaceSubrange(site ..< site + 4, with: branch)
        log?("      [+] 0x\(hex(siteVMA)): \(siteInstruction?.description ?? "") -> b 0x\(hex(located.epilogueVMA))")
        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [site])
            if !rehashes.isEmpty {
                log?("      [+] re-attested \(rehashes.count) stale slot(s)")
            }
        }
        return MuteSetReport(
            outcome: .patched,
            anchor: anchor,
            records: [PatchRecord(
                patchID: muteSetPatchID,
                component: component,
                fileOffset: site,
                virtualAddress: siteVMA,
                originalBytes: original,
                patchedBytes: branch,
                beforeDisasm: siteInstruction?.description ?? "",
                afterDisasm: branch.map { String(format: "%02x", $0) }.joined(separator: " "),
                description: "mute-set throw -> epilogue",
            )],
            slotRehashes: rehashes,
        )
    }

    // MARK: - SP-gate patching

    /// Patch the VirtualAudio Mach-O at `url` in place, opening the branch
    /// that declines a finished speaker route for lack of HAL Speaker
    /// Protection.
    ///
    /// The gate branch is left untouched; what changes is the decline's own
    /// log block: its entry — the `mov w0, #<size>` that opens the os_log —
    /// is rewritten into a branch back to the gate's fall-through, so a
    /// taken gate lands straight on the success path the handler already
    /// built. The block is reachable only by the gate's jump (its
    /// predecessor is an unconditional branch, verified before writing) and
    /// that success path never reads the verdict the gate tested, on either
    /// supported build.
    ///
    /// Idempotent: a second run finds the log block's entry holding its own
    /// unconditional branch, reports ``Outcome/alreadyPatched`` and leaves
    /// the file byte-identical.
    ///
    /// - Parameters:
    ///   - url: the `VirtualAudio` plugin binary.
    ///   - reattest: recompute the code-directory slot hash of the touched
    ///     page. `false` when the caller re-signs the whole binary right
    ///     after, which is what both install paths do.
    ///   - dryRun: locate and report, write nothing.
    @discardableResult
    public static func patchSpeakerProtectionGate(
        fileAt url: URL,
        handler: SPGateHandler = .playback,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> SPGateReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patchSpeakerProtectionGate(
            &data, handler: handler, reattest: reattest, dryRun: dryRun, log: log,
        )
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form of ``patchSpeakerProtectionGate(fileAt:handler:reattest:dryRun:log:)``.
    @discardableResult
    public static func patchSpeakerProtectionGate(
        _ data: inout Data,
        handler: SPGateHandler = .playback,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> SPGateReport {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let located = try locateSPGate(in: data, handler: handler)
        let head = located.blockHead
        let headVMA = located.vma(head)
        let site = located.site
        let siteVMA = located.vma(site)
        log?("  [.] SP-gate \(handler.rawValue) handler 0x\(hex(located.functionStartVMA)) … 0x\(hex(located.functionEndVMA))"
            + "; log block 0x\(hex(headVMA)); gate 0x\(hex(siteVMA))")
        let anchor = SPGateAnchor(
            branchFileOffset: site,
            branchVMA: siteVMA,
            blockHeadFileOffset: head,
            blockHeadVMA: headVMA,
        )

        let headInstruction = located.disasm.disassembleOne(in: data, at: head, address: headVMA)
        if let insn = headInstruction, insn.isJump, !insn.isCall, insn.detail?.conditionCode == nil {
            // An unconditional branch at the head is either this patch's own
            // work or someone else's; the target tells them apart, and
            // someone else's is never overwritten.
            guard let word = wordAt(data, head),
                  let target = ARM64Encoder.decodeBranchTarget(insn: word, pc: headVMA),
                  target == siteVMA + 4
            else {
                throw PatcherError.invalidFormat(
                    "\(component): the log block at 0x\(hex(headVMA)) holds a branch this "
                        + "patch did not write",
                )
            }
            log?("      [=] the decline's log block already branches back to the gate's fall-through")
            return SPGateReport(outcome: .alreadyPatched, anchor: anchor, records: [], slotRehashes: [])
        }
        // A pristine block opens the os_log allocation: the size move, then
        // the call that allocates it.
        guard isExceptionSizeMove(headInstruction),
              let next = located.disasm.disassembleOne(in: data, at: head + 4), next.isCall
        else {
            throw PatcherError.invalidFormat(
                "\(component): the log block at 0x\(hex(headVMA)) does not open an os_log allocation",
            )
        }
        guard let branch = ARM64Encoder.encodeB(from: Int(headVMA), to: Int(siteVMA) + 4) else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the fall-through at 0x\(hex(siteVMA + 4)) is out of "
                    + "branch range of the log block at 0x\(hex(headVMA))",
            )
        }
        let original = Data(data[head ..< head + 4])
        if dryRun {
            log?("      [.] dry-run — would branch 0x\(hex(headVMA)) -> 0x\(hex(siteVMA + 4))")
            return SPGateReport(outcome: .wouldPatch, anchor: anchor, records: [], slotRehashes: [])
        }
        data.replaceSubrange(head ..< head + 4, with: branch)
        log?("      [+] 0x\(hex(headVMA)): \(headInstruction?.description ?? "") -> b 0x\(hex(siteVMA + 4))")
        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [head])
            if !rehashes.isEmpty {
                log?("      [+] re-attested \(rehashes.count) stale slot(s)")
            }
        }
        return SPGateReport(
            outcome: .patched,
            anchor: anchor,
            records: [PatchRecord(
                patchID: handler.patchID,
                component: component,
                fileOffset: head,
                virtualAddress: headVMA,
                originalBytes: original,
                patchedBytes: branch,
                beforeDisasm: headInstruction?.description ?? "",
                afterDisasm: branch.map { String(format: "%02x", $0) }.joined(separator: " "),
                description: "speaker-protection decline -> gate fall-through",
            )],
            slotRehashes: rehashes,
        )
    }

    // MARK: - Volume-gate patching

    /// Patch the VirtualAudio Mach-O at `url` in place, opening the branch
    /// that declines a finished route when its software-volume mode is not
    /// the kHardwareOnlyReadOnly the routing database demands.
    ///
    /// The comparison is left untouched; what changes is the decline's own
    /// log block: its entry — the `mov w0, #<size>` that opens the os_log —
    /// is rewritten into a branch back to the comparison's fall-through, so
    /// a failed precondition lands on the success path the handler already
    /// built. The block is reachable only by the comparison's jump (its
    /// predecessor is an unconditional branch, verified before writing) and
    /// that success path never reads the value the comparison tested, on
    /// either supported build.
    ///
    /// Idempotent: a second run finds the log block's entry holding its own
    /// unconditional branch, reports ``Outcome/alreadyPatched`` and leaves
    /// the file byte-identical.
    ///
    /// - Parameters:
    ///   - url: the `VirtualAudio` plugin binary.
    ///   - reattest: recompute the code-directory slot hash of the touched
    ///     page. `false` when the caller re-signs the whole binary right
    ///     after, which is what both install paths do.
    ///   - dryRun: locate and report, write nothing.
    @discardableResult
    public static func patchVolumeModePrecondition(
        fileAt url: URL,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> VolumeGateReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patchVolumeModePrecondition(&data, reattest: reattest, dryRun: dryRun, log: log)
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form of ``patchVolumeModePrecondition(fileAt:reattest:dryRun:log:)``.
    @discardableResult
    public static func patchVolumeModePrecondition(
        _ data: inout Data,
        reattest: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> VolumeGateReport {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let located = try locateVolumeGate(in: data)
        let head = located.blockHead
        let headVMA = located.vma(head)
        let site = located.site
        let siteVMA = located.vma(site)
        log?("  [.] volume-gate handler 0x\(hex(located.functionStartVMA)) … 0x\(hex(located.functionEndVMA))"
            + "; log block 0x\(hex(headVMA)); comparison 0x\(hex(siteVMA))")
        let anchor = VolumeGateAnchor(
            branchFileOffset: site,
            branchVMA: siteVMA,
            blockHeadFileOffset: head,
            blockHeadVMA: headVMA,
        )

        let headInstruction = located.disasm.disassembleOne(in: data, at: head, address: headVMA)
        if let insn = headInstruction, insn.isJump, !insn.isCall, insn.detail?.conditionCode == nil {
            // An unconditional branch at the head is either this patch's own
            // work or someone else's; the target tells them apart, and
            // someone else's is never overwritten.
            guard let word = wordAt(data, head),
                  let target = ARM64Encoder.decodeBranchTarget(insn: word, pc: headVMA),
                  target == siteVMA + 4
            else {
                throw PatcherError.invalidFormat(
                    "\(component): the log block at 0x\(hex(headVMA)) holds a branch this "
                        + "patch did not write",
                )
            }
            log?("      [=] the decline's log block already branches back to the comparison's fall-through")
            return VolumeGateReport(outcome: .alreadyPatched, anchor: anchor, records: [], slotRehashes: [])
        }
        // A pristine block opens the os_log allocation: the size move, then
        // the call that allocates it.
        guard isExceptionSizeMove(headInstruction),
              let next = located.disasm.disassembleOne(in: data, at: head + 4), next.isCall
        else {
            throw PatcherError.invalidFormat(
                "\(component): the log block at 0x\(hex(headVMA)) does not open an os_log allocation",
            )
        }
        guard let branch = ARM64Encoder.encodeB(from: Int(headVMA), to: Int(siteVMA) + 4) else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the fall-through at 0x\(hex(siteVMA + 4)) is out of "
                    + "branch range of the log block at 0x\(hex(headVMA))",
            )
        }
        let original = Data(data[head ..< head + 4])
        if dryRun {
            log?("      [.] dry-run — would branch 0x\(hex(headVMA)) -> 0x\(hex(siteVMA + 4))")
            return VolumeGateReport(outcome: .wouldPatch, anchor: anchor, records: [], slotRehashes: [])
        }
        data.replaceSubrange(head ..< head + 4, with: branch)
        log?("      [+] 0x\(hex(headVMA)): \(headInstruction?.description ?? "") -> b 0x\(hex(siteVMA + 4))")
        var rehashes: [CustomFirmwareSlotRehash] = []
        if reattest {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: [head])
            if !rehashes.isEmpty {
                log?("      [+] re-attested \(rehashes.count) stale slot(s)")
            }
        }
        return VolumeGateReport(
            outcome: .patched,
            anchor: anchor,
            records: [PatchRecord(
                patchID: volumeGatePatchID,
                component: component,
                fileOffset: head,
                virtualAddress: headVMA,
                originalBytes: original,
                patchedBytes: branch,
                beforeDisasm: headInstruction?.description ?? "",
                afterDisasm: branch.map { String(format: "%02x", $0) }.joined(separator: " "),
                description: "volume-mode precondition -> comparison fall-through",
            )],
            slotRehashes: rehashes,
        )
    }

    // MARK: - Anchoring

    /// Resolve the throw block and the epilogue, or say why not.
    /// Everything the patch needs: the walker's bounds, its epilogue, and
    /// every throw site inside it.
    struct Plan: Sendable {
        let disasm: ARM64Disassembler
        let textStart: Int
        let textAddress: UInt64
        let walkerStartOffset: Int
        let walkerEndOffset: Int
        let epilogueOffset: Int
        let epilogueVMA: UInt64
        let sites: [Int]

        var walkerStartVMA: UInt64 { vma(walkerStartOffset) }
        var walkerEndVMA: UInt64 { vma(walkerEndOffset) }
        func vma(_ offset: Int) -> UInt64 { textAddress + UInt64(offset - textStart) }
    }

    static func locate(in data: Data) throws -> Plan {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("\(component): no __TEXT,__text section")
        }
        let textStart = Int(text.fileOffset)
        let textEnd = textStart + Int(text.size)
        let disasm = ARM64Disassembler()

        let stringVMA = try locateMessage(in: data, sections: sections)
        let references = adrpAddReferences(to: 0, formingAnyOf: [stringVMA], in: data, textStart: textStart, textEnd: textEnd)
        guard references.count == 1 else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 reference to \"\(message)\" (the exception "
                    + "constructor's), found \(references.count)",
            )
        }
        let ctor = references[0]
        guard disasm.disassembleOne(in: data, at: ctor.add + 4)?.isCall == true else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the reference to \"\(message)\" is not the exception constructor's",
            )
        }
        guard nearbyLogReference(in: data, sections: sections, textStart: textStart, textEnd: textEnd, before: ctor.adrp) != nil else {
            throw PatcherError.patchSiteNotFound(
                "\(component): no diagnostic-log reference above the throw to corroborate it",
            )
        }

        // The walker: the function whose prologue stands above the anchor and
        // whose next prologue closes it.
        let walkerStart = nearestPrologue(in: data, disasm: disasm, below: ctor.adrp, floor: textStart)
            ?? textStart
        let walkerEnd = nearestPrologue(in: data, disasm: disasm, atOrAfter: walkerStart + 4, ceiling: textEnd)
            ?? textEnd

        // The epilogue: the guarded pop run after the anchor's throw.
        guard let terminator = firstUnconditionalBranch(in: data, disasm: disasm, after: ctor.add + 4, textEnd: walkerEnd) else {
            throw PatcherError.patchSiteNotFound(
                "\(component): no terminator branch after the exception constructor",
            )
        }
        let epilogueOffset = try locateEpilogue(in: data, disasm: disasm, after: terminator, textEnd: walkerEnd)

        // Every throw block in the walker: a `mov w0, #<size>` whose next
        // instruction calls the exception allocator, followed within a short
        // window by a message load into x1 and a constructor call, and closed
        // by the terminator branch.
        var sites: [Int] = []
        var offset = walkerStart
        while offset + 4 <= walkerEnd {
            defer { offset += 4 }
            guard let insn = disasm.disassembleOne(in: data, at: offset),
                  isExceptionSizeMove(insn) || (insn.isJump && !insn.isCall),
                  let next = disasm.disassembleOne(in: data, at: offset + 4), next.isCall
            else { continue }
            // An already-patched site still carries its allocation call and
            // the whole machinery below, so the shape check holds for it too
            // and `patch` recognises its own branch when it writes.
            if isThrowBlock(in: data, disasm: disasm, from: offset + 4, to: walkerEnd) {
                sites.append(offset)
            }
        }
        var allSites = sites
        if let terminate = terminateSite(
            in: data,
            disasm: disasm,
            sections: sections,
            textStart: textStart,
            textEnd: textEnd,
            walkerStart: walkerStart,
            walkerEnd: walkerEnd,
            epilogueVMA: text.address + UInt64(epilogueOffset - textStart),
        ) {
            allSites.append(terminate)
        }

        guard !allSites.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "\(component): no exception throw blocks in the walker at 0x\(hex(UInt64(textStart)))",
            )
        }

        return Plan(
            disasm: disasm,
            textStart: textStart,
            textAddress: text.address,
            walkerStartOffset: walkerStart,
            walkerEndOffset: walkerEnd,
            epilogueOffset: epilogueOffset,
            epilogueVMA: text.address + UInt64(epilogueOffset - textStart),
            sites: allSites.sorted(),
        )
    }

    // MARK: - Mute-set anchoring

    /// Everything the mute-set patch needs: the set wrapper's bounds, its
    /// epilogue, and its throw site.
    struct MuteSetPlan: Sendable {
        let disasm: ARM64Disassembler
        let textStart: Int
        let textAddress: UInt64
        let functionStartOffset: Int
        let functionEndOffset: Int
        let epilogueOffset: Int
        let epilogueVMA: UInt64
        let site: Int

        var functionStartVMA: UInt64 { vma(functionStartOffset) }
        var functionEndVMA: UInt64 { vma(functionEndOffset) }
        func vma(_ offset: Int) -> UInt64 { textAddress + UInt64(offset - textStart) }
    }

    /// Resolve the mute-set throw and the wrapper's epilogue, or say why not.
    static func locateMuteSet(in data: Data) throws -> MuteSetPlan {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("\(component): no __TEXT,__text section")
        }
        let textStart = Int(text.fileOffset)
        let textEnd = textStart + Int(text.size)
        let disasm = ARM64Disassembler()

        // The anchor: the mute-set log format, referenced exactly once in
        // __text — by the wrapper's selector dispatch.
        guard let logVMA = cStringVMA(containing: muteSetMessage, in: data, sections: sections) else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the string \"\(muteSetMessage)\" is nowhere in the binary's sections",
            )
        }
        let references = adrpAddReferences(
            to: 0,
            formingAnyOf: [logVMA],
            in: data,
            textStart: textStart,
            textEnd: textEnd,
        )
        guard references.count == 1 else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 reference to \"\(muteSetMessage)\", found \(references.count)",
            )
        }

        // The wrapper: the function whose prologue stands above the log
        // reference and whose next prologue closes it.
        let functionStart = nearestPrologue(in: data, disasm: disasm, below: references[0].adrp, floor: textStart)
            ?? textStart
        let functionEnd = nearestPrologue(in: data, disasm: disasm, atOrAfter: functionStart + 4, ceiling: textEnd)
            ?? textEnd

        // The throw: the wrapper's CAException block whose EXCEPTION log sits
        // just above it. iOS 27's wrapper holds a second CAException — the
        // deactivated-device throw — and the log window is what tells them
        // apart.
        let exceptionStrings = cStringVMAs(containing: muteSetException, in: data, sections: sections)
        guard !exceptionStrings.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the string \"\(muteSetException)\" is nowhere in the binary's sections",
            )
        }
        var sites: [Int] = []
        var offset = functionStart
        while offset + 4 <= functionEnd {
            defer { offset += 4 }
            guard let insn = disasm.disassembleOne(in: data, at: offset),
                  isExceptionSizeMove(insn) || (insn.isJump && !insn.isCall),
                  let next = disasm.disassembleOne(in: data, at: offset + 4), next.isCall
            else { continue }
            // An already-patched site still carries the allocation call and
            // the stores below it, so the shape holds for it too and
            // `patchMuteSet` recognises its own branch when it writes.
            guard isCAExceptionThrowBlock(in: data, disasm: disasm, from: offset + 4, to: functionEnd),
                  hasExceptionLogWindow(
                      in: data,
                      textStart: textStart,
                      before: offset,
                      targets: exceptionStrings,
                  )
            else { continue }
            sites.append(offset)
        }
        guard sites.count == 1, let site = sites.first else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 mute-set throw in the wrapper at 0x\(hex(text.address + UInt64(functionStart - textStart))), found \(sites.count)",
            )
        }

        // The epilogue: the wrapper's only `retab`, walked back to its entry.
        // The mute-set throw sits *below* the epilogue, so the forward search
        // the walker patch uses cannot apply — the retab must be enumerated
        // within the function's own bounds.
        var retabs: [Int] = []
        offset = functionStart
        while offset + 4 <= functionEnd {
            if let insn = disasm.disassembleOne(in: data, at: offset), insn.mnemonic == "retab" {
                retabs.append(offset)
            }
            offset += 4
        }
        guard retabs.count == 1, let retab = retabs.first else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 `retab` in the mute-set wrapper, found \(retabs.count)",
            )
        }
        let epilogueOffset = try epilogueEntry(in: data, disasm: disasm, retab: retab)

        return MuteSetPlan(
            disasm: disasm,
            textStart: textStart,
            textAddress: text.address,
            functionStartOffset: functionStart,
            functionEndOffset: functionEnd,
            epilogueOffset: epilogueOffset,
            epilogueVMA: text.address + UInt64(epilogueOffset - textStart),
            site: site,
        )
    }

    // MARK: - SP-gate anchoring

    /// Everything the SP-gate patch needs: the routing handler's bounds, the
    /// decline's log block, and the branch that jumps into it. The branch is
    /// found the same way on a pristine and on an already-patched binary —
    /// the patch leaves it intact and rewrites the block's head instead.
    struct SPGatePlan: Sendable {
        let disasm: ARM64Disassembler
        let textStart: Int
        let textAddress: UInt64
        let functionStartOffset: Int
        let functionEndOffset: Int
        let blockHead: Int
        let site: Int

        var functionStartVMA: UInt64 { vma(functionStartOffset) }
        var functionEndVMA: UInt64 { vma(functionEndOffset) }
        func vma(_ offset: Int) -> UInt64 { textAddress + UInt64(offset - textStart) }
    }

    /// How far above a branch target the format-string reference may sit and
    /// still be inside the log block that target heads. Both supported
    /// builds hold the os_log's file-name and format references 0x34 apart,
    /// 0x84 above the block's entry; the budget covers the shape, not those
    /// exact figures.
    private static let spGateBlockWindow = 0x100

    /// The ringtone ('crnp') routing handler both gate patches live in,
    /// resolved once and shared: the SP-missing decline and the volume-mode
    /// precondition sit in the same function, qualified by the same pair of
    /// strings.
    struct PlaybackHandler: Sendable {
        let disasm: ARM64Disassembler
        let textStart: Int
        let textAddress: UInt64
        let functionStartOffset: Int
        let functionEndOffset: Int
        /// The SP-missing format reference that qualified the handler.
        let reference: (adrp: Int, add: Int)
        /// The handler's own source-file string addresses — the corroboration
        /// both gate scans read.
        let fileNameVMAs: Set<UInt64>

        var functionStartVMA: UInt64 { vma(functionStartOffset) }
        var functionEndVMA: UInt64 { vma(functionEndOffset) }
        func vma(_ offset: Int) -> UInt64 { textAddress + UInt64(offset - textStart) }
    }

    /// Resolve the routing handler, or say why not. The anchors are the
    /// SP-missing decline's log format and the handler's own source file:
    /// the format alone names three routing handlers, and of the functions
    /// holding a reference to it, exactly one — ours — also references the
    /// GenericConfig1 file name.
    static func locatePlaybackHandler(in data: Data, file: String = spGateFile) throws -> PlaybackHandler {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("\(component): no __TEXT,__text section")
        }
        let textStart = Int(text.fileOffset)
        let textEnd = textStart + Int(text.size)
        let disasm = ARM64Disassembler()

        let formats = cStringVMAs(containing: spGateMessage, in: data, sections: sections)
        guard !formats.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the string \"\(spGateMessage)\" is nowhere in the binary's sections",
            )
        }
        let fileNames = cStringVMAs(containing: file, in: data, sections: sections)
        guard !fileNames.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the string \"\(file)\" is nowhere in the binary's sections",
            )
        }

        let references = adrpAddReferences(
            to: 0,
            formingAnyOf: formats,
            in: data,
            textStart: textStart,
            textEnd: textEnd,
        )
        guard !references.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "\(component): no reference to \"\(spGateMessage)\" in __text",
            )
        }

        var qualified: [(reference: (adrp: Int, add: Int), start: Int, end: Int)] = []
        for reference in references {
            let start = nearestPrologue(in: data, disasm: disasm, below: reference.adrp, floor: textStart)
                ?? textStart
            let end = nearestPrologue(in: data, disasm: disasm, atOrAfter: start + 4, ceiling: textEnd)
                ?? textEnd
            let corroborated = adrpAddReferences(
                to: 0,
                formingAnyOf: fileNames,
                in: data,
                textStart: start,
                textEnd: end,
            )
            if !corroborated.isEmpty {
                qualified.append((reference, start, end))
            }
        }
        guard qualified.count == 1, let handler = qualified.first else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 \"\(file)\" handler referencing "
                    + "\"\(spGateMessage)\", found \(qualified.count)",
            )
        }
        return PlaybackHandler(
            disasm: disasm,
            textStart: textStart,
            textAddress: text.address,
            functionStartOffset: handler.start,
            functionEndOffset: handler.end,
            reference: handler.reference,
            fileNameVMAs: fileNames,
        )
    }

    /// Resolve the SP-gate branch, or say why not.
    static func locateSPGate(in data: Data, handler which: SPGateHandler = .playback) throws -> SPGatePlan {
        let handler = try locatePlaybackHandler(in: data, file: which.file)
        func vma(_ offset: Int) -> UInt64 { handler.vma(offset) }
        func offset(of address: UInt64) -> Int { handler.textStart + Int(address - handler.textAddress) }

        // The gate: the one branch in the handler whose target heads the log
        // block — a target at or above which, within the window, the format
        // reference sits and the handler's own file name is referenced too.
        // The os_log block carries both strings; a branch into any other
        // label in the window does not qualify.
        //
        // Each word is decoded rather than trusted to Capstone's jump group:
        // the gate is a `tbz`, which the group tagging misses, and the op
        // fields the decoded families live in hold nothing but branches.
        // The gate's branch is never rewritten, so the scan resolves the
        // same candidate on a pristine and on an already-patched binary
        // alike.
        var candidates: [(site: Int, head: Int)] = []
        var cursor = handler.functionStartOffset
        while cursor + 4 <= handler.functionEndOffset {
            defer { cursor += 4 }
            guard let insn = handler.disasm.disassembleOne(in: data, at: cursor),
                  !insn.isCall,
                  let word = wordAt(data, cursor),
                  let target = branchTargetValue(insn: word, pc: vma(cursor))
            else { continue }
            let head = offset(of: target)
            guard cursor < head, head >= handler.functionStartOffset,
                  head <= handler.reference.add, handler.reference.add - head <= spGateBlockWindow
            else { continue }
            let names = adrpAddReferences(
                to: 0,
                formingAnyOf: handler.fileNameVMAs,
                in: data,
                textStart: head,
                textEnd: handler.reference.add + 4,
            )
            guard !names.isEmpty else { continue }
            // The head must be the block's own opening — the os_log size
            // move and the allocation call, which is exactly what the patch
            // rewrites — or, once it has run, the branch back to the gate's
            // fall-through that replaced them. Any other label inside the
            // window is not the block's head, whichever branch lands on it.
            let headInsn = handler.disasm.disassembleOne(in: data, at: head)
            let opensLog = isExceptionSizeMove(headInsn)
                && handler.disasm.disassembleOne(in: data, at: head + 4)?.isCall == true
            let holdsOurBranch: Bool = {
                guard let insn = headInsn, insn.isJump, !insn.isCall,
                      insn.detail?.conditionCode == nil,
                      let word = wordAt(data, head)
                else { return false }
                return ARM64Encoder.decodeBranchTarget(insn: word, pc: vma(head)) == vma(cursor) + 4
            }()
            guard opensLog || holdsOurBranch else { continue }
            candidates.append((cursor, head))
        }
        guard candidates.count == 1, let gate = candidates.first else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 branch into the SP-missing log block in "
                    + "the handler at 0x\(hex(vma(handler.functionStartOffset))), found \(candidates.count)",
            )
        }

        // The block is entered only by the gate's jump: the instruction
        // above its head must not fall through. That is what makes rewriting
        // the head safe — nothing else arrives at the block expecting the
        // os_log the head used to open.
        guard let above = handler.disasm.disassembleOne(in: data, at: gate.head - 4),
              above.mnemonic == "brk" || ["ret", "retab"].contains(above.mnemonic)
                  || (above.isJump && !above.isCall && above.detail?.conditionCode == nil)
        else {
            throw PatcherError.invalidFormat(
                "\(component): the log block at 0x\(hex(vma(gate.head))) is reached by "
                    + "fall-through, not only by the gate's jump",
            )
        }

        return SPGatePlan(
            disasm: handler.disasm,
            textStart: handler.textStart,
            textAddress: handler.textAddress,
            functionStartOffset: handler.functionStartOffset,
            functionEndOffset: handler.functionEndOffset,
            blockHead: gate.head,
            site: gate.site,
        )
    }

    // MARK: - Volume-gate anchoring

    /// Everything the volume-gate patch needs: the routing handler's bounds,
    /// the decline's log block, and the comparison that jumps into it. The
    /// comparison is found the same way on a pristine and on an
    /// already-patched binary — the patch leaves it intact and rewrites the
    /// block's head instead.
    struct VolumeGatePlan: Sendable {
        let disasm: ARM64Disassembler
        let textStart: Int
        let textAddress: UInt64
        let functionStartOffset: Int
        let functionEndOffset: Int
        let blockHead: Int
        let site: Int

        var functionStartVMA: UInt64 { vma(functionStartOffset) }
        var functionEndVMA: UInt64 { vma(functionEndOffset) }
        func vma(_ offset: Int) -> UInt64 { textAddress + UInt64(offset - textStart) }
    }

    /// How far above a branch target the precondition block's format and
    /// file-name references may sit. Both supported builds hold them 0x2c
    /// and 0x58 above the block's entry — the same layout every decline log
    /// in this handler carries; the budget covers the shape, not those
    /// exact figures.
    private static let volumeGateBlockWindow = 0x100

    /// Resolve the volume-mode comparison and its decline, or say why not.
    /// The decline is one of three in this handler that open with the same
    /// PRECONDITION FAILURE format; what picks ours out is the comparison
    /// that reaches it — the only one that masks a lookup's return with the
    /// 33-bit volume-mode packing mask and compares it against the expected
    /// packed pair. The sibling preconditions branch off plain flag tests.
    static func locateVolumeGate(in data: Data) throws -> VolumeGatePlan {
        let sections = MachOParser.parseSections(from: data)
        let handler = try locatePlaybackHandler(in: data)
        let formats = cStringVMAs(containing: volumePreconditionFormat, in: data, sections: sections)
        guard !formats.isEmpty else {
            throw PatcherError.patchSiteNotFound(
                "\(component): the string \"\(volumePreconditionFormat)\" is nowhere in the binary's sections",
            )
        }
        func vma(_ offset: Int) -> UInt64 { handler.vma(offset) }
        func offset(of address: UInt64) -> Int { handler.textStart + Int(address - handler.textAddress) }

        // The comparison: the one branch in the handler whose target heads a
        // precondition log block — both the format and the handler's own
        // file name referenced within the window, and the target opening the
        // os_log allocation — and whose own backward window holds the
        // packing-mask `and` over a call's return, closed by the branch.
        // Each word is decoded rather than trusted to Capstone's jump group:
        // the comparison's branch is a `b.ne`, and the op fields the decoded
        // families live in hold nothing but branches. The branch is never
        // rewritten, so the scan resolves the same candidate on a pristine
        // and on an already-patched binary alike.
        var candidates: [(site: Int, head: Int)] = []
        var cursor = handler.functionStartOffset
        while cursor + 4 <= handler.functionEndOffset {
            defer { cursor += 4 }
            guard let insn = handler.disasm.disassembleOne(in: data, at: cursor),
                  !insn.isCall,
                  let word = wordAt(data, cursor),
                  let target = branchTargetValue(insn: word, pc: vma(cursor))
            else { continue }
            let head = offset(of: target)
            guard cursor < head, head >= handler.functionStartOffset,
                  !adrpAddReferences(
                      to: 0,
                      formingAnyOf: formats,
                      in: data,
                      textStart: head,
                      textEnd: head + volumeGateBlockWindow,
                  ).isEmpty,
                  !adrpAddReferences(
                      to: 0,
                      formingAnyOf: handler.fileNameVMAs,
                      in: data,
                      textStart: head,
                      textEnd: head + volumeGateBlockWindow,
                  ).isEmpty
            else { continue }
            // The head must be the block's own opening — the os_log size
            // move and the allocation call, which is exactly what the patch
            // rewrites — or, once it has run, the branch back to the
            // comparison's fall-through that replaced them. The block's own
            // exception-allocation label and its log-enable skips hold size
            // moves too; the comparison window below the branch is what
            // rejects them.
            let headInsn = handler.disasm.disassembleOne(in: data, at: head)
            let opensLog = isExceptionSizeMove(headInsn)
                && handler.disasm.disassembleOne(in: data, at: head + 4)?.isCall == true
            let holdsOurBranch: Bool = {
                guard let insn = headInsn, insn.isJump, !insn.isCall,
                      insn.detail?.conditionCode == nil,
                      let word = wordAt(data, head)
                else { return false }
                return ARM64Encoder.decodeBranchTarget(insn: word, pc: vma(head)) == vma(cursor) + 4
            }()
            guard opensLog || holdsOurBranch,
                  isVolumeModeComparison(in: data, disasm: handler.disasm, below: cursor)
            else { continue }
            candidates.append((cursor, head))
        }
        guard candidates.count == 1, let gate = candidates.first else {
            throw PatcherError.patchSiteNotFound(
                "\(component): expected exactly 1 volume-mode comparison guarding a "
                    + "precondition decline in the handler at 0x\(hex(vma(handler.functionStartOffset))), "
                    + "found \(candidates.count)",
            )
        }

        // The block is entered only by the comparison's jump: the
        // instruction above its head must not fall through. That is what
        // makes rewriting the head safe — nothing else arrives at the block
        // expecting the os_log the head used to open.
        guard let above = handler.disasm.disassembleOne(in: data, at: gate.head - 4),
              above.mnemonic == "brk" || ["ret", "retab"].contains(above.mnemonic)
                  || (above.isJump && !above.isCall && above.detail?.conditionCode == nil)
        else {
            throw PatcherError.invalidFormat(
                "\(component): the precondition block at 0x\(hex(vma(gate.head))) is reached by "
                    + "fall-through, not only by the comparison's jump",
            )
        }

        return VolumeGatePlan(
            disasm: handler.disasm,
            textStart: handler.textStart,
            textAddress: handler.textAddress,
            functionStartOffset: handler.functionStartOffset,
            functionEndOffset: handler.functionEndOffset,
            blockHead: gate.head,
            site: gate.site,
        )
    }

    /// Whether the branch at `branch` closes a volume-mode comparison: the
    /// packing-mask `and` over a lookup's return within a few instructions
    /// below it, a `cmp` between the two, and the call that produced the
    /// masked value directly below the `and`. The sibling preconditions in
    /// this handler branch off plain flag tests, so this is what tells the
    /// declines apart.
    private static func isVolumeModeComparison(
        in data: Data,
        disasm: ARM64Disassembler,
        below branch: Int,
    ) -> Bool {
        var sawCompare = false
        var cursor = branch - 4
        // Six instructions reach from the branch past the whole masked
        // compare on both supported builds (`cmp; add; and; bl`).
        while cursor >= branch - 24 {
            defer { cursor -= 4 }
            guard let insn = disasm.disassembleOne(in: data, at: cursor) else { return false }
            if insn.mnemonic == "cmp" { sawCompare = true }
            guard insn.mnemonic == "and",
                  let operands = insn.detail?.operands, operands.count >= 3,
                  operands[2].type == .immediate,
                  operands[2].imm == volumeModePackingMask
            else { continue }
            // The masked value is a lookup's return: the call that produced
            // it sits directly below the `and`.
            guard disasm.disassembleOne(in: data, at: cursor - 4)?.isCall == true else { return false }
            return sawCompare
        }
        return false
    }

    /// The target of a jump word, whichever immediate family encodes it:
    /// `ARM64Encoder.decodeBranchTarget` reads `b`/`bl`, this adds nothing
    /// for them and defers to ``decodeConditionalBranchTarget`` for the
    /// rest.
    private static func branchTargetValue(insn word: UInt32, pc: UInt64) -> UInt64? {
        ARM64Encoder.decodeBranchTarget(insn: word, pc: pc)
            ?? decodeConditionalBranchTarget(insn: word, pc: pc)
    }

    /// The target of the conditional-branch families, which
    /// ``ARM64Encoder.decodeBranchTarget(insn:pc:)`` (the `b`/`bl` pair)
    /// does not decode: `b.cond` and `cbz`/`cbnz` carry a 19-bit immediate
    /// at bits 23-5, `tbz`/`tbnz` a 14-bit one at bits 18-5. The SP-gate
    /// branch is a `tbz`. Analysis only: this reads where a branch goes, it
    /// assembles nothing.
    static func decodeConditionalBranchTarget(insn: UInt32, pc: UInt64) -> UInt64? {
        // b.cond: bits 31-24 = 01010100. The PAUTH BC.cond shares the top
        // seven bits but sets bit 24, and names a register, not an offset.
        if insn >> 24 == 0b0101_0100 {
            let imm19 = (insn >> 5) & 0x7FFFF
            let signed = Int32(bitPattern: imm19 << 13) >> 13
            return UInt64(Int64(pc) + Int64(signed) * 4)
        }
        // cbz/cbnz (bits 30-25 = 011010) and tbz/tbnz (011011): the leading
        // bit is sf/b5, which does not change how far the branch reaches.
        switch (insn >> 25) & 0x3F {
        case 0b011010:
            let imm19 = (insn >> 5) & 0x7FFFF
            let signed = Int32(bitPattern: imm19 << 13) >> 13
            return UInt64(Int64(pc) + Int64(signed) * 4)
        case 0b011011:
            let imm14 = (insn >> 5) & 0x3FFF
            let signed = Int32(bitPattern: imm14 << 18) >> 18
            return UInt64(Int64(pc) + Int64(signed) * 4)
        default:
            return nil
        }
    }

    /// Whether the window after an allocation call holds the CAException
    /// throw machinery: the vtable or status stored into the allocated object
    /// (`str xN, [x0, #imm]`), the throw call after it, and the block's
    /// terminator. A CAException carries no message string, so the
    /// `runtime_error` shape (`isThrowBlock`) does not fit it.
    private static func isCAExceptionThrowBlock(
        in data: Data,
        disasm: ARM64Disassembler,
        from offset: Int,
        to end: Int,
    ) -> Bool {
        var cursor = offset
        var sawObjectStore = false
        var sawThrowCall = false
        var scanned = 0
        // A CAException block runs longer than a runtime_error one — the
        // vtable and its PAC discriminators, the status store, the typeinfo
        // pointer — 17 instructions on both supported builds before the
        // terminator, so the budget reaches past it.
        while cursor + 4 <= end, scanned < 32 {
            defer {
                cursor += 4
                scanned += 1
            }
            guard let insn = disasm.disassembleOne(in: data, at: cursor) else { return false }
            if insn.mnemonic == "str",
               let operands = insn.detail?.operands, operands.count >= 2,
               operands[0].type == .register,
               operands[1].type == .memory, operands[1].mem.base == ARM64Register.x(0) {
                sawObjectStore = true
            }
            if insn.isCall, sawObjectStore {
                sawThrowCall = true
                continue
            }
            // The block ends at an unconditional branch (the iOS 27 twin jumps
            // to its `brk`) or at the `brk` the compiler plants after a call
            // it knows never returns.
            if insn.mnemonic == "brk"
                || (insn.isJump && !insn.isCall && insn.detail?.conditionCode == nil) {
                return sawObjectStore && sawThrowCall
            }
        }
        return false
    }

    /// Whether an adrp+add pair within `window` bytes above the site forms
    /// one of `targets` — the EXCEPTION log that always precedes this throw.
    private static func hasExceptionLogWindow(
        in data: Data,
        textStart: Int,
        before site: Int,
        targets: Set<UInt64>,
        window: Int = 0x40,
    ) -> Bool {
        !adrpAddReferences(
            to: 0,
            formingAnyOf: targets,
            in: data,
            textStart: max(textStart, site - window),
            textEnd: site,
        ).isEmpty
    }

    /// The address of the cstring containing `needle`, in a real string
    /// section. The os_log formats begin with a `%25s:%-5d` prefix, so the
    /// reference the code materialises points at the whole string's start,
    /// not at the needle itself.
    private static func cStringVMA(containing needle: String, in data: Data, sections: [String: MachOSectionInfo]) -> UInt64? {
        cStringVMAs(containing: needle, in: data, sections: sections).first
    }

    /// Every such address, one per section occurrence — a message can live in
    /// more than one string, and the callers only need the set for
    /// corroboration.
    private static func cStringVMAs(containing needle: String, in data: Data, sections: [String: MachOSectionInfo]) -> Set<UInt64> {
        let bytes = Array(needle.utf8)
        // cstring sections first, then any other section that still holds
        // file bytes; the signature and symbol tables are not sections.
        let searchable = sections.values
            .filter { $0.fileOffset > 0 && Int($0.fileOffset) + Int($0.size) <= data.count }
            .sorted { lhs, rhs in
                let l = lhs.sectionName == "__cstring"
                let r = rhs.sectionName == "__cstring"
                if l != r { return l }
                return lhs.fileOffset < rhs.fileOffset
            }
        var addresses: Set<UInt64> = []
        for section in searchable {
            let start = Int(section.fileOffset)
            let end = start + Int(section.size)
            var searchFrom = start
            while searchFrom + bytes.count <= end,
                  let match = range(of: bytes, in: data, start: searchFrom, end: end) {
                let stringStart = cStringStart(in: data, containing: match, notBefore: start)
                addresses.insert(section.address + UInt64(stringStart - start))
                searchFrom = match + 1
            }
        }
        return addresses
    }

    /// The walker's direct `std::terminate` call. The compiler ends a
    /// fault-logged fatal path with a run of back-to-back `bl`s — the log, its
    /// releases — closed by the terminate call, whose successor is never a
    /// call. Anchored on the fault's own string, not on the stub address.
    private static func terminateSite(
        in data: Data,
        disasm: ARM64Disassembler,
        sections: [String: MachOSectionInfo],
        textStart: Int,
        textEnd: Int,
        walkerStart: Int,
        walkerEnd: Int,
        epilogueVMA: UInt64,
    ) -> Int? {
        let needle = Array((terminateFault + "\0").utf8)
        var faultVMA: UInt64?
        for section in sections.values
        where section.fileOffset > 0 && Int(section.fileOffset) + Int(section.size) <= data.count {
            let start = Int(section.fileOffset)
            let end = start + Int(section.size)
            if let match = range(of: needle, in: data, start: start, end: end) {
                faultVMA = section.address + UInt64(match - start)
                break
            }
        }
        guard let faultVMA else { return nil }
        let references = adrpAddReferences(
            to: 0,
            formingAnyOf: [faultVMA],
            in: data,
            textStart: walkerStart,
            textEnd: walkerEnd,
        )
        guard let reference = references.first else { return nil }

        // The fault logger: the first call after the string reference,
        // following any unconditional branch its argument setup ends with.
        var cursor = reference.add + 4
        var steps = 0
        var faultLogger: Int?
        while cursor + 4 <= walkerEnd, steps < 32 {
            defer {
                cursor += 4
                steps += 1
            }
            guard let insn = disasm.disassembleOne(in: data, at: cursor) else { return nil }
            if insn.isCall {
                faultLogger = cursor
                break
            }
            if insn.isJump, !insn.isCall, insn.detail?.conditionCode == nil,
               let target = branchTarget(insn, at: cursor), target >= walkerStart, target < walkerEnd {
                cursor = Int(target) - 4  // the defer moves past it
                continue
            }
        }
        guard let logger = faultLogger else { return nil }

        // The back-to-back call run the logger opens; its last call, followed
        // by anything but a call, is the terminate.
        var call = logger
        var site: Int?
        while call + 8 <= walkerEnd {
            let nextOffset = call + 4
            guard let next = disasm.disassembleOne(in: data, at: nextOffset) else { break }
            if next.isCall {
                site = nextOffset
                call = nextOffset
                continue
            }
            break
        }
        // Already patched: the run now ends one call early, and what follows
        // its last call is our branch to the epilogue. Recognise it rather
        // than eating the release on every re-run.
        if let site,
           let after = disasm.disassembleOne(in: data, at: site + 4),
           after.isJump, !after.isCall,
           let word = wordAtCache(data: after.bytes, offset: 0),
           let target = ARM64Encoder.decodeBranchTarget(insn: word, pc: UInt64(site + 4)),
           target == epilogueVMA {
            return nil
        }
        return site
    }

    private static func branchTarget(_ insn: ARM64Instruction, at offset: Int) -> UInt64? {
        guard let word = wordAtCache(data: insn.bytes, offset: 0) else { return nil }
        return ARM64Encoder.decodeBranchTarget(insn: word, pc: UInt64(offset))
    }

    private static func wordAtCache(data bytes: [UInt8], offset: Int) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    /// The nearest function prologue (`pacibsp`) at or before `below`.
    private static func nearestPrologue(in data: Data, disasm: ARM64Disassembler, below: Int, floor: Int) -> Int? {
        var offset = min(below, floor + ((below - floor) & ~3))
        while offset >= floor {
            if let insn = disasm.disassembleOne(in: data, at: offset), insn.mnemonic == "pacibsp" {
                return offset
            }
            offset -= 4
        }
        return nil
    }

    /// The nearest function prologue at or after `atOrAfter`.
    private static func nearestPrologue(in data: Data, disasm: ARM64Disassembler, atOrAfter: Int, ceiling: Int) -> Int? {
        var offset = atOrAfter
        while offset + 4 <= ceiling {
            if let insn = disasm.disassembleOne(in: data, at: offset), insn.mnemonic == "pacibsp" {
                return offset
            }
            offset += 4
        }
        return nil
    }

    /// Whether the window after an allocation call holds the whole throw
    /// machinery: a message load into x1, a constructor call, and the block's
    /// terminating branch.
    private static func isThrowBlock(
        in data: Data,
        disasm: ARM64Disassembler,
        from offset: Int,
        to end: Int,
    ) -> Bool {
        var cursor = offset
        var sawMessageLoad = false
        var sawConstructorCall = false
        var scanned = 0
        while cursor + 4 <= end, scanned < 16 {
            defer {
                cursor += 4
                scanned += 1
            }
            guard let insn = disasm.disassembleOne(in: data, at: cursor) else { return false }
            if insn.mnemonic == "adrp",
               let operands = insn.detail?.operands, operands.count >= 2,
               operands[0].reg == ARM64Register.x(1) {
                if let low = disasm.disassembleOne(in: data, at: cursor + 4), low.mnemonic == "add",
                   let lowOps = low.detail?.operands, lowOps.count >= 3,
                   lowOps[0].reg == ARM64Register.x(1), lowOps[1].reg == ARM64Register.x(1) {
                    sawMessageLoad = true
                }
            }
            if insn.isCall, sawMessageLoad {
                sawConstructorCall = true
                continue
            }
            // The block ends at an unconditional branch (to a resume path or
            // a tail-called throw) or at the `brk` the compiler plants after
            // a call it knows never returns.
            if insn.mnemonic == "brk"
                || (insn.isJump, !insn.isCall, insn.detail?.conditionCode == nil) == (true, true, true) {
                return sawMessageLoad && sawConstructorCall
            }
        }
        return false
    }

    /// A cstring that *contains* the message — the diagnostic log's format
    /// string — with an adrp+add reference within `window` bytes above the
    /// throw. The exception and its log always come as this pair, so a
    /// message string whose only reference is not corroborated by a log
    /// reference nearby is not this site.
    private static func nearbyLogReference(
        in data: Data,
        sections: [String: MachOSectionInfo],
        textStart: Int,
        textEnd: Int,
        before offset: Int,
        window: Int = 0x100,
    ) -> (adrp: Int, add: Int)? {
        let messageBytes = Array(message.utf8)
        let formats: [UInt64] = sections.values
            .filter { $0.fileOffset > 0 && Int($0.fileOffset) + Int($0.size) <= data.count }
            .compactMap { section in
                let start = Int(section.fileOffset)
                let end = start + Int(section.size)
                guard let match = range(of: messageBytes, in: data, start: start, end: end) else { return nil }
                let stringStart = cStringStart(in: data, containing: match, notBefore: start)
                let stringEnd = cStringEnd(in: data, from: stringStart, notAfter: end)
                guard stringEnd - stringStart > messageBytes.count + 8 else { return nil }
                return section.address + UInt64(stringStart - start)
            }
        guard !formats.isEmpty else { return nil }
        return adrpAddReferences(
            to: 0,
            formingAnyOf: Set(formats),
            in: data,
            textStart: max(textStart, offset - window),
            textEnd: offset,
        ).first
    }

    /// The `No default VAD present` C string, in a real string section.
    private static func locateMessage(in data: Data, sections: [String: MachOSectionInfo]) throws -> UInt64 {
        let needle = Array((message + "\0").utf8)
        // cstring sections first, then any other section that still holds
        // file bytes; the signature and symbol tables are not sections.
        let searchable = sections.values
            .filter { $0.fileOffset > 0 && Int($0.fileOffset) + Int($0.size) <= data.count }
            .sorted { lhs, rhs in
                let l = lhs.sectionName == "__cstring"
                let r = rhs.sectionName == "__cstring"
                if l != r { return l }
                return lhs.fileOffset < rhs.fileOffset
            }
        for section in searchable {
            let start = Int(section.fileOffset)
            let end = start + Int(section.size)
            guard end - start >= needle.count else { continue }
            guard let match = range(of: needle, in: data, start: start, end: end) else { continue }
            return section.address + UInt64(match - start)
        }
        throw PatcherError.patchSiteNotFound(
            "\(component): the string \"\(message)\" is nowhere in the binary's sections",
        )
    }

    /// Every `adrp Xn, page ; add Xn, Xn, #low` pair in `__text` whose sum is
    /// `target`, in file-offset terms.
    private static func adrpAddReferences(
        to target: UInt64,
        in data: Data,
        textStart: Int,
        textEnd: Int,
    ) -> [(adrp: Int, add: Int)] {
        adrpAddReferences(to: 0, formingAnyOf: [target], in: data, textStart: textStart, textEnd: textEnd)
    }

    /// The same pairs, matching any target in a set.
    private static func adrpAddReferences(
        to placeholder: UInt64,
        formingAnyOf targets: Set<UInt64>,
        in data: Data,
        textStart: Int,
        textEnd: Int,
    ) -> [(adrp: Int, add: Int)] {
        let disasm = ARM64Disassembler()
        var references: [(Int, Int)] = []
        var offset = textStart
        while offset + 8 <= textEnd {
            defer { offset += 4 }
            guard let adrp = disasm.disassembleOne(in: data, at: offset), adrp.mnemonic == "adrp",
                  let add = disasm.disassembleOne(in: data, at: offset + 4), add.mnemonic == "add",
                  let page = adrp.detail?.operands, page.count >= 2,
                  let low = add.detail?.operands, low.count >= 3,
                  page[0].reg == low[1].reg,
                  page[1].type == .immediate, low[2].type == .immediate,
                  targets.contains(UInt64(page[1].imm + low[2].imm))
            else { continue }
            references.append((offset, offset + 4))
        }
        return references
    }

    /// The first unconditional, non-call branch after `offset` — the throw
    /// block's terminator, whether it jumps to a resume path or tail-calls
    /// the throw itself.
    private static func firstUnconditionalBranch(
        in data: Data,
        disasm: ARM64Disassembler,
        after offset: Int,
        textEnd: Int,
    ) -> Int? {
        var cursor = offset
        var scanned = 0
        while cursor + 4 <= textEnd, scanned < 16 {
            defer {
                cursor += 4
                scanned += 1
            }
            guard let insn = disasm.disassembleOne(in: data, at: cursor) else { return nil }
            if insn.isCall { continue }
            if insn.mnemonic == "brk" || (insn.isJump && insn.detail?.conditionCode == nil) {
                return cursor
            }
        }
        return nil
    }

    /// `mov w0, #<size>` — the instruction that sizes a std::exception.
    static func isExceptionSizeMove(_ insn: ARM64Instruction?) -> Bool {
        guard let insn else { return false }
        guard ["mov", "movz"].contains(insn.mnemonic),
              let operands = insn.detail?.operands, operands.count == 2
        else { return false }
        return operands[0].type == .register
            && operands[0].reg == ARM64Register.w(0)
            && operands[1].type == .immediate
            && (0 ... 0x100).contains(operands[1].imm)
    }

    /// The function epilogue's entry, found after the throw: the stack-guard
    /// load when the function is built with the protector (iOS 26), or the
    /// first frame restore when it is not (iOS 27).
    private static func locateEpilogue(
        in data: Data,
        disasm: ARM64Disassembler,
        after offset: Int,
        textEnd: Int,
    ) throws -> Int {
        // The first `retab` after the throw ends the epilogue.
        var retabOffset: Int?
        var cursor = offset + 4
        while cursor + 4 <= textEnd {
            defer { cursor += 4 }
            if let insn = disasm.disassembleOne(in: data, at: cursor),
               insn.mnemonic == "retab" {
                retabOffset = cursor
                break
            }
        }
        guard let retab = retabOffset else {
            throw PatcherError.patchSiteNotFound(
                "\(component): no `retab` after the throw at 0x\(hex(UInt64(offset)))",
            )
        }
        return try epilogueEntry(in: data, disasm: disasm, retab: retab)
    }

    /// The entry of the epilogue a known `retab` closes: the stack-guard load
    /// when the function is built with the protector, or the first frame
    /// restore when it is not. Shared by both VirtualAudio patches — the
    /// walker patch reaches the retab forwards from its throw, the mute-set
    /// patch enumerates the wrapper's own retab because its throw sits below
    /// the epilogue.
    private static func epilogueEntry(
        in data: Data,
        disasm: ARM64Disassembler,
        retab: Int,
    ) throws -> Int {
        func instruction(_ at: Int) -> ARM64Instruction? {
            guard at >= 0 else { return nil }
            return disasm.disassembleOne(in: data, at: at)
        }

        // `add sp, sp, #imm` directly before the return, then the pops.
        guard let addSP = instruction(retab - 4), addSP.mnemonic == "add",
              let addOps = addSP.detail?.operands, addOps.count >= 2,
              addOps[0].type == .register, addOps[1].type == .register,
              addOps[0].reg == addOps[1].reg
        else {
            throw PatcherError.invalidFormat(
                "\(component): no `add sp` directly before the epilogue's `retab`",
            )
        }

        // The pops, innermost first, until the frame pair. `index` lands one
        // instruction below the first pop.
        var index = retab - 8
        var sawFramePair = false
        while let insn = instruction(index), insn.mnemonic == "ldp",
              let operands = insn.detail?.operands, operands.count >= 2 {
            if operands[0].reg == ARM64Register.x(29), operands[1].reg == ARM64Register.x(30) {
                sawFramePair = true
            }
            index -= 4
        }
        guard sawFramePair else {
            throw PatcherError.invalidFormat(
                "\(component): the epilogue's pops do not restore the frame pair",
            )
        }
        let firstPop = index + 4

        // A stack-guarded function loads the canary below the first pop:
        // `ldur` off the frame pointer, its page, two loads, a compare and
        // the fail branch. When that chain is there the entry is the load,
        // so the restored canary is still checked; when it is not (a build
        // without the protector) the entry is the first pop itself.
        if let branch = instruction(index), branch.mnemonic == "b.ne",
           let cmp = instruction(index - 4), cmp.mnemonic == "cmp",
           let load2 = instruction(index - 8), load2.mnemonic == "ldr",
           let load1 = instruction(index - 12), load1.mnemonic == "ldr",
           let page = instruction(index - 16), page.mnemonic == "adrp",
           let canary = instruction(index - 20), canary.mnemonic == "ldur",
           let canaryOps = canary.detail?.operands, canaryOps.count >= 2,
           canaryOps[1].type == .memory,
           canaryOps[1].mem.base == ARM64Register.x(29) {
            return index - 20
        }
        return firstPop
    }

    // MARK: - Bytes

    /// The first byte of the null-terminated string containing `offset`.
    private static func cStringStart(in data: Data, containing offset: Int, notBefore start: Int) -> Int {
        var begin = offset
        while begin > start, data[begin - 1] != 0 {
            begin -= 1
        }
        return begin
    }

    /// One past the NUL ending the string at `offset`.
    private static func cStringEnd(in data: Data, from offset: Int, notAfter end: Int) -> Int {
        var terminator = offset
        while terminator < end, data[terminator] != 0 {
            terminator += 1
        }
        return min(terminator + 1, end)
    }

    private static func range(of needle: [UInt8], in data: Data, start: Int, end: Int) -> Int? {
        guard end - start >= needle.count else { return nil }
        for offset in start ... (end - needle.count) {
            var matched = true
            for (index, byte) in needle.enumerated() where data[offset + index] != byte {
                matched = false
                break
            }
            if matched { return offset }
        }
        return nil
    }
}

private func hex(_ value: UInt64) -> String {
    String(format: "%llx", value)
}
