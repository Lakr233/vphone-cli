// VPhoneCustomFirmwareDyldSharedCacheVerbsCommand.swift — `cfw` verbs for the dyld-shared-cache patchers.
//
// Each command here is a thin face over a type in `FirmwarePatcher/DSC/Patchers/`,
// and each one answers to the same verb name, the same positional arguments and
// the same flags as the `scripts/patchers/cfw.py` subcommand it replaces
// (`cfw.py:356-432`). That is not a stylistic choice: `scripts/cfw_install*.sh`,
// `cfw-kit/lib/base_stages.sh` and `scripts/patch_{camera,hv_vmm}_userland.sh`
// invoke these by hand-written argv, so the argv is the contract.
//
// Nothing here parses the patchers' output, so the bar for stdout is that an
// install log still reads like the Python's — which is why every command passes
// `log: stdout` rather than letting the library default to stderr, and prints
// nothing of its own on top. The library already emits the Python's lines,
// including the trailing "… complete".
//
// Exit codes follow the Python exactly: every one of these verbs exits 0 on a
// no-op as well as on a patch (a self-gating patcher that finds a pre-iOS-27
// userland has done its job), and non-zero only when the patcher throws.

import ArgumentParser
import FirmwarePatcher
import Foundation

enum VPhoneCustomFirmwareDyldSharedCacheVerbs {
    /// Registered into `vphone-cli cfw` by `VPhoneCustomFirmwareCommand`.
    static var all: [ParsableCommand.Type] {
        [
            VPhoneCustomFirmwarePatchHypervisorVirtualMachineDyldSharedCacheCommand.self,
            VPhoneCustomFirmwarePatchIOMFBSwapEndCommand.self,
            VPhoneCustomFirmwarePatchIOMFBForceKernCommand.self,
            VPhoneCustomFirmwarePatchDyldSharedCacheMaxSlideCommand.self,
            VPhoneCustomFirmwarePatchLSDEmbeddedRegCommand.self,
            VPhoneCustomFirmwarePatchXPCLWCRCommand.self,
            VPhoneCustomFirmwarePatchLockdownModeCommand.self,
            VPhoneCustomFirmwarePatchCameraDyldSharedCacheCommand.self,
        ]
    }

    /// Where the patchers' progress lines go.
    ///
    /// The DSC library defaults some patchers to stderr and some to stdout; the
    /// Python put all of it on stdout, and an install log is read as one stream,
    /// so all eight verbs are pinned here.
    static let stdout: @Sendable (String) -> Void = { print($0) }

    /// `int(value, 0)`, which is how `cfw.py` reads `--target-size 0x560`.
    ///
    /// Base is taken from the prefix, so `0x560`, `0o2540`, `0b10101100000` and
    /// `1376` are the same number and a bare `0560` is decimal — Python's rule,
    /// not C's. Underscores are accepted as digit separators, as Python accepts
    /// them.
    static func parseCInteger(_ value: String) throws -> UInt32 {
        let cleaned = value.replacingOccurrences(of: "_", with: "")
        let (radix, digits): (Int, Substring) =
            switch cleaned.prefix(2).lowercased() {
            case "0x": (16, cleaned.dropFirst(2))
            case "0o": (8, cleaned.dropFirst(2))
            case "0b": (2, cleaned.dropFirst(2))
            default: (10, cleaned[...])
            }
        guard !digits.isEmpty, let parsed = UInt32(digits, radix: radix) else {
            throw ValidationError("'\(value)' is not a valid number. Enter a decimal or hexadecimal value.")
        }
        return parsed
    }
}

// MARK: - patch-hv-vmm-dsc

