// DeviceTreeNodeAdditions.swift — DeviceTree child-node additions.
//
// Nodes a real iPhone17,3 (D47AP) carries but vphone600 does not, added
// so the userland answer surface matches the spoofed identity. Gated
// behind `includeIdentityPatches` (the `.exp` variant only).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension DeviceTreePatcher {
    /// Experimental child-node additions. Adds nodes that exist on real
    /// iPhone17,3 but not on vphone600 — so the userland answer surface
    /// matches the spoofed identity. Gated by `includeIdentityPatches`
    /// (EXP variant only).
    ///
    /// `/device-tree/product/camera` is required for
    /// `MGGetBoolAnswer("still-camera")` to return YES — without it,
    /// SpringBoard's SBAppTags filter hides `Camera.app`'s icon and
    /// blocks launch. The d47ap DT carries this node with 64 capability
    /// properties; the subset here is the minimum that backs the
    /// `cameraCapability` / `aggregateCameraCapability` /
    /// `autoFocusCameraCapability` getters in libMobileGestalt and the
    /// `still-camera` answer the SBAppTags consumer hits.
    static let experimentalNodeAdditions: [AddChildNodePatch] = [
        // Replicates the full `/product/camera` property set carried by the
        // iPhone17,3 D47AP DT (62 props in the reference build, all integers
        // or zero-length placeholders). The minimal 11-property version
        // wasn't enough — `PurpleBuddy` and other first-boot consumers
        // re-evaluate camera capability via `MGGetBoolAnswer` reading
        // additional DT properties (front-flash-capability,
        // live-photo-capture, rear-cam-superwide-capability, etc.) and
        // hide the Camera icon if any return nil/absent.
        //
        // Values copied byte-for-byte from
        // `ipsws/iPhone17,3_26.5_23F77_Restore_extracted/Firmware/all_flash/DeviceTree.d47ap.im4p`
        // post-LZFSE-decompression. Sorted alphabetically for diff stability.
        // The `"<"` / `"d"` / `"x"` values that ipsw dtree shows are 4-byte
        // little-endian ints whose first byte happens to print:
        //   "<" = 0x3C = 60   (60 fps cap)
        //   "d" = 0x64 = 100  (100-ms burst duration)
        //   "x" = 0x78 = 120  (120 fps slomo cap)
        // `<nil>` properties are 0-length placeholders (the name exists but
        // there's no value blob); MGGetBoolAnswer treats those as YES too.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "camera",
            properties: [
                .init(name: "aggregate-cam-photo-zoom", length: 4, flags: 0, value: .integer(0x7D0)),
                .init(name: "aggregate-cam-video-zoom", length: 4, flags: 0, value: .integer(0x4B0)),
                .init(name: "aggregate-camera", length: 4, flags: 0, value: .integer(1)),
                .init(name: "auto-focus", length: 4, flags: 0, value: .integer(1)),
                .init(name: "auto-low-light-video", length: 4, flags: 0, value: .integer(1)),
                .init(name: "camera-hdr-version", length: 4, flags: 0, value: .integer(3)),
                .init(name: "camera-ui-version", length: 4, flags: 0, value: .integer(2)),
                .init(name: "deferred-processing", length: 4, flags: 0, value: .integer(1)),
                .init(name: "flash", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-auto-focus", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-auto-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-burst", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-burst-image-duration", length: 4, flags: 0, value: .integer(100)),
                .init(name: "front-flash-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-hdr-on", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-low-light-photo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-max-burst-length", length: 4, flags: 0, value: .integer(600)),
                .init(name: "front-max-slomo-video-fps-1080p", length: 4, flags: 0, value: .integer(120)),
                .init(name: "front-max-slomo-video-fps-720p", length: 4, flags: 0, value: .integer(120)),
                .init(name: "front-max-video-fps-1080p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-max-video-fps-4k", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-max-video-fps-720p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-max-video-zoom", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-slowmo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-stage-light-portrait", length: 0, flags: 0, value: .bytes(Data())),
                .init(name: "front-variable-frame-rate", length: 4, flags: 0, value: .integer(1)),
                .init(name: "live-effects", length: 4, flags: 0, value: .integer(1)),
                .init(name: "live-photo-auto", length: 4, flags: 0, value: .integer(1)),
                .init(name: "live-photo-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "moment-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "p3-color-space-video-recording", length: 4, flags: 0, value: .integer(1)),
                .init(name: "panorama", length: 4, flags: 0, value: .integer(1)),
                .init(name: "pearl-camera", length: 4, flags: 0, value: .integer(1)),
                .init(name: "photo-capture-on-touch-down", length: 4, flags: 0, value: .integer(1)),
                .init(name: "photos-live-video-rendering", length: 0, flags: 0, value: .bytes(Data())),
                .init(name: "pipelined-stillimage-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "portrait-lighting-strength", length: 4, flags: 0, value: .integer(1)),
                .init(name: "post-effects", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-auto-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-burst", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-burst-image-duration", length: 4, flags: 0, value: .integer(100)),
                .init(name: "rear-cam-sup-wide-af-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-cam-superwide-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-hdr-on", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-low-light-photo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-burst-length", length: 4, flags: 0, value: .integer(600)),
                .init(name: "rear-max-slomo-video-fps-1080p", length: 4, flags: 0, value: .integer(240)),
                .init(name: "rear-max-slomo-video-fps-720p", length: 4, flags: 0, value: .integer(240)),
                .init(name: "rear-max-video-fps-1080p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-fps-4k", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-fps-720p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-frame_rate", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-zoom", length: 4, flags: 0, value: .integer(3)),
                .init(name: "rear-slowmo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-stage-light-portrait", length: 0, flags: 0, value: .bytes(Data())),
                .init(name: "rear-variable-frame-rate", length: 4, flags: 0, value: .integer(1)),
                .init(name: "spatial-over-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "stage-light-portrait-preview", length: 4, flags: 0, value: .integer(1)),
                .init(name: "video-cap", length: 4, flags: 0, value: .integer(2)),
                .init(name: "video-stills", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.product.camera_node",
            description: "Add /product/camera node with full iPhone17,3 D47AP property set (62 props)",
        ),

        // ── /product/facetime (Tier C — front-camera video-call config) ──
        // d47ap carries this 11-property node (excluding AAPL,phandle).
        // FaceTime reads bitrate-{2g,3g,lte,wifi}, decoding/encoding
        // codec parameters, pref-decoding, and tnr-mode-{back,front}
        // (temporal noise reduction) at app launch. Values byte-for-byte
        // from the d47ap DT.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "facetime",
            properties: [
                .init(name: "bitrate-2g", length: 4, flags: 0, value: .integer(100)),
                .init(name: "bitrate-3g", length: 4, flags: 0, value: .integer(228)),
                .init(name: "bitrate-lte", length: 4, flags: 0, value: .integer(228)),
                .init(name: "bitrate-wifi", length: 4, flags: 0, value: .integer(2000)),
                .init(name: "decoding", length: 48, flags: 0, value: .bytes(Data([
                    0x40, 0x01, 0x00, 0x00, 0x0F, 0x00, 0xF0, 0x00,
                    0x40, 0x01, 0x00, 0x00, 0x1E, 0x00, 0xF0, 0x00,
                    0xE0, 0x01, 0x00, 0x00, 0x0F, 0x00, 0x70, 0x01,
                    0xE0, 0x01, 0x00, 0x00, 0x1E, 0x00, 0x70, 0x01,
                    0x80, 0x02, 0x00, 0x00, 0x1E, 0x00, 0xE0, 0x01,
                    0x00, 0x04, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x03,
                ]))),
                .init(name: "encoding", length: 56, flags: 0, value: .bytes(Data([
                    0x40, 0x01, 0x00, 0x00, 0x0F, 0x00, 0xF0, 0x00,
                    0x40, 0x01, 0x00, 0x00, 0x1E, 0x00, 0xF0, 0x00,
                    0xE0, 0x01, 0x00, 0x00, 0x0F, 0x00, 0x70, 0x01,
                    0xE0, 0x01, 0x00, 0x00, 0x1E, 0x00, 0x70, 0x01,
                    0x80, 0x02, 0x00, 0x00, 0x1E, 0x00, 0xE0, 0x01,
                    0x00, 0x04, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x03,
                    0x00, 0x05, 0x00, 0x00, 0x1E, 0x00, 0xD0, 0x02,
                ]))),
                .init(name: "pref-decoding", length: 8, flags: 0, value: .integer(0x0300_001E_0000_0400)),
                .init(name: "tnr-mode-back", length: 4, flags: 0, value: .integer(10)),
                .init(name: "tnr-mode-front", length: 4, flags: 0, value: .integer(10)),
            ],
            patchID: "devicetree.product.facetime_node",
            description: "Add /product/facetime node with full iPhone17,3 D47AP property set (9 props)",
        ),

        // ── /product/audio (Tier C — audio + spatial-capture flags) ──
        // d47ap carries this 31-property node (excluding AAPL,phandle).
        // Two camera-joint flags live here: `supports-spatial-audio-capture`
        // and `supports-spatial-facetime` — needed for spatial-video and
        // spatial-photo capture pipelines that combine camera + audio.
        // The remaining 29 properties are pure audio config (mic gains,
        // speaker cpms, voice trigger, channel layout, codec use-case
        // formats). Calibration cstrings (`mic-trim-gains-*`,
        // `speaker-thiele-small-*`, `speaker-trim-gains-*`) keep their
        // syscfg-reference form — replacing them with concrete values
        // from d47 wouldn't make the VM's actual mic/speaker hardware
        // match, but downstream code already handles missing-syscfg
        // gracefully.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "audio",
            properties: [
                .init(name: "acoustic-id", length: 4, flags: 0, value: .integer(8018)),
                .init(name: "actuator-cpms-bgd_100ms", length: 8, flags: 0, value: .integer(0x0000_0EEF_0000_01F4)),
                .init(name: "actuator-cpms-bgd_inst", length: 8, flags: 0, value: .integer(0x0000_1DB0_0000_06D6)),
                .init(name: "enabledChannels", length: 4, flags: 0, value: .integer(15)),
                .init(name: "historyChannels", length: 4, flags: 0, value: .integer(15)),
                .init(name: "mic-trim-gains-0", length: 12, flags: 0, value: .string("syscfg/MiGH")),
                .init(name: "mic-trim-gains-2", length: 12, flags: 0, value: .string("syscfg/MiGB")),
                .init(name: "mic-trim-gains-key-cnt", length: 4, flags: 0, value: .integer(2)),
                .init(name: "speaker-cpms-bgd_100ms", length: 8, flags: 0, value: .integer(0x0000_2328_0000_04B0)),
                .init(name: "speaker-cpms-bgd_1s", length: 8, flags: 0, value: .integer(0x0000_2328_0000_04B0)),
                .init(name: "speaker-cpms-bgd_inst", length: 8, flags: 0, value: .integer(0x0000_2328_0000_04B0)),
                .init(name: "speaker-thiele-small-0", length: 12, flags: 0, value: .string("syscfg/SpPH")),
                .init(name: "speaker-thiele-small-key-cnt", length: 4, flags: 0, value: .integer(1)),
                .init(name: "speaker-trim-gains-0", length: 12, flags: 0, value: .string("syscfg/SpGH")),
                .init(name: "speaker-trim-gains-key-cnt", length: 4, flags: 0, value: .integer(1)),
                .init(name: "stereo-sound-recording", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supportedChannels", length: 4, flags: 0, value: .integer(15)),
                .init(name: "supports-advanced-vp-chatflavor", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-always-listening", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-audio-mix", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-auto-mic-mode", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-barge-in", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-concurrent-hp-lp-mics", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-mic-modes-telephony", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-spatial-audio-capture", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-spatial-facetime", length: 4, flags: 0, value: .integer(1)),
                .init(name: "use-case-client-format", length: 96, flags: 0, value: .bytes(Data([
                    0x61, 0x64, 0x6E, 0x73, 0x80, 0xBB, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x69, 0x72, 0x69, 0x73, 0x80, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x73, 0x74, 0x70, 0x6C, 0x80, 0x3E, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ]))),
                .init(name: "use-case-dsp-in-format", length: 160, flags: 0, value: .bytes(Data([
                    0x64, 0x6B, 0x74, 0x6D, 0x80, 0xBB, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x61, 0x64, 0x6E, 0x73, 0x80, 0xBB, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x64, 0x76, 0x70, 0x73, 0x80, 0xBB, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x69, 0x72, 0x69, 0x73, 0x80, 0x3E, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x73, 0x74, 0x70, 0x6C, 0x80, 0x3E, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ]))),
                .init(name: "use-case-struct-version", length: 4, flags: 0, value: .integer(1)),
                .init(name: "voiceTriggerChannels", length: 4, flags: 0, value: .integer(1)),
                .init(name: "wireless-splitter", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.product.audio_node",
            description: "Add /product/audio node with full iPhone17,3 D47AP property set (31 props)",
        ),

        // ── /product/iopm (Tier C — always-on technology) ────────────
        // d47ap carries this 2-property node (excluding AAPL,phandle).
        // `aot-mode = 13` enables Always-On Technology — drives wake
        // policy and always-on-display behavior. POTENTIAL DISPLAY
        // RISK: if the VM display can't service the AOT init path,
        // this may need to be reverted in isolation. Test this batch
        // alongside facetime + audio + Tier B; if display breaks,
        // remove this AddChildNodePatch entry first before bisecting
        // the rest.
        AddChildNodePatch(
            parentPath: ["device-tree", "product"],
            nodeName: "iopm",
            properties: [
                .init(name: "aot-linger-time-ms", length: 4, flags: 0, value: .integer(0)),
                .init(name: "aot-mode", length: 4, flags: 0, value: .integer(13)),
            ],
            patchID: "devicetree.product.iopm_node",
            description: "Add /product/iopm node with aot-mode=13 + aot-linger-time-ms=0 (2 props)",
        ),

        // ── ISP / SMC camera-flag stubs (Tier F — /arm-io subtree) ──
        // Adds minimal stub nodes carrying ONLY the camera-related
        // properties that libMobileGestalt / SpringBoard / Camera.app
        // userland code walks under `/arm-io/isp`, `/arm-io/ispRtb`,
        // and `/arm-io/smc/iop-smc-nub/smc-ext-charger`.
        //
        // d47ap carries these as full hardware-attach nodes (65/53/14
        // properties). We deliberately do NOT replicate the full set
        // — they describe a real ISP / SMC chip with MMIO regions,
        // interrupts, DART/IOMMU bindings, kext-`compatible` strings
        // etc., and the VM has no such hardware. Stubbing only the
        // camera-* properties + the mandatory `name` (no `compatible`,
        // no `device_type`, no `reg`, no `interrupts`) means:
        //
        //   - IOKit registry sees these nodes appear under `/arm-io`.
        //   - No kext (`AppleH16CamIn`, AppleSMC, etc.) finds a
        //     matching `compatible` and binds, so no driver probe
        //     can fail-and-panic on missing hardware.
        //   - Userland code that resolves these paths via
        //     `IORegistryEntryFromPath` + `IORegistryEntryGetProperty`
        //     still finds the camera-* properties on the empty stub.
        //
        // RISK: still untested. If an IOKit walker reports the empty
        // node and a userland daemon (e.g. cameracaptured) takes the
        // node's presence as "real ISP attached" and then crashes
        // trying to talk to it, the symptom is likely a boot stall or
        // a camera-daemon respawn loop visible in logs. Bisect by
        // removing /arm-io/isp + /arm-io/ispRtb first if so.
        //
        // The three nodes are added in dependency order: each parent
        // before its children. The patcher walks `experimentalNodeAdditions`
        // in array order against the in-memory tree, so later entries
        // can resolve parents added by earlier entries.

        // /arm-io/smc — empty stub (parent for iop-smc-nub).
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io"],
            nodeName: "smc",
            properties: [],
            patchID: "devicetree.arm_io.smc_stub",
            description: "Add /arm-io/smc empty stub (parent for smc-ext-charger chain)",
        ),

        // /arm-io/smc/iop-smc-nub — empty stub (parent for smc-ext-charger).
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io", "smc"],
            nodeName: "iop-smc-nub",
            properties: [],
            patchID: "devicetree.arm_io.smc.iop_smc_nub_stub",
            description: "Add /arm-io/smc/iop-smc-nub empty stub (parent for smc-ext-charger)",
        ),

        // /arm-io/smc/iop-smc-nub/smc-ext-charger — carries camera-driver.
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io", "smc", "iop-smc-nub"],
            nodeName: "smc-ext-charger",
            properties: [
                .init(name: "camera-driver", length: 14, flags: 0, value: .string("AppleH16CamIn")),
            ],
            patchID: "devicetree.arm_io.smc.smc_ext_charger_camera_driver",
            description: "Add /arm-io/smc/iop-smc-nub/smc-ext-charger with camera-driver='AppleH16CamIn'",
        ),

        // /arm-io/isp — minimal stub carrying camera-front + camera-rear.
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io"],
            nodeName: "isp",
            properties: [
                .init(name: "camera-front", length: 4, flags: 0, value: .integer(1)),
                .init(name: "camera-rear", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.arm_io.isp_camera_flags",
            description: "Add /arm-io/isp stub with camera-front=1 + camera-rear=1",
        ),

        // /arm-io/ispRtb — minimal stub carrying camera-front + camera-rear.
        AddChildNodePatch(
            parentPath: ["device-tree", "arm-io"],
            nodeName: "ispRtb",
            properties: [
                .init(name: "camera-front", length: 4, flags: 0, value: .integer(1)),
                .init(name: "camera-rear", length: 4, flags: 0, value: .integer(1)),
            ],
            patchID: "devicetree.arm_io.ispRtb_camera_flags",
            description: "Add /arm-io/ispRtb stub with camera-front=1 + camera-rear=1",
        ),
    ]
}
