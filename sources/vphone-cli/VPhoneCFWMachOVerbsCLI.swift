// VPhoneCFWMachOVerbsCLI.swift — `cfw` verbs for the standalone Mach-O patchers.
//
// Six faces over `FirmwarePatcher/CFW/Patches/`, replacing
// `"$PYTHON3" scripts/patchers/cfw.py <verb> <binary>` in `cfw_install*.sh`,
// `cfw-kit/` and `scripts/patch_hv_vmm_userland.sh`. The verb names, their
// positional arguments and their flags are exactly the Python's — `cfw.py`
// gives only `patch-watchdogd` a `--dry-run`, so only that one has one here.
//
// RE-ATTESTATION. Each library type decides for itself whether to recompute the
// CodeDirectory slot hash of the page it dirties, and the settings below are
// chosen so the bytes these verbs write equal the bytes the Python writes:
//
//   * seputil and mobileactivationd re-attest by default, which the Python does
//     not do — `reattest: false` / `resign: false` restores parity.
//   * launchd_cache_loader, launchd (jetsam) and diskimagesiod default to off,
//     matching their Python. Passed explicitly anyway, so the choice is visible
//     at the call site rather than inherited from a default that could move.
//   * watchdogd has no switch, and needs none: `cfw_patch_watchdogd.py` calls
//     `cfw_macho_codesign.reattest_modified_offsets` itself, so both sides
//     re-attest and both write the same file.
//
// Nothing is lost by turning it off: every shipped caller runs `ldid_sign` over
// the binary on the next line, which rebuilds the signature whole.
//
// STDOUT. Each library type already prints its own progress, so — as with
// `patch-build-version` and friends in VPhoneCFWPatchCLI.swift — these commands
// print nothing of their own. The Python writes every line to stdout, so the
// log closure is `print` even for the two types whose default is stderr.
//
// IDEMPOTENCE. The Swift recognises its own output and reports "already
// patched" without writing; several of the Pythons do not (seputil's anchor
// string is gone after the first run, the cache-loader gate is no longer a
// conditional branch) and exit 1 on a second run. That difference is
// deliberate and documented in each library type's header — a re-run over an
// already-installed volume is a normal thing for `cfw install` to do.

import ArgumentParser
import FirmwarePatcher
import Foundation

/// Where these verbs send patcher progress: stdout, like the Python.
private let machOVerbLog: @Sendable (String) -> Void = { print($0) }

// MARK: - Truncation guard

/// Refuse a file whose Mach-O header promises more than the file holds.
///
/// This used to be load-bearing: `MachOParser` walked the load-command table
/// checking only that each command's 8-byte header fit, and `Data.loadLE` is a
/// `precondition`, so a header claiming a 2312-byte table in a 64-byte file
/// killed the process with SIGTRAP and exit 133 rather than raising. The parser
/// bounds every command now (`MachOParser.forEachLoadCommand`), so the trap is
/// gone either way and this is kept for the message: "truncated Mach-O — the
/// header claims 23 load command(s) in 2312 bytes, and the file is 64 bytes"
/// names the problem, where the library can only say it found no segments.
///
/// Deliberately narrow: it only looks at a native 64-bit Mach-O header and only
/// asks whether the load commands fit. Anything else — text, a fat header, a
/// 32-bit image — passes straight through, and the library's own
/// "not a 64-bit Mach-O" message is what the caller sees. Nothing the library
/// accepts today is rejected here.
private func requireUntruncatedMachO(at url: URL) throws {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 32), header.count == 32 else { return }

    let magic = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    guard UInt32(littleEndian: magic) == 0xFEED_FACF else { return }

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    guard let fileSize = size else { return }

    let numberOfCommands = Int(UInt32(littleEndian: header.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
    }))
    let sizeOfCommands = Int(UInt32(littleEndian: header.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
    }))

    // A load command is 8 bytes at its smallest (cmd + cmdsize), so a header
    // claiming more commands than that much room is lying about one of the two.
    guard 32 + sizeOfCommands <= fileSize, numberOfCommands * 8 <= sizeOfCommands else {
        throw PatcherError.invalidFormat(
            "\(url.lastPathComponent): truncated Mach-O — the header claims "
                + "\(numberOfCommands) load command(s) in \(sizeOfCommands) bytes, "
                + "and the file is \(fileSize) bytes",
        )
    }
}