struct VPhoneCustomFirmwarePatchHypervisorVirtualMachineDyldSharedCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-hv-vmm-dsc",
        abstract: "Mangle the \"kern.hv_vmm_present\" sysctl name in the userland dyld cache",
        discussion: """
        The EXP variant's userland half of the hv_vmm rename: every cstring
        occurrence of the sysctl name inside an executable mapping is rewritten,
        so the identity, store and consumer-service dylibs that ask "am I in a
        VM?" get ENOENT and read as a real device.

        It is a blacklist, not a list: a site is patched unless the dylib that
        contains it is one of the paravirt consumers that must keep seeing the
        truth — the graphics passthrough and compute/accel fast paths, which
        break if they think they are on bare metal. A site whose containing
        dylib cannot be named is left alone rather than guessed at.

        Every page written is re-attested against the cache's code-signature
        slots, and so is every page found already mangled: a cache whose bytes
        and slot hashes disagree is one the guest page-faults on. A re-run is
        therefore a no-op that still repairs attestation.

        Runs while the SystemOS cryptex is mounted on the host, wrapped by
        `scripts/patch_hv_vmm_userland.sh dsc`.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Flag(name: .customLong("dry-run"), help: "Report every site and write nothing")
    var dryRun = false

    func run() throws {
        try DyldSharedCacheHypervisorVirtualMachinePatcher.patch(
            chunksDirectory: chunksDirectory,
            dryRun: dryRun,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}

// MARK: - patch-iomfb-swapend

struct VPhoneCustomFirmwarePatchIOMFBSwapEndCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-iomfb-swapend",
        abstract: "Shrink IOMobileFramebuffer's _kern_SwapEnd payload to what the base userclient accepts",
        discussion: """
        iOS 26.0/26.0.1 and 18.x ship a `_kern_SwapEnd` that hands the
        userclient a larger input-state struct than the vphone600 base kernel's
        `checkStructureInputSize` will take, so every present is refused and the
        VZ view stays black. This rewrites the size register in the
        `io_connect_method` set-up — one `mov w3, #imm` — and re-attests the page.

        The site is found by shape, not offset: the selector move, then the size
        move, then the two zeroed argument registers, then the call. A userland
        whose SwapEnd no longer has that shape is an error, not a silent skip.

        --target-size takes the size the base kernel accepts, in any base
        `int(x, 0)` reads (the installers pass 0x560). Default is 0x588, the
        26.4 base's. iOS 27 is not patched this way at all — see
        `patch-iomfb-force-kern`.

        Already-correct is a no-op that still re-attests, so re-running over a
        patched cache is safe.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Option(
        name: .customLong("target-size"),
        help: "Payload size the base kernel's userclient accepts (hex or decimal)",
        transform: VPhoneCustomFirmwareDyldSharedCacheVerbs.parseCInteger,
    )
    var targetSize: UInt32 = DyldSharedCacheIOMFBSwapEndPatcher.defaultTargetSize

    @Flag(name: .customLong("dry-run"), help: "Report the site and the rewrite, and write nothing")
    var dryRun = false

    func run() throws {
        try DyldSharedCacheIOMFBSwapEndPatcher.patch(
            chunksDirectory: chunksDirectory,
            targetSize: targetSize,
            dryRun: dryRun,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}

// MARK: - patch-iomfb-force-kern

struct VPhoneCustomFirmwarePatchIOMFBForceKernCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-iomfb-force-kern",
        abstract: "Retarget IOMobileFramebuffer's public Swap* trampolines onto their _kern_Swap* siblings",
        discussion: """
        iOS 27's IOMobileFramebuffer defaults present onto the `_virt_*`
        callback path, which the 26.4 paravirt GPU never receives — so the host
        scans out nothing and the VZ view stays black. Each public
        `_IOMobileFramebufferSwap*` entry point is a thin dispatch trampoline;
        this retargets its branch at the `_kern_Swap*` sibling, which is the
        userclient method-5 path the paravirt GPU does scan out.

        Only a function that still looks like a thin trampoline is retargeted.
        One that does not is left on the virt path and reported, and a cache
        missing a required entry point is refused before anything is written —
        so a half-forced IOMFB is not a state this can leave behind.

        `_kern_Swap*` are stripped local symbols, so the cache's `.symbols`
        side file has to be present; without it there would be zero pairs to
        find, which would read as "this userland has none".

        Pairs with the KernelJailbreakPatchIomfbSwap kernel patches, which make the
        userclient accept 27's native 0x6e0 SwapEnd struct. Modified pages are
        re-attested; an already-forced cache is a no-op.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Flag(name: .customLong("dry-run"), help: "Report every entry point and write nothing")
    var dryRun = false

    func run() throws {
        try DyldSharedCacheIOMFBForceKernPatcher.patch(
            chunksDirectory: chunksDirectory,
            dryRun: dryRun,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}

// MARK: - patch-dsc-maxslide

struct VPhoneCustomFirmwarePatchDyldSharedCacheMaxSlideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-dsc-maxslide",
        abstract: "Zero dyld_cache_header.maxSlide when the cache would overflow the kernel's shared region",
        discussion: """
        The vphone600 26.x kernel reserves a fixed 6 GiB shared region and
        charges it the cache's mapped span plus the header's maxSlide. iOS 27's
        userland cache (~5.95 GiB) plus 512 MiB of slide does not fit, so
        `_shared_region_map_and_slide` returns ENOMEM, dyld cannot map libSystem
        and launchd — pid 1 — takes the kernel down with it. Zeroing maxSlide
        lets the cache map at slide 0, which fits.

        Self-gating on the cache's real span, so a 26.x or 18.x base that fits
        with full slide is left alone and a cache already at maxSlide 0 is left
        alone either way. Both are reported and exit 0.

        --force zeroes maxSlide even when the cache fits — the opt-in behind
        FORCE_DSC_MAXSLIDE=1 for a non-27 base.

        No re-attestation: maxSlide lives in the cache header, which is not one
        of the cs_validate'd code pages.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Flag(name: .customLong("dry-run"), help: "Decide and report, and write nothing")
    var dryRun = false

    @Flag(name: .customLong("force"), help: "Zero maxSlide even when the cache already fits")
    var force = false

    func run() throws {
        try DyldSharedCacheMaxSlidePatcher.patch(
            chunksDirectory: chunksDirectory,
            dryRun: dryRun,
            force: force,
        )
    }
}

