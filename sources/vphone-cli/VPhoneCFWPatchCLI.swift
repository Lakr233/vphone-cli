// VPhoneCFWPatchCLI.swift — the `cfw` subcommands that replace the Python patchers.
//
// Each one is a thin face over a type in `FirmwarePatcher/CFW/`. The Python they
// replace (`scripts/patchers/cfw.py` and friends) was removed once the
// installers switched to these verbs — `git show 78cbeea:scripts/patchers` to
// read it. The bar every command here had to clear is that its stdout is the
// Python's stdout — `cfw_install.sh:207-208` reads
// `cryptex-paths` with `head -1`/`tail -1`, and a human reads the rest out of an
// install log. Where the library already prints (build-version, campo,
// post-restore-dt), the command passes `verbose: true` and prints nothing of its
// own rather than inventing a second voice.

import ArgumentParser
import FirmwarePatcher
import Foundation

// MARK: - cryptex-paths

struct VPhoneCFWCryptexPathsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cryptex-paths",
        abstract: "Print the SystemOS and AppOS Cryptex DMG paths from a BuildManifest",
        discussion: """
        Two lines, SystemOS first then AppOS, relative to the IPSW root. The
        installer reads them with `head -1` and `tail -1`, so nothing else may
        be printed on success.

        Every BuildIdentity is searched, not just the first: a vResearch IPSW
        carries its Cryptex entries in a later identity, and the last identity
        in a real manifest has none at all. The first identity carrying both
        wins. When no identity carries both, this exits non-zero rather than
        printing a blank line the caller would read as a path.
        """
    )

    @Argument(help: "Path to BuildManifest.plist", transform: URL.init(fileURLWithPath:))
    var buildManifest: URL

    func run() throws {
        let paths = try CFWDaemons.cryptexPaths(buildManifest: buildManifest)
        print(paths.systemOS)
        print(paths.appOS)
    }
}

// MARK: - inject-daemons

struct VPhoneCFWInjectDaemonsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inject-daemons",
        abstract: "Merge the staged LaunchDaemons into a launchd.plist",
        discussion: """
        Looks for bash, dropbear, trollvnc, vphoned and rpcserver_ios in the
        staging directory — a fixed list, in that order, so what gets injected
        does not depend on what else a variant leaves lying around — and writes
        each one into the target's `LaunchDaemons` dictionary under
        `/System/Library/LaunchDaemons/<name>.plist`.

        A daemon that is not staged is skipped, not an error: a variant that
        does not ship rpcserver_ios still installs. An entry already present is
        replaced, which is what makes re-running an install over an
        already-patched volume safe.

        dropbear's ProgramArguments are rewritten on the way through to point at
        the /var/dropbear host keys — see `patch-dropbear-plist`.
        """
    )

    @Argument(help: "Path to the guest's /System/Library/xpc/launchd.plist", transform: URL.init(fileURLWithPath:))
    var launchdPlist: URL

    @Argument(help: "Directory holding the staged <name>.plist daemons", transform: URL.init(fileURLWithPath:))
    var daemonDirectory: URL

    func run() throws {
        for entry in try CFWDaemons.injectDaemons(into: launchdPlist, fromDirectory: daemonDirectory) {
            switch entry {
            case let .present(daemon): print("  [+] Injected \(daemon.name)")
            case let .absent(source): print("  [!] Missing \(source), skipping")
            }
        }
    }
}

// MARK: - inject-daemon

struct VPhoneCFWInjectDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inject-daemon",
        abstract: "Merge one LaunchDaemon plist into a launchd.plist under a given label",
        discussion: """
        The single-file form of `inject-daemons`, replacing the inline plistlib
        snippet that `cfw_install_jb.sh` and `cfw_install_exp.sh` each carry a
        copy of.

        --name is the label the daemon installs under, which is not the source
        file's name: the JB setup daemon ships as `vphone_jb_setup.plist` and
        installs as `com.vphone.jb-setup.plist`. It is the key launchd looks the
        daemon up by, so it has to match the file written into
        /System/Library/LaunchDaemons.
        """
    )

    @Argument(help: "Path to the guest's /System/Library/xpc/launchd.plist", transform: URL.init(fileURLWithPath:))
    var launchdPlist: URL

    @Argument(help: "The daemon plist to merge in", transform: URL.init(fileURLWithPath:))
    var source: URL

    @Option(name: .customLong("name"), help: "Label to install under, without .plist (e.g. com.vphone.jb-setup)")
    var name: String

    func run() throws {
        try CFWDaemons.injectDaemon(into: launchdPlist, name: name, from: source)
    }
}

// MARK: - patch-dropbear-plist

struct VPhoneCFWPatchDropbearPlistCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-dropbear-plist",
        abstract: "Point dropbear at the /var/dropbear host keys instead of generating its own",
        discussion: """
        Drops `-R` (generate defaults under /etc/dropbear, which is on the
        read-only root during a normal VM boot) and every `-r <path>` pair, so a
        stale explicit key path cannot survive, then appends the two keys
        cfw_install seeds on the writable Data volume.

        An empty or missing ProgramArguments list is left alone: there is
        nothing there to point at a key.
        """
    )

    @Argument(help: "Path to dropbear.plist", transform: URL.init(fileURLWithPath:))
    var plist: URL

    func run() throws {
        try CFWDaemons.patchDropbearPlist(at: plist)
    }
}