// MARK: - patch-seputil

struct VPhoneCFWPatchSeputilCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-seputil",
        abstract: "Pin seputil's gigalocker path to /AA.gl instead of the device UUID",
        discussion: """
        seputil builds the gigalocker filename from the format string
        "/%s.gl", filling %s with the device's UUID. Rewriting those two bytes
        to "AA" makes the path /mnt7/AA.gl on every guest, which is what lets
        the install ship one pre-made .gl file instead of one per device.

        The literal is found in __TEXT,__cstring and confirmed by an adrp+add
        pair in __TEXT,__text that computes its address — the Python takes the
        first substring hit anywhere in the file. Both land on the same byte in
        this firmware; this one cannot land on a coincidence in the next.

        Idempotent: a binary already reading "/AA.gl" is reported and left
        alone. The Python exits 1 there, because the string it searches for is
        no longer in the file.
        """,
    )

    @Argument(help: "Path to the seputil Mach-O, patched in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    func run() throws {
        try requireUntruncatedMachO(at: binary)
        // reattest: false — the Python leaves the signature stale and
        // `cfw_install*.sh` re-signs on the next line. Parity in bytes.
        try CFWSeputil.patch(fileAt: binary, reattest: false, log: machOVerbLog)
    }
}

// MARK: - patch-launchd-cache-loader

struct VPhoneCFWPatchLaunchdCacheLoaderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-launchd-cache-loader",
        abstract: "Open the launchd_unsecure_cache gate so a modified launchd.plist loads",
        discussion: """
        /usr/libexec/launchd_cache_loader refuses a launch-daemon cache it did
        not validate unless the boot arg `launchd_unsecure_cache=` is set.
        NOPping the branch that reads that boot arg takes the guest down the
        unsecure path unconditionally, which is how the injected daemons get
        loaded without a boot-args change.

        The branch is reached from the boot-arg string's adrp+add xref, and it
        is checked to actually consume the call's result and jump forward out
        of the unsecure path before anything is written. The Python NOPs the
        first conditional branch after the call, whatever it tests.

        Idempotent: a gate already holding a NOP is reported and left alone.
        The Python exits 1 there — a NOP is not one of the branches it looks
        for.
        """,
    )

    @Argument(help: "Path to the launchd_cache_loader Mach-O, patched in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    func run() throws {
        try requireUntruncatedMachO(at: binary)
        // Off by default in the library and off in the Python: the caller
        // re-signs. Spelled out so the parity choice is readable here.
        try CFWCacheLoaderPatcher.patch(
            fileAt: binary,
            reattestsCodeSignature: false,
            log: machOVerbLog,
        )
    }
}

// MARK: - patch-mobileactivationd

struct VPhoneCFWPatchMobileactivationdCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-mobileactivationd",
        abstract: "Force -[DeviceType should_hactivate] to return YES",
        discussion: """
        The guest has no path to Apple's activation service, so activation has
        to be answered locally. Overwriting the getter's prologue with
        `mov x0, #1 ; ret` is safe: it returns to the caller's unsigned LR
        without ever pushing a frame.

        The implementation is resolved twice — through LC_SYMTAB and through
        the ObjC metadata chain (selector -> selref -> method list -> IMP) —
        and when both resolve they must agree. The Python takes whichever
        answers first.

        Idempotent: a getter already reading `mov x0, #1 ; ret` is reported and
        the file is not rewritten, so even its mtime survives.
        """,
    )

    @Argument(help: "Path to the mobileactivationd Mach-O, patched in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    func run() throws {
        try requireUntruncatedMachO(at: binary)
        // resign: false — the Python's bytes, for the `ldid_sign` that follows.
        try CFWMobileactivationd.patch(fileAt: binary, resign: false, log: machOVerbLog)
    }
}

// MARK: - patch-launchd-jetsam

