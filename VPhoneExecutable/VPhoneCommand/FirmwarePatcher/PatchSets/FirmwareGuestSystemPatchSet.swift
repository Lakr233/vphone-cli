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
                identifier: "dyld-cfw-mis_trust_auth",
                title: "MIS online authorization",
                summary: """
                Accepts a provisioning profile that wants online authorization. The guest is \
                hacktivated and has no activation record, so it can never obtain the device \
                identity such a profile is checked against; without this, an app signed with a \
                free personal-team certificate installs but refuses to launch.
                """,
                target: .dyldSharedCache,
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
                identifier: "system-installd-cfw-adhoc_signature",
                title: "installd ad-hoc signatures",
                summary: """
                Lets Xcode install an app the guest would otherwise refuse. installd asks \
                MobileIdentityService to validate a bundle without allowing an ad-hoc \
                signature, so anything not signed with an Apple leaf fails at \
                0xE8008014 even though the guest runs unsigned code perfectly well. A \
                hook in /usr/lib/libmisfix.dylib, loaded into installd, sets the option \
                MIS already understands. Nothing in the dyld shared cache is touched.
                """,
                target: .guestExecutable(path: "/usr/libexec/installd"),
            ),
            VPhonePatchDeclaration(
                identifier: "system-misagent-cfw-device_identity",
                title: "misagent device identity",
                summary: """
                Lets a provisioning profile written for a device you already own install on \
                this guest. misagent compares the profile's ProvisionedDevices against the \
                UDID MobileGestalt reports, and a VM's UDID is in nobody's list, so a paid \
                team's profile fails at 0xE8008012. The same hook, loaded into misagent, \
                answers that one query with the UDID set in /usr/lib/libmisfix.plist. Off \
                until a UDID is set there, and it does not change what Xcode or lockdown \
                report.
                """,
                target: .guestExecutable(path: "/usr/libexec/misagent"),
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
                summary: "Installs the launchd environment and plists the guest tools read.",
                target: .guestFile(path: "/Library/LaunchDaemons"),
                bootEssential: true,
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

    /// The preset parameter `system-systemversion-cfw-build_version` reads.
    public static let buildVersionParameter = "BuildVersion"
}