// MARK: - inject-dylib

struct VPhoneCFWInjectDylibCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inject-dylib",
        abstract: "Insert a weak LC_LOAD_DYLIB into every slice of a Mach-O",
        discussion: """
        Replaces `insert_dylib --weak --inplace --all-yes`, which is how the JB
        and EXP installers get launchd to load /b (the short launchdhook alias)
        at boot.

        The load is weak, so a guest that reaches launchd without the dylib in
        place boots instead of panicking, and the existing LC_CODE_SIGNATURE and
        its blob are removed — exactly what insert_dylib does by default. The
        binary is not left unsigned: the install re-signs it on the next line.
        """
    )

    @Argument(help: "The Mach-O to patch, in place", transform: URL.init(fileURLWithPath:))
    var binary: URL

    @Argument(help: "Path the guest will load the dylib from (e.g. /b)")
    var dylibPath: String

    func run() throws {
        let injections = try CFWInjectDylib.inject(dylibPath: dylibPath, into: binary, weak: true, policy: .strip)
        for injection in injections {
            let stripped = injection.removedCodeSignature ? ", signature stripped" : ""
            print("  [+] LC_LOAD_WEAK_DYLIB \(dylibPath) -> \(binary.lastPathComponent) "
                + "(slice +0x\(String(injection.sliceOffset, radix: 16))\(stripped))")
        }
    }
}

// MARK: - patch-build-version

struct VPhoneCFWPatchBuildVersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-build-version",
        abstract: "Rewrite ProductBuildVersion in a SystemVersion.plist",
        discussion: """
        Settings → General → About shows this string as "Build Version", and
        most of userland — libMobileGestalt, CoreFoundation's
        _CFCopyServerVersionDictionary, App Store telemetry — reads it from
        SystemVersion.plist rather than from the kernel. The EXP install
        rewrites both copies: the one on the system volume and the one under
        /private/preboot/Cryptexes/OS.

        It does not touch `sysctl kern.osversion` (a kernel global set from boot
        args), ProductVersion (the marketing version, deliberately left alone)
        or any DSC constant. The file's format is preserved: XML in, XML out.

        Idempotent — a re-run on an already-patched plist reports and exits
        without rewriting.
        """
    )

    @Argument(help: "Path to SystemVersion.plist", transform: URL.init(fileURLWithPath:))
    var plist: URL

    @Argument(help: "The build identifier to write (e.g. 23B85)")
    var buildID: String

    @Flag(name: .customLong("dry-run"), help: "Report what would change and exit")
    var dryRun = false

    func run() throws {
        try CFWBuildVersion.patch(at: plist, to: buildID, dryRun: dryRun, verbose: true)
    }
}

// MARK: - patch-campo-entitlements

struct VPhoneCFWPatchCampoEntitlementsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-campo-entitlements",
        abstract: "Merge the backboard/frontboard mach-lookup exceptions Campo needs",
        discussion: """
        iOS 27's temporary sandbox denies Campo.app the services it needs to put
        a window on screen. The install dumps Campo's entitlements, runs this to
        merge the missing global-name lookups into the mach-lookup exception
        array, and re-signs with the merged plist.

        The merge is append-only and order-preserving: an entry already present
        keeps its position, and anything the binary carried that is not in this
        list survives. That matters because the result goes straight back to the
        signer, and dropping an entitlement Campo already had would be a silent
        downgrade.

        The file is written back as XML, which is what the signer expects.
        """
    )

    @Argument(help: "Path to the dumped entitlements plist", transform: URL.init(fileURLWithPath:))
    var plist: URL

    func run() throws {
        try CFWMachLookupExceptions.merge(at: plist, verbose: true)
    }
}

// MARK: - patch-post-restore-dt

struct VPhoneCFWPatchPostRestoreDTCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch-post-restore-dt",
        abstract: "Rewrite the restore-fatal identity properties in a device tree",
        discussion: """
        Rewrites the three identity properties that make the guest look like a
        real iPhone17,3 to the services that ask, in place, preserving the
        container's compression, manifest and restore info.

        Every rewrite lands in the property's existing slot, so the blob's size
        cannot change; if it did, the parser and the serializer would have
        drifted apart and the IM4P's recorded uncompressed size would no longer
        match its payload. That is checked, and it refuses rather than writing a
        device tree the guest will not load.

        Takes a devicetree.img4 (preferred) or a bare .im4p. An encrypted
        payload is refused, not guessed at.
        """
    )

    @Argument(help: "Path to devicetree.img4 or devicetree.im4p", transform: URL.init(fileURLWithPath:))
    var deviceTree: URL

    @Flag(name: .customLong("dry-run"), help: "Report what would change and exit")
    var dryRun = false

    func run() throws {
        try CFWPostRestoreDeviceTree.patch(at: deviceTree, dryRun: dryRun, verbose: true)
    }
}