struct VPhoneCFWPatchLaunchdJetsamCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-launchd-jetsam",
        abstract: "Bypass the jetsam panic guard in /sbin/launchd",
        discussion: """
        launchd panics when its jetsam configuration does not add up, which a
        JB guest's rearranged daemon set reliably triggers. The conditional
        branch that guards the panic is rewritten to an unconditional `b` to
        the same target, so the function always takes its return path.

        The site is reached from the panic string's adrp+add xref, walking back
        to the conditional branch whose target is the enclosing function's
        return block.

        Idempotent: an unconditional branch into the return block already
        sitting ahead of every conditional one means a previous run did the
        work, and nothing is written. Neither implementation would otherwise
        pick the same site twice.
        """,
    )

    @Argument(help: "Path to the /sbin/launchd Mach-O, patched in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    func run() throws {
        try requireUntruncatedMachO(at: binary)
        // Off in the library and off in the Python: cfw_install_{dev,jb,exp}.sh
        // and cfw-kit/jb/install.sh all run ldid over the result.
        try CFWJetsamPatcher.patch(fileAt: binary, reattest: false, log: machOVerbLog)
    }
}

// MARK: - patch-watchdogd

struct VPhoneCFWPatchWatchdogdCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-watchdogd",
        abstract: "Stop watchdogd caching kern.hv_vmm_present as true",
        discussion: """
        watchdogd reads `kern.hv_vmm_present` through sysctlbyname and caches
        the answer in a __DATA global. On the EXP variant the kernel already
        lies about that sysctl, but watchdogd's cached copy is written from the
        call's success path, so the NOP here plus a forced `mov wN, #1` leaves
        the cache reading "not a VM" whatever the call returns.

        Each site is confirmed five ways — the literal, its adrp+add, the
        `bl _sysctlbyname`, Capstone's decoded condition code on the gate, and
        a `strb` into a __DATA-segment global — before a byte moves.

        Exits 0 whether it patched or found every site already patched, which
        is what `scripts/patch_hv_vmm_userland.sh` expects; only an
        unparseable binary or a missing anchor is fatal. Unlike the other five
        verbs this one re-attests the pages it dirties, because its Python does
        too.
        """,
    )

    @Argument(help: "Path to the watchdogd Mach-O, patched in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    @Flag(name: .customLong("dry-run"), help: "Report the sites found and exit without writing")
    var dryRun = false

    func run() throws {
        try requireUntruncatedMachO(at: binary)
        try CFWWatchdogd.patch(at: binary, dryRun: dryRun, log: machOVerbLog)
    }
}

// MARK: - patch-diskimagesiod

struct VPhoneCFWPatchDiskimagesiodCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-diskimagesiod",
        abstract: "Force -[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:] to return YES",
        discussion: """
        MobileStorageMounter waits for a disk-arbitration mount count the guest
        never reaches, and blocks boot until it times out. Returning YES from
        the completion check lets the mount finish.

        The same two-anchor resolution as patch-mobileactivationd: LC_SYMTAB
        first, then the ObjC metadata chain, with the prologue overwritten by
        `mov x0, #1 ; ret`.

        Idempotent: a prologue already reading `mov x0, #1 ; ret` is reported
        and the file is left byte-for-byte alone.
        """,
    )

    @Argument(help: "Path to the diskimagesiod Mach-O, patched in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    func run() throws {
        try requireUntruncatedMachO(at: binary)
        // Off in the library and off in the Python: cfw_install.sh re-signs
        // with the extracted com.apple.diskimagesiod entitlements right after.
        try CFWDiskimagesiod.patch(fileAt: binary, reattest: false, log: machOVerbLog)
    }
}

// MARK: - Registration

enum VPhoneCFWMachOVerbs {
    /// Registered into `vphone-cli cfw` by `VPhoneCFWCommand`.
    ///
    /// Ordered as `cfw.py`'s dispatch table lists them, so `--help` and the
    /// Python's usage block read in the same order.
    static let all: [ParsableCommand.Type] = [
        VPhoneCFWPatchSeputilCommand.self,
        VPhoneCFWPatchLaunchdCacheLoaderCommand.self,
        VPhoneCFWPatchMobileactivationdCommand.self,
        VPhoneCFWPatchLaunchdJetsamCommand.self,
        VPhoneCFWPatchWatchdogdCommand.self,
        VPhoneCFWPatchDiskimagesiodCommand.self,
    ]
}
