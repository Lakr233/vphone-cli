import Darwin // _NSGetExecutablePath
import Foundation

// MARK: - VPhoneResources

public struct VPhoneResources: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    // MARK: - Resolution

    /// The image this process is actually running, as the kernel recorded it.
    ///
    /// Neither obvious alternative works here. `CommandLine.arguments[0]` is a
    /// bare name under a PATH or symlink launch, which `URL(fileURLWithPath:)`
    /// then resolves against the CWD and lands under `$HOME`.
    /// `Bundle.main.executableURL` can describe a bundle's main executable
    /// instead of the tool actually running beside it in `Contents/MacOS`.
    ///
    /// `_NSGetExecutablePath` has neither problem: it is the path the kernel
    /// exec'd, independent of argv and of any plist. Symlinks are resolved so a
    /// a command symlink lands on the real binary inside the .bundle.
    public static func runningExecutable() -> URL {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            return realPath(URL(fileURLWithPath: path))
        }
        // Only reachable if PATH_MAX was somehow too small for our own path.
        if let exe = Bundle.main.executableURL {
            return realPath(exe)
        }
        return realPath(URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    /// `realpath(3)`, deliberately not `URL.resolvingSymlinksInPath()`.
    ///
    /// Foundation's version standardizes as well as resolves, and on macOS that
    /// means dropping a leading `/private`: a binary that really lives at
    /// `/private/tmp/x/vphone-vm` comes back as `/tmp/x/vphone-vm`. Both open
    /// the same file, but only one is the path the kernel records — and an AMFI
    /// allowlist is matched against the kernel's spelling, so the other one
    /// silently allows nothing. `realpath` resolves every component and keeps
    /// `/private`.
    ///
    /// A path that does not resolve (it does not exist yet) is returned as it
    /// came in; the caller is better placed to say what is missing.
    static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// A companion binary shipped beside this one — today only `vphone-vm`.
    ///
    /// The layout is the same in both places we ever run from — `.build/release`
    /// during development and `Contents/MacOS` in the bundle — so resolving a
    /// sibling of the running image covers both without a special case, and
    /// without ever consulting `PATH`. That last part is the point: a `PATH`
    /// lookup is what let the old Python probing pick up whatever happened to
    /// be installed on the machine.
    ///
    /// Existence is deliberately not checked here. The caller reports a missing
    /// companion far better than this function could, because it knows which
    /// operation is failing and why.
    public static func siblingExecutable(_ name: String) -> URL {
        runningExecutable().deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func resolve(executablePath: String? = nil) -> VPhoneResources {
        let exe = executablePath.map { realPath(URL(fileURLWithPath: $0)) }
            ?? runningExecutable()
        let macos = exe.deletingLastPathComponent() // …/Contents/MacOS
        if macos.lastPathComponent == "MacOS",
           macos.deletingLastPathComponent().lastPathComponent == "Contents"
        {
            return VPhoneResources(base: macos.deletingLastPathComponent()
                .appendingPathComponent("Resources")) // …/Contents/Resources
        }
        var dir = macos
        for _ in 0 ..< 6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts").path) {
                return VPhoneResources(base: dir)
            }
            dir = dir.deletingLastPathComponent()
        }
        return VPhoneResources(base: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    // MARK: - Assets

    public var scriptsDir: URL {
        base.appendingPathComponent("scripts")
    }

    public var vphoned: URL {
        let bundled = base.deletingLastPathComponent()
            .appendingPathComponent("MacOS/vphoned.signed")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Dev fallback for a source build outside the bundle.
        return base.appendingPathComponent(".build/vphoned.signed")
    }

    public var gpuCompilerPlugin: URL {
        Self.siblingExecutable("libAppleParavirtCompilerPluginIOGPUFamily.dylib")
    }

    // MARK: - Cache dirs

    /// The per-user data root: `$VPHONE_ROOT` when set, else `~/.vphone`. Both
    /// `VPhoneResources` (ipsws/tools) and `VPhoneLibrary` (VMs) derive
    /// from this so one variable redirects everything vphone-cli creates.
    public static func userDataRoot() -> URL {
        if let root = ProcessInfo.processInfo.environment["VPHONE_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        let home = VPhoneInvokingUser.current?.home ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".vphone")
    }

    public var ipswCacheDir: URL {
        Self.userDataRoot().appendingPathComponent("ipsws")
    }

    public var sealVolumeCacheDir: URL {
        Self.userDataRoot().appendingPathComponent("tools")
    }

    // MARK: - No interpreter

    // There is deliberately nothing here any more.
    //
    // This type used to resolve a python3 — an explicit `VPHONE_PYTHON`, the
    // repo's `.venv`, a managed `~/.vphone/venv` it would provision on first
    // run, and failing all of those a scan of `PATH` for python3.14 down to
    // python3.10 and then `/usr/bin/python3`. The one program that needed it
    // was the pymobiledevice3 restore bridge, and the restore backend is now
    // libirecovery + idevicerestore linked into this binary (`VPhoneRestore`).
    //
    // The whole ladder is gone rather than left unused, because the last rung
    // was the dangerous one: a `PATH` fallback makes a missing environment look
    // like a working one, right up until a restore fails on a stranger's
    // machine. Nothing in this package may resolve an interpreter again — see
    // the "Python" section in AGENTS.md, and `Scripts/check_aux.sh`, which now
    // fails outright on a python3 lookup instead of registering it.

    // With the interpreter went the last `PATH` lookup in this package. Every
    // program vphone-cli runs is either a sibling of the running image
    // (`siblingExecutable`) or a bundled script under `scriptsDir`.
}