// MARK: - patch-lsd-embedded-reg

struct VPhoneCustomFirmwarePatchLSDEmbeddedRegCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-lsd-embedded-reg",
        abstract: "Open lsd's embedded-registration path so JB app installs can register",
        discussion: """
        On iOS 27, `-[_LSDModifyClient
        clientIsEntitledForEmbeddedRegistrationOperations]` demands three
        privileged entitlements from its XPC peer, which nothing we install has,
        and uicache's own registration call is a stub. That leaves an app
        installed and unregistered — no icon, no launch. NOPing the gate makes
        the method fall through to success, which is what unblocks
        vphoned/TrollStore/uicache installs.

        One instruction, found by the method's control-flow shape rather than by
        offset, and the page is re-attested afterwards.

        Self-gating: a pre-iOS-27 userland has no such method, which is reported
        and exits 0. A userland that has the method but not the shape is an
        error — a LaunchServices rewrite has to stop the install rather than be
        guessed at, because the silent alternative boots a guest in which no app
        can register.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Flag(name: .customLong("dry-run"), help: "Report the gate and write nothing")
    var dryRun = false

    func run() throws {
        try DyldSharedCacheLSDEmbeddedRegPatcher.patch(
            chunksDirectory: chunksDirectory,
            dryRun: dryRun,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}

// MARK: - patch-xpc-lwcr

struct VPhoneCustomFirmwarePatchXPCLWCRCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-xpc-lwcr",
        abstract: "Stop libxpc's Lightweight Code Requirement self-check from brk-aborting",
        discussion: """
        Under our code-signing environment, iOS 27's LWCR matcher hands
        `_xpc_token_satisfies_lwcr` the contradictory pair (matched = 0,
        error_code = MATCH). The consistency assertion takes that as
        memory corruption and traps, which crash-loops every daemon that pins an
        entitlement peer-requirement on its peer — intelligencetasksd,
        searchpartyd, transparencyd, bluetoothd and the rest.

        Three words: `matched` is derived from `error_code` instead of being
        cross-checked against it, and the abort is dropped. The pages are
        re-attested.

        Self-gating: the symbol is absent on pre-iOS-27 libxpc, which is
        reported and exits 0, and a cache already carrying the patched shape is
        a no-op. A cache with the symbol but neither shape is an error.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Flag(name: .customLong("dry-run"), help: "Report the three sites and write nothing")
    var dryRun = false

    func run() throws {
        try DyldSharedCacheXPCLWCRPatcher.apply(
            directory: chunksDirectory,
            dryRun: dryRun,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}

// MARK: - patch-lockdown-mode

struct VPhoneCustomFirmwarePatchLockdownModeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-lockdown-mode",
        abstract: "Stop os_lockdown_mode_enabled() aborting when the Lockdown Mode sysctl is missing",
        discussion: """
        iOS 27's libSystem treats a failed read of
        `security.mac.lockdown_mode_state_public` as unrecoverable and aborts.
        The vphone600 26.x kernel does not implement that MAC sysctl, launchd is
        the first caller, and pid 1 aborting is a kernel panic before the guest
        ever reaches a login screen.

        NOPing the error branch lets the query fall through with 0 — Lockdown
        Mode off, which is the truth here — and boot continues. The page is
        re-attested.

        Self-gating: pre-iOS-27 userlands have no such symbol, which is reported
        and exits 0, and a cache already patched is a no-op.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Flag(name: .customLong("dry-run"), help: "Report the gate and write nothing")
    var dryRun = false

    func run() throws {
        try DyldSharedCacheLockdownModePatcher.patch(
            chunksDirectory: chunksDirectory,
            dryRun: dryRun,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}

// MARK: - patch-camera-dsc

struct VPhoneCustomFirmwarePatchCameraDyldSharedCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-camera-dsc",
        abstract: "Stub the AVFoundation init-time validation that crashes Camera.app on a VM",
        discussion: """
        The host-side virtual camera synthesises a single `vphone-cam`
        AVCaptureDevice through cameracaptured's device-list, discovery-session
        and serializer paths. AVFoundation's init-time validation does not
        survive a device assembled that way, so Camera.app dies on launch. This
        short-circuits the entry points that do that validation to a constant
        return, which is what makes the app launch-survivable.

        <dsc_header> is the unsuffixed `dyld_shared_cache_arm64e` file — the one
        the symbols resolve against, not a chunk. The Python takes it as a
        separate argument because `ipsw dyld symaddr` wants a file; it is passed
        through for the same reason.

        --force accepts an entry point whose prologue is neither the expected
        `pacibsp` nor the replacement already in place, which is otherwise
        refused rather than overwritten blind. Modified pages are re-attested;
        an already-patched cache is a no-op.
        """,
    )

    @Argument(
        help: "The guest's /System/Library/Caches/com.apple.dyld directory",
        transform: URL.init(fileURLWithPath:),
    )
    var chunksDirectory: URL

    @Argument(
        help: "The dyld_shared_cache_arm64e file symbols resolve against (not a chunk)",
        transform: URL.init(fileURLWithPath:),
    )
    var dscHeader: URL

    @Flag(name: .customLong("dry-run"), help: "Report every site and write nothing")
    var dryRun = false

    @Flag(name: .customLong("force"), help: "Patch an entry point whose prologue is not the expected one")
    var force = false

    func run() throws {
        try DyldSharedCacheCameraPatcher.applyAll(
            chunksDirectory: chunksDirectory,
            symbolCacheURL: dscHeader,
            dryRun: dryRun,
            force: force,
            log: VPhoneCustomFirmwareDyldSharedCacheVerbs.stdout,
        )
    }
}
