import Darwin  // _NSGetExecutablePath
import Foundation

// MARK: - VPhoneResourcesError

public enum VPhoneResourcesError: Error, Equatable {
    case venvBootstrapFailed(String)
}

// MARK: - VPhoneResources

public struct VPhoneResources: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    // MARK: - Resolution

    /// The image this process is actually running, as the kernel recorded it.
    ///
    /// Neither obvious alternative works here. `CommandLine.arguments[0]` is a
    /// bare name under a PATH or symlink launch, which `URL(fileURLWithPath:)`
    /// then resolves against the CWD and lands under `$HOME`.
    /// `Bundle.main.executableURL` reads `CFBundleExecutable` out of Info.plist
    /// — and now that the bundle declares `vphone-vm`, it answers "vphone-vm"
    /// even when the running binary is `vphone-cli` sitting right beside it in
    /// the same `Contents/MacOS`. It cannot be used to find ourselves.
    ///
    /// `_NSGetExecutablePath` has neither problem: it is the path the kernel
    /// exec'd, independent of argv and of any plist. Symlinks are resolved so a
    /// Homebrew symlink lands on the real binary inside the .app.
    public static func runningExecutable() -> URL {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        // Only reachable if PATH_MAX was somehow too small for our own path.
        if let exe = Bundle.main.executableURL { return exe.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    /// A companion binary shipped beside this one: `vphone-vm`, `vphone-letmein`.
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
    public var resourceArchivesDir: URL { scriptsDir.appendingPathComponent("resources") }
    public var fwPrepareScript: URL { scriptsDir.appendingPathComponent("fw_prepare.sh") }
    public var cfwInstallHostScript: URL { scriptsDir.appendingPathComponent("cfw_install_host.sh") }
    public var preflightScript: URL { scriptsDir.appendingPathComponent("boot_host_preflight.sh") }
    public var pmd3Bridge: URL { scriptsDir.appendingPathComponent("pymobiledevice3_bridge.py") }
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

    public var ipswCacheDir: URL { Self.userDataRoot().appendingPathComponent("ipsws") }
    public var sealVolumeCacheDir: URL { Self.userDataRoot().appendingPathComponent("tools") }
    public var debsCacheDir: URL { Self.userDataRoot().appendingPathComponent("debs") }

    // MARK: - Python

    /// Runtime pip deps, mirrored from requirements.txt (fallback when the
    /// bundled requirements.txt is somehow absent).
    ///
    /// One consumer is left: `scripts/pymobiledevice3_bridge.py`, the restore
    /// path. The firmware patchers that needed capstone, keystone-engine and
    /// pyimg4 are Swift now (`FirmwarePatcher`), so those three are gone. pyimg4
    /// still ends up installed — `pymobiledevice3` and `ipsw-parser` both
    /// require it — but nothing here asks for it directly any more.
    static let fallbackRequirements =
        ["typer", "pymobiledevice3>=9.5.0", "ipsw-parser", "setuptools"]

    /// Bundled/dev requirements list the managed venv is provisioned from.
    public var requirementsFile: URL { base.appendingPathComponent("requirements.txt") }

    /// Per-user managed venv, created on demand. Deliberately OUTSIDE both the
    /// repo and the .app so the app is portable — a venv is never moved between
    /// machines (its links would break); it is built fresh on each host.
    public var managedVenvDir: URL {
        if let dir = ProcessInfo.processInfo.environment["VPHONE_VENV_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return Self.userDataRoot().appendingPathComponent("venv")
    }
    private var managedVenvPython: URL { managedVenvDir.appendingPathComponent("bin/python3") }

    /// A python is usable only if it can actually run the restore bridge.
    ///
    /// Two halves, and both are needed. `ipsw_parser` must be new enough —
    /// that is the gap behind `IPSW has no attribute 'create_from_path'` when
    /// an old system-python build gets picked up. And `pymobiledevice3` must be
    /// importable, which `ipsw_parser` does **not** imply: `pip show
    /// ipsw-parser` lists coloredlogs, construct, plumbum, pyimg4, remotezip2,
    /// requests and typer, and no pymobiledevice3. A venv holding only
    /// `ipsw-parser` passes an `ipsw_parser`-only probe and then dies on
    /// `ModuleNotFoundError: No module named 'pymobiledevice3'` at the bridge's
    /// line 11 — an import traceback instead of "this environment is wrong".
    func pythonIsUsable(_ python: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let probe = "from ipsw_parser.ipsw import IPSW; import pymobiledevice3; import sys; "
            + "sys.exit(0 if hasattr(IPSW, 'create_from_path') else 1)"
        return (try? VPhoneProcessRunner.runCapturing(python, ["-c", probe]))?.succeeded == true
    }

    /// Resolve a python with working deps: an explicit `VPHONE_PYTHON`, the dev
    /// repo `.venv`, the managed per-user venv, else provision the managed venv
    /// on this machine. Never silently falls back to a stale system python.
    ///
    /// `pythonIsUsable` is the whole health check now. It used to be paired
    /// with a keystone probe and an in-place repair of keystone's native
    /// library, because a `fw patch` ran Python patchers; those are Swift
    /// (`FirmwarePatcher`), and the only thing left needing an interpreter is
    /// the pymobiledevice3 restore bridge — which is exactly what the probe
    /// covers.
    public func pythonExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["VPHONE_PYTHON"], !override.isEmpty {
            let u = URL(fileURLWithPath: override)
            if pythonIsUsable(u) { return u }
        }
        let devVenv = base.appendingPathComponent(".venv/bin/python3")
        if pythonIsUsable(devVenv) { return devVenv }
        if pythonIsUsable(managedVenvPython) { return managedVenvPython }
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
                "No python3 found on this system. Install it with 'brew install python@3.13', or set VPHONE_PYTHON.")
        }
        log("[*] First run: setting up the Python environment at \(managedVenvDir.path)…")
        let py = managedVenvPython
        let install: [String] = FileManager.default.fileExists(atPath: requirementsFile.path)
            ? ["-m", "pip", "install", "-r", requirementsFile.path]
            : ["-m", "pip", "install"] + Self.fallbackRequirements
        var lastError = "No usable Python could be found on this system"

        for host in candidates {
            log("    → Trying \(host.path)…")
            try? FileManager.default.removeItem(at: managedVenvDir)
            try FileManager.default.createDirectory(
                at: Self.userDataRoot(),
                withIntermediateDirectories: true)
            guard (try? VPhoneProcessRunner.runStreaming(host, ["-m", "venv", managedVenvDir.path])) == 0 else {
                lastError = "Could not create a Python environment with \(host.path)"; continue
            }
            _ = try? VPhoneProcessRunner.runStreaming(py, ["-m", "pip", "install", "--upgrade", "-q", "pip"])
            guard (try? VPhoneProcessRunner.runStreaming(py, install)) == 0 else {
                lastError = "Could not install the required Python packages with \(host.path)"; continue
            }
            guard pythonIsUsable(py) else {
                lastError = "The Python environment built with \(host.path) is missing a required package"; continue
            }
            log("[+] Python environment ready: \(py.path)")
            return py
        }
        try? FileManager.default.removeItem(at: managedVenvDir)
        throw VPhoneResourcesError.venvBootstrapFailed(
            lastError + ". If the problem persists, install a modern python3 with "
                + "'brew install python@3.13', or set VPHONE_PYTHON.")
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
