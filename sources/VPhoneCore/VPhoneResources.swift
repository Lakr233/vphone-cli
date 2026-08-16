import Foundation

// MARK: - VPhoneResourcesError

public enum VPhoneResourcesError: Error, Equatable {
    case pythonNotFound(String)
    case venvBootstrapFailed(String)
}

// MARK: - VPhoneResources

public struct VPhoneResources: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    // MARK: - Resolution

    /// The running executable, resolved reliably. `CommandLine.arguments[0]` is
    /// NOT reliable — under a PATH/symlink launch (e.g. a Homebrew symlink) it's
    /// a bare name that `URL(fileURLWithPath:)` resolves against the CWD, so the
    /// binary/base end up under `$HOME`. `Bundle.main.executableURL` is the
    /// kernel-provided executable path, correct regardless of how the process
    /// was invoked; resolve symlinks so a brew symlink lands on the real binary
    /// inside the .app.
    public static func runningExecutable() -> URL {
        if let exe = Bundle.main.executableURL { return exe.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    public static func resolve(executablePath: String? = nil) -> VPhoneResources {
        let exe = executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            ?? runningExecutable()
        let macos = exe.deletingLastPathComponent()             // …/Contents/MacOS
        if macos.lastPathComponent == "MacOS",
           macos.deletingLastPathComponent().lastPathComponent == "Contents" {
            return VPhoneResources(base: macos.deletingLastPathComponent()
                .appendingPathComponent("Resources"))            // …/Contents/Resources
        }
        var dir = macos
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts").path) {
                return VPhoneResources(base: dir)
            }
            dir = dir.deletingLastPathComponent()
        }
        return VPhoneResources(base: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    // MARK: - Assets

    public var scriptsDir: URL { base.appendingPathComponent("scripts") }
    public var patchersDir: URL { scriptsDir.appendingPathComponent("patchers") }
    public var resourceArchivesDir: URL { scriptsDir.appendingPathComponent("resources") }
    public var fwPrepareScript: URL { scriptsDir.appendingPathComponent("fw_prepare.sh") }
    public var cfwInstallHostScript: URL { scriptsDir.appendingPathComponent("cfw_install_host.sh") }
    public var preflightScript: URL { scriptsDir.appendingPathComponent("boot_host_preflight.sh") }
    public var pmd3Bridge: URL { scriptsDir.appendingPathComponent("pymobiledevice3_bridge.py") }
    public var cfwPy: URL { patchersDir.appendingPathComponent("cfw.py") }
    public var apfsSnapRename: URL { base.appendingPathComponent("tools/apfs_snap_rename.py") }
    public var signcert: URL { scriptsDir.appendingPathComponent("vphoned/signcert.p12") }

    public var vphoned: URL {
        let bundled = base.appendingPathComponent("vphoned.signed")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Dev fallback: build.sh stages the signed daemon under .build (a
        // gitignored build-output dir) rather than cluttering the repo root.
        return base.appendingPathComponent(".build/vphoned.signed")
    }

    // MARK: - Cache dirs

    /// The per-user data root: `$VPHONE_ROOT` when set, else `~/.vphone`. Both
    /// `VPhoneResources` (ipsws/tools/debs/venv) and `VPhoneLibrary` (VMs)
    /// derive from this so one variable redirects everything vphone-cli creates.
    public static func userDataRoot() -> URL {
        if let root = ProcessInfo.processInfo.environment["VPHONE_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone")
    }

    public var userCacheDir: URL { Self.userDataRoot() }
    public var ipswCacheDir: URL { userCacheDir.appendingPathComponent("ipsws") }
    public var sealVolumeCacheDir: URL { userCacheDir.appendingPathComponent("tools") }
    public var debsCacheDir: URL { userCacheDir.appendingPathComponent("debs") }
    public var toolsBinDir: URL { base.appendingPathComponent(".tools/bin") }

    // MARK: - Python

    /// Runtime pip deps, mirrored from requirements.txt (fallback when the
    /// bundled requirements.txt is somehow absent).
    static let fallbackRequirements =
        ["typer", "capstone", "keystone-engine", "pyimg4", "pymobiledevice3>=9.5.0", "ipsw-parser"]

    /// Bundled/dev requirements list the managed venv is provisioned from.
    public var requirementsFile: URL { base.appendingPathComponent("requirements.txt") }

    /// Per-user managed venv, created on demand. Deliberately OUTSIDE both the
    /// repo and the .app so the app is portable — a venv is never moved between
    /// machines (its links would break); it is built fresh on each host.
    public var managedVenvDir: URL {
        if let dir = ProcessInfo.processInfo.environment["VPHONE_VENV_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return userCacheDir.appendingPathComponent("venv")
    }
    private var managedVenvPython: URL { managedVenvDir.appendingPathComponent("bin/python3") }

    /// A python is usable only if it carries an `ipsw_parser` new enough for the
    /// bridge — the exact gap behind `IPSW has no attribute 'create_from_path'`
    /// when an old system-python build gets picked up.
    func pythonIsUsable(_ python: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let probe = "from ipsw_parser.ipsw import IPSW; import sys; "
            + "sys.exit(0 if hasattr(IPSW, 'create_from_path') else 1)"
        return (try? VPhoneProcessRunner.runCapturing(python, ["-c", probe]))?.succeeded == true
    }

    /// Must assemble, not just import — a bindings-only install imports fine
    /// and then fails inside `fw patch`.
    func keystoneIsUsable(_ python: URL) -> Bool {
        let probe = "from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN; import sys; "
            + "sys.exit(0 if bytes(Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm('nop')[0]) else 1)"
        return (try? VPhoneProcessRunner.runCapturing(python, ["-c", probe]))?.succeeded == true
    }

    func venvIsUsable(_ python: URL) -> Bool {
        pythonIsUsable(python) && keystoneIsUsable(python)
    }

    // MARK: - keystone native library

    /// Older bottles ship only the static archive.
    private func homebrewKeystoneLibs() -> (dylib: URL?, archive: URL?) {
        for prefix in ["/opt/homebrew/opt/keystone/lib", "/usr/local/opt/keystone/lib"] {
            let dir = URL(fileURLWithPath: prefix)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            let dylib = names.first { $0.hasPrefix("libkeystone") && $0.hasSuffix(".dylib") }
            let archive = names.first { $0 == "libkeystone.a" }
            if dylib != nil || archive != nil {
                return (dylib.map(dir.appendingPathComponent), archive.map(dir.appendingPathComponent))
            }
        }
        return (nil, nil)
    }

    /// Asked of the interpreter: `import keystone` is what's broken here.
    private func keystonePackageDir(_ python: URL) -> URL? {
        let probe = "import sysconfig; print(sysconfig.get_paths()['purelib'])"
        guard let r = try? VPhoneProcessRunner.runCapturing(python, ["-c", probe]), r.succeeded else { return nil }
        let purelib = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purelib.isEmpty else { return nil }
        return URL(fileURLWithPath: purelib).appendingPathComponent("keystone")
    }

    /// PyPI has no arm64 macOS wheel and the sdist ignores its build's exit
    /// status, so a failed native build still installs bindings alone and pip
    /// reports success. Same recovery as scripts/setup_venv.sh.
    func repairKeystone(_ python: URL) -> Bool {
        guard let pkgDir = keystonePackageDir(python),
              FileManager.default.fileExists(atPath: pkgDir.path) else { return false }
        let dest = pkgDir.appendingPathComponent("libkeystone.dylib")
        let libs = homebrewKeystoneLibs()

        if let dylib = libs.dylib {
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: dylib, to: dest)) != nil else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } else if let archive = libs.archive {
            let r = try? VPhoneProcessRunner.runCapturing(
                URL(fileURLWithPath: "/usr/bin/clang"),
                ["-shared", "-o", dest.path, "-Wl,-all_load", archive.path,
                 "-lc++", "-install_name", "@rpath/libkeystone.dylib"])
            guard r?.succeeded == true else { return false }
        } else {
            return false
        }

        guard keystoneIsUsable(python) else { return false }
        FileHandle.standardError.write(Data("[+] Repaired keystone native library: \(dest.path)\n".utf8))
        return true
    }

    /// Resolve a python with working deps: an explicit `VPHONE_PYTHON`, the dev
    /// repo `.venv`, the managed per-user venv, else provision the managed venv
    /// on this machine. Never silently falls back to a stale system python.
    public func pythonExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["VPHONE_PYTHON"], !override.isEmpty {
            let u = URL(fileURLWithPath: override)
            if pythonIsUsable(u) { return u }
        }
        let devVenv = base.appendingPathComponent(".venv/bin/python3")
        if venvIsUsable(devVenv) { return devVenv }
        // Repair in place before rebuilding — a missing dylib is not worth a
        // full re-install.
        if pythonIsUsable(managedVenvPython),
           keystoneIsUsable(managedVenvPython) || repairKeystone(managedVenvPython) {
            return managedVenvPython
        }
        return try bootstrapManagedVenv()
    }

    /// Provision `~/.vphone/venv`: try each candidate host python for real
    /// (build the venv, install deps, verify) and use the first that fully
    /// succeeds — a candidate that imports `venv` can still fail `-m venv`
    /// (e.g. a broken `ensurepip`), so we fall through instead of trusting it.
    /// One-time per machine.
    private func bootstrapManagedVenv() throws -> URL {
        func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let candidates = candidateHostPythons()
        guard !candidates.isEmpty else {
            throw VPhoneResourcesError.venvBootstrapFailed(
                "no host python3 found — install one (e.g. `brew install python@3.13`) or set VPHONE_PYTHON")
        }
        log("[*] First run: provisioning the vphone Python environment at \(managedVenvDir.path) (one-time)…")
        let py = managedVenvPython
        let install: [String] = FileManager.default.fileExists(atPath: requirementsFile.path)
            ? ["-m", "pip", "install", "-r", requirementsFile.path]
            : ["-m", "pip", "install"] + Self.fallbackRequirements
        var lastError = "no candidate python could build a usable venv"

        for host in candidates {
            log("    → trying \(host.path) …")
            try? FileManager.default.removeItem(at: managedVenvDir)
            try FileManager.default.createDirectory(at: userCacheDir, withIntermediateDirectories: true)
            guard (try? VPhoneProcessRunner.runStreaming(host, ["-m", "venv", managedVenvDir.path])) == 0 else {
                lastError = "python -m venv failed with \(host.path)"; continue
            }
            _ = try? VPhoneProcessRunner.runStreaming(py, ["-m", "pip", "install", "--upgrade", "-q", "pip"])
            guard (try? VPhoneProcessRunner.runStreaming(py, install)) == 0 else {
                lastError = "pip install failed with \(host.path)"; continue
            }
            guard pythonIsUsable(py) else {
                lastError = "venv from \(host.path) still lacks a usable ipsw_parser (too old?)"; continue
            }
            guard keystoneIsUsable(py) || repairKeystone(py) else {
                lastError = "venv from \(host.path) has no working libkeystone — "
                    + "`brew install keystone`, or install cmake so pip can build it"
                continue
            }
            log("[+] Python environment ready: \(py.path)")
            return py
        }
        try? FileManager.default.removeItem(at: managedVenvDir)
        throw VPhoneResourcesError.venvBootstrapFailed(
            lastError + " — install a modern python3 (e.g. `brew install python@3.13`) or set VPHONE_PYTHON")
    }

    /// Ordered, existence-checked host python3 candidates to bootstrap from.
    /// Canonical Homebrew locations first, then versioned names on PATH, then
    /// generic `python3`, then system `/usr/bin/python3` (3.9) as a last resort
    /// (it resolves an old, broken pymobiledevice3 stack).
    private func candidateHostPythons() -> [URL] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["VPHONE_PYTHON"], !override.isEmpty {
            paths.append(override)
        }
        paths += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for name in ["python3.14", "python3.13", "python3.12", "python3.11", "python3.10"] {
            if let p = which(name) { paths.append(p) }
        }
        if let p = which("python3") { paths.append(p) }
        paths.append("/usr/bin/python3")

        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func which(_ name: String) -> String? {
        let r = try? VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/env"), ["which", name])
        guard let r, r.succeeded else { return nil }
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : p
    }
}
