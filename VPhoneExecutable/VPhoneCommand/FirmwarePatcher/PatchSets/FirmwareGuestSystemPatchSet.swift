// FirmwareGuestSystemPatchSet.swift — Manifest for the mounted guest volume.
//
// What `cfw install` does after the restore: the shared-cache policy gates a 27
// userland needs, the handful of system daemons that must be patched to start on
// a research board, and the vphone payload itself.
//
// Unlike the boot chain, several of these are Mach-O or shared-cache edits that
// emit no patch record — a string mangled in place, a file installed. Their
// identifiers name the operation instead of mirroring a record, and they are
// still the names a preset selects and the UI lists.

import Foundation
import VPhonePatchKit

public enum FirmwareGuestSystemPatchSet {
    public static let identifier = "com.vphone.patchset.guest.system"

    private static let ios27 = VPhonePatchApplicability(iOSBase: .major(27))

    /// The bases where short-circuiting `checkTrustAndAuthorization` in the
    /// shared cache is survivable.
    ///
    /// Not a preference — a preference belongs in a preset's block list, and
    /// `standard` blocks this one too. This is the harder statement: on iOS 27 the
    /// patch stops the guest booting. TXM rejects the re-attested page, dyld
    /// cannot map `libSystem.B.dylib`, and `initproc failed to start`
    /// (issue #532). Without the gate, `experimental` — which is `Kind = All` —
    /// would hand a 27 user an unbootable VM.
    ///
    /// An unreadable base satisfies only `.any`, so an unknown release skips the
    /// patch. That is the safe direction here.
    private static let misTrustAuthBases = VPhonePatchApplicability(
        iOSBase: .oneOf([.major(18), .major(26)]),
    )

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Guest System",
        summary: "Shared-cache policy gates, patched system daemons and the vphone guest payload",
        patches: [
            // MARK: Shared Cache Policy

            VPhonePatchDeclaration(
                identifier: "dyld-boot-maxslide",
                title: "Shared cache max slide",
                summary: """
                Zeroes the shared cache's maximum slide. A 27 userland otherwise computes a slide \
                the patched cache cannot satisfy.
                """,
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-lsd_embedded_reg",
                title: "lsd registration entitlement",
                summary: "Lets lsd register the guest's embedded app bundles.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-xpc_lwcr",
                title: "XPC lightweight code requirements",
                summary: "Stops XPC refusing a peer whose lightweight code requirement no longer matches.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-boot-lockdown_mode",
                title: "Lockdown mode sysctl gate",
                summary: "Stops a failed lockdown-mode sysctl read being treated as an error.",
                target: .dyldSharedCache,
                applicability: ios27,
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "dyld-exp-mis_trust_auth",
                title: "MIS online authorization",
                summary: """
                Accepts a provisioning profile that wants online authorization, by short-circuiting \
                the check in the shared cache. Off by default: libmisfix.dylib already declines the \
                same check from userspace in installd, misagent and SpringBoard, and editing the \
                cache for it stops an iOS 27 guest booting. Not offered on iOS 27.
                """,
                target: .dyldSharedCache,
                applicability: misTrustAuthBases,
            ),

            // MARK: System Daemons

            VPhonePatchDeclaration(
                identifier: "system-seputil-boot-gigalocker_uuid",
                title: "seputil Gigalocker UUID",
                summary: "Points seputil at the renamed Gigalocker so key material resolves.",
                target: .guestExecutable(path: "/usr/libexec/seputil"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-diskimagesiod-cfw-is_mount_complete",
                title: "diskimagesiod mount completion",
                summary: "Reports the personalised developer image as mounted on a 27 userland.",
                target: .guestExecutable(path: "/usr/libexec/diskimagesiod"),
                applicability: ios27,
            ),
            VPhonePatchDeclaration(
                identifier: "system-launchd_cache_loader-boot-unsecure_cache_gate",
                title: "launchd cache loader gate",
                summary: "Lets the launchd cache loader accept the patched, unsealed cache.",
                target: .guestExecutable(path: "/usr/libexec/launchd_cache_loader"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-mobileactivationd-boot-should_hactivate",
                title: "mobileactivationd activation",
                summary: "Reports the device activated, so the guest reaches the home screen.",
                target: .guestExecutable(path: "/usr/libexec/mobileactivationd"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-launchd-boot-jetsam_panic_guard_bypass",
                title: "launchd jetsam panic guard",
                summary: "Stops launchd panicking when jetsam reaps a process the VM needs.",
                target: .guestExecutable(path: "/sbin/launchd"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-debugserver-cfw-install",
                title: "debugserver",
                summary: "Installs a debugserver that can attach in the guest.",
                target: .guestFile(path: "/usr/bin/debugserver"),
            ),
            VPhonePatchDeclaration(
                identifier: "system-campo-cfw-entitlements",
                title: "Campo entitlements",
                summary: "Widens Campo's entitlements so the 27 setup assistant completes.",
                target: .guestEntitlements(path: "/System/Library/PrivateFrameworks/Campo.framework/Campo"),
                applicability: ios27,
            ),

            // MARK: Guest Payload

            VPhonePatchDeclaration(
                identifier: "system-gigalocker-boot-rename",
                title: "Gigalocker rename",
                summary: "Renames the data volume's Gigalocker so the guest recreates it.",
                target: .guestFile(path: "/private/var/Gigalocker"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-extensions-boot-gpu_bundle",
                title: "GPU driver bundle",
                summary: "Installs the GPU bundle the virtual display needs.",
                target: .guestFile(path: "/System/Library/Extensions"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-vphoned-boot-install",
                title: "vphoned",
                summary: "Installs the guest daemon the host talks to over VSOCK.",
                target: .guestFile(path: "/usr/local/bin/vphoned"),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "system-launchdaemons-boot-environment",
                title: "Guest environment",
                summary: """
                Installs the launchd environment and plists the guest tools read, and the hooks \
                launchd and SystemHook insert at spawn. Among them is libmisfix.dylib, inserted \
                into installd, misagent and SpringBoard, which lets Xcode install and launch an \
                app signed for someone else's team, or ad hoc, without writing the shared cache, \
                and into lockdownd and remoted, which tell the host a configured UDID. It also \
                ships libhapticsfix.dylib, which SystemHook loads into SpringBoard so UIKit's \
                feedback engine takes the no-haptics path instead of crashing on the VM's absent \
                haptic hardware.
                """,
                target: .guestFile(path: "/Library/LaunchDaemons"),
                bootEssential: true,
            ),
            // MARK: Audio

            VPhonePatchDeclaration(
                identifier: virtioSoundDriver,
                title: "Virtual sound driver",
                summary: """
                Installs the CoreAudio HAL plugin that plays the guest's audio through the VM's \
                virtio sound device. iOS ships the kernel driver but not this half, so without \
                it nothing reaches the Mac's speakers.
                """,
                target: .guestFile(path: "/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioSpeakerRouteThrows,
                title: "VirtualAudio speaker-route throws",
                summary: """
                Turns VirtualAudio's \"No default VAD present\" exception into a quiet return. \
                Applying a speaker route with no default VAD throws through an AudioServerPlugIn \
                callback, which cannot propagate it: audiomxd aborts, and the saved route state \
                replays the same throw into every launch. The speaker route the virtio plugin \
                publishes is what makes the walk reach that throw, so the two patches go together.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioMuteSetThrow,
                title: "VirtualAudio mute-set throw",
                summary: """
                Turns the CAException VirtualAudio throws when the HAL server refuses its \
                device-level mute set into a quiet return. iOS's HAL never forwards that \
                selector to a plugin device, and RoutingManager catches the throw by \
                abandoning the route — the aggregate is left on Null_Device and the guest \
                is silent. With the throw quieted, the route survives on the virtio device.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioSpeakerProtectionGate,
                title: "VirtualAudio speaker-protection gate",
                summary: """
                Stops the ringtone route handler from declining its own finished route for lack \
                of HAL Speaker Protection — a capability only a physical codec reports, whose \
                query never leaves VirtualAudio. The decline leaves the vdef playing into \
                Null_Device, silent with the volume dead; with the gate opened, the route keeps \
                the virtio device it already built. The handler for routes that play and record \
                has the same gate, and declines every recording app's route; it is opened too.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioVolumeModePrecondition,
                title: "VirtualAudio volume-mode precondition",
                summary: """
                One step after the speaker-protection gate, the same handler declines the \
                finished route because its software-volume mode is not the kHardwareOnlyReadOnly \
                the routing database demands — a mismatch every virtio-plugin device carries, \
                since the mode a VM's device reports is SoftwareHardwareMix. The decline throws \
                past the route's own teardown, leaving the session on Null_Device: silent, \
                volume dead. With the precondition opened, the route keeps the virtio aggregate \
                it already built.
                """,
                target: .guestExecutable(path: "/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio"),
            ),
            VPhonePatchDeclaration(
                identifier: virtualAudioGraphConfigurations,
                title: "VirtualAudio speaker graph chains",
                summary: """
                Moves every speaker_* entry in the tuning set's graph_configurations.plist from the \
                `clhs` HAL SpeakerProtection chain to the `dflt` generic graph chain the mic \
                configurations use. The HAL chain's construction looks a physical "Speaker" device \
                up in the device registry and throws when a VM has none, which is what still kills \
                every speaker route once the route walk itself survives.
                """,
                target: .guestFile(path: "/Library/Audio/Tunings"),
            ),
            VPhonePatchDeclaration(
                identifier: prebootBoardAudio,
                title: "iPad audio configuration",
                summary: """
                Gives an iPad guest's restored Preboot device tree the iPad's own audio node, as \
                fw patch now does. Earlier trees kept the iPhone's, whose acoustic ID names tunings \
                an iPad image does not ship, so iOS's audio routing failed to start. Needs the \
                iPad's device tree in the VM's FirmwareOriginals.
                """,
                target: .prebootDeviceTree,
            ),
            VPhonePatchDeclaration(
                identifier: prebootHaptics,
                title: "Haptics node",
                summary: """
                Removes the haptics node from a guest's restored Preboot device tree, iPhone or \
                iPad, as fw patch now does. With it iOS believes the guest has a Taptic Engine, \
                plays every tone with its haptic track, and drops the tone when the haptic engine \
                a VM does not have fails to start.
                """,
                target: .prebootDeviceTree,
            ),

            VPhonePatchDeclaration(
                identifier: "system-systemversion-cfw-build_version",
                title: "Reported build version",
                summary: """
                Rewrites the guest's SystemVersion build string. Needs a build to write: the \
                preset's BuildVersion parameter, or the SPOOF_BUILD environment variable. With \
                neither, this patch has nothing to do even when it is on.
                """,
                target: .guestFile(path: "/System/Library/CoreServices/SystemVersion.plist"),
            ),
        ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.guest.system"],
    )

    /// The virtio sound HAL plugin, installed by `cfw install` and by the
    /// environment update.
    public static let virtioSoundDriver = "system-virtiosound-cfw-hal_plugin"

    /// The no-default-VAD throw VirtualAudio must survive when the virtio
    /// plugin publishes the guest's speaker route.
    public static let virtualAudioSpeakerRouteThrows = "system-virtualaudio-cfw-speaker_route_throws"

    /// The mute-set CAException that makes VirtualAudio abandon the speaker
    /// route when the HAL server refuses the device-level unmute.
    public static let virtualAudioMuteSetThrow = "system-virtualaudio-cfw-mute_set_throw"

    /// The branch that declines a finished route for lack of HAL Speaker
    /// Protection, opened so the ringtone route keeps the virtio device it
    /// already built instead of falling back to Null_Device, and so a route
    /// that also records is not refused.
    public static let virtualAudioSpeakerProtectionGate = "system-virtualaudio-cfw-speaker_protection_gate"

    /// The precondition that declines a finished route whose software-volume
    /// mode is not the kHardwareOnlyReadOnly the routing database demands,
    /// opened one step after the speaker-protection gate so the route keeps
    /// the virtio aggregate it already built.
    public static let virtualAudioVolumeModePrecondition = "system-virtualaudio-cfw-volume_mode_precondition"

    /// The speaker chains in graph_configurations.plist, moved onto the
    /// generic graph path so the DSP chain factory never needs the physical
    /// Speaker device a VM does not have.
    public static let virtualAudioGraphConfigurations = "system-virtualaudio-cfw-speaker_graph_chains"

    /// The iPad audio node repair in the restored Preboot device tree, for an
    /// iPad VM patched before `fw patch` copied the board's node.
    public static let prebootBoardAudio = "preboot-cfw-devicetree_board_audio"

    /// The haptics node removal in the restored Preboot device tree, for any
    /// VM patched before `fw patch` removed it from every guest's tree.
    public static let prebootHaptics = "preboot-cfw-devicetree_haptics"

    /// The preset parameter `system-systemversion-cfw-build_version` reads.
    public static let buildVersionParameter = "BuildVersion"
}
