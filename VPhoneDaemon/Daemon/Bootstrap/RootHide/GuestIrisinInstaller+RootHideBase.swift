import Darwin
import Foundation
import VphonedNative

// MARK: - RootHide bootstrap base

extension GuestIrisinInstaller {
    /// A jailbreak's bootstrap installer creates what no package owns: vroot
    /// `/tmp` and `/dev`, the account files and the databases user lookup
    /// reads, root's home and the SSH host keys. Irisin only unpacks packages,
    /// so vphoned is that installer. Paths are physical; `root/x` is `/x`
    /// under vroot. A missing item is created and an existing one is left
    /// alone, so a changed password, key or mode survives. The one exception
    /// is the login shell: `ensureInteractiveShells` rewrites entries still on
    /// the seeded `/bin/sh`, because the seed copies the system's accounts
    /// before the bootstrap's zsh exists. A step that needs a bootstrap tool
    /// waits for a later refresh until Irisin's Bootstrap Install has unpacked
    /// the tool.
    static func ensureRootHideBase(root: String) throws -> [String: Any] {
        guard try directoryExistsWithoutSymlink(root) else {
            throw GuestAPIError.operationFailed("RootHide bootstrap root is missing: \(root)")
        }
        var created: [String] = []
        var deferred: [String] = []

        // Everything under vroot resolves /tmp and /var/tmp here. Without it
        // iGhostVT never starts: libghostty only logs the failed config write.
        for (path, mode) in [("tmp", 0o1777), ("var", 0o755), ("var/root", 0o700), ("etc", 0o755)] {
            if try ensureBaseDirectory(root + "/" + path, mode: mode_t(mode)) {
                created.append("/" + path)
            }
        }
        // The kernel resolves link text, not vroot paths: vroot shows /rootfs/x,
        // but the text must be /x. Earlier vphoned wrote dev -> /rootfs/dev,
        // which dangles, so every shell failed on /dev/null and sshd never
        // started. rootfs is the vroot bridge to the real root.
        let dev = root + "/dev"
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: dev)) == "/rootfs/dev" {
            try FileManager.default.removeItem(atPath: dev)
        }
        for (path, target) in [("var/tmp", "../tmp"), ("dev", "/dev"), ("rootfs", "/")] {
            if try ensureBaseLink(root + "/" + path, target: target) {
                created.append("/" + path)
            }
        }
        for (name, mode) in [("passwd", 0o644), ("group", 0o644), ("master.passwd", 0o600)] {
            if try seedAccountFile(name, root: root, mode: mode_t(mode)) {
                created.append("/etc/" + name)
            }
        }
        // Before the databases, so their freshness check rebuilds from the
        // rewritten master.passwd rather than a stale one.
        let shells = try ensureInteractiveShells(root: root)
        if !shells.isEmpty {
            created.append("/etc/master.passwd login shell: " + shells.joined(separator: ", "))
        }

        switch try ensureAccountDatabases(root: root) {
        case true?:
            created += ["/etc/pwd.db", "/etc/spwd.db"]
        case false?:
            break
        case nil:
            deferred.append("/etc/pwd.db and /etc/spwd.db wait for /usr/sbin/pwd_mkdb")
            return ["created": created, "deferred": deferred]
        }
        // ssh-keygen needs getpwuid(0), so host keys follow the databases.
        switch try ensureHostKeys(root: root) {
        case true?:
            created.append("/etc/ssh host keys")
        case false?:
            break
        case nil:
            deferred.append("/etc/ssh host keys wait for /usr/bin/ssh-keygen")
        }
        return ["created": created, "deferred": deferred]
    }

    /// Creates a root-owned directory with exactly `mode`, since mkdir applies
    /// the umask. An existing directory keeps its owner and mode.
    private static func ensureBaseDirectory(_ path: String, mode: mode_t) throws -> Bool {
        if mkdir(path, mode) == 0 {
            guard chown(path, 0, 0) == 0, chmod(path, mode) == 0 else {
                throw GuestAPIError.operationFailed(
                    "Could not set the owner and mode of \(path): \(String(cString: strerror(errno)))",
                )
            }
            return true
        }
        let reason = String(cString: strerror(errno))
        guard errno == EEXIST else {
            throw GuestAPIError.operationFailed("Could not create \(path): \(reason)")
        }
        guard isDirectory(path) else {
            throw GuestAPIError.operationFailed("RootHide bootstrap path is not a directory: \(path)")
        }
        return false
    }

    /// Unlike a loader link, an existing entry here is not checked: whatever
    /// the user or a package put at the path stays.
    private static func ensureBaseLink(_ path: String, target: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw GuestAPIError.operationFailed("Could not inspect \(path): \(String(cString: strerror(errno)))")
        }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        return true
    }

    /// The bootstrap's account files start as copies of the system's. The
    /// copy is created with its final mode, so master.passwd, the shadow file,
    /// is never readable by others.
    private static func seedAccountFile(_ name: String, root: String, mode: mode_t) throws -> Bool {
        let destination = root + "/etc/" + name
        var info = stat()
        if lstat(destination, &info) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw GuestAPIError.operationFailed("Could not inspect \(destination): \(String(cString: strerror(errno)))")
        }
        let source = "/private/etc/" + name
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            throw GuestAPIError.operationFailed("Could not open \(source): \(String(cString: strerror(errno)))")
        }
        defer { close(input) }
        let data = try FileHandle(fileDescriptor: input, closeOnDealloc: false).readToEnd() ?? Data()

        let temporary = destination + ".vphoned-" + UUID().uuidString
        let output = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else {
            throw GuestAPIError.operationFailed("Could not create \(temporary): \(String(cString: strerror(errno)))")
        }
        let written = data.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
        let prepared = written == data.count && fchown(output, 0, 0) == 0 && fchmod(output, mode) == 0
        let failure = errno
        close(output)
        guard prepared, rename(temporary, destination) == 0 else {
            let reason = String(cString: strerror(prepared ? errno : failure))
            unlink(temporary)
            throw GuestAPIError.operationFailed("Could not write \(destination): \(reason)")
        }
        return true
    }

    /// Points the seeded accounts at the bootstrap's shell, and returns the
    /// names it changed. The rule itself is ``GuestLoginShellRule``.
    ///
    /// Waits for the shell the way the other steps wait for their tool: with
    /// nothing to run yet this does nothing, and the refresh that follows
    /// Irisin's Bootstrap Install applies it.
    static func ensureInteractiveShells(root: String) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: root + GuestLoginShellRule.bootstrapShell) else {
            return []
        }
        let path = root + "/etc/master.passwd"
        guard let text = String(data: try Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8) else {
            throw GuestAPIError.operationFailed("Could not read \(path) as UTF-8")
        }
        let (rewritten, changed) = GuestLoginShellRule.rewritingLoginShells(text)
        guard !changed.isEmpty else { return [] }

        // master.passwd is the shadow file: create the replacement 0600 and
        // owned by root before it takes the name, as seedAccountFile does.
        let temporary = path + ".vphoned-" + UUID().uuidString
        let output = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else {
            throw GuestAPIError.operationFailed("Could not create \(temporary): \(String(cString: strerror(errno)))")
        }
        let data = Data(rewritten.utf8)
        let written = data.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
        let prepared = written == data.count && fchown(output, 0, 0) == 0 && fchmod(output, 0o600) == 0
        let failure = errno
        close(output)
        guard prepared, rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(prepared ? errno : failure))
            unlink(temporary)
            throw GuestAPIError.operationFailed("Could not write \(path): \(reason)")
        }
        return changed
    }

    /// Procursus tools look users up through libiosexec, which reads the
    /// Berkeley databases rather than the text files. Without them every
    /// getpwnam and getpwuid under vroot fails with EINVAL while group lookups
    /// work. They are rebuilt only when missing or older than master.passwd,
    /// so a password changed with passwd survives a refresh. Returns nil while
    /// the bootstrap has no pwd_mkdb.
    private static func ensureAccountDatabases(root: String) throws -> Bool? {
        let etc = root + "/etc/"
        guard let master = try modificationTime(etc + "master.passwd") else {
            throw GuestAPIError.operationFailed("RootHide account file is missing: \(etc)master.passwd")
        }
        if let database = try modificationTime(etc + "pwd.db"), database >= master,
           let shadow = try modificationTime(etc + "spwd.db"), shadow >= master
        {
            return false
        }
        let tool = root + "/usr/sbin/pwd_mkdb"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return nil
        }
        // pwd_mkdb also regenerates /etc/passwd from master.passwd.
        try runBootstrapTool(tool, ["-p", "/etc/master.passwd"])
        for (name, mode) in [("pwd.db", 0o644), ("spwd.db", 0o600)] {
            let path = etc + name
            guard chown(path, 0, 0) == 0, chmod(path, mode_t(mode)) == 0 else {
                throw GuestAPIError.operationFailed(
                    "Could not set the owner and mode of \(path): \(String(cString: strerror(errno)))",
                )
            }
        }
        let id = root + "/usr/bin/id"
        if FileManager.default.isExecutableFile(atPath: id) {
            try runBootstrapTool(id, ["root"])
        }
        return true
    }

    /// sshd resets every connection before its banner when it has no host
    /// key. `ssh-keygen -A` creates each missing default key type and leaves
    /// existing keys alone. Nothing happens until openssh has created
    /// /etc/ssh; returns nil while ssh-keygen is missing.
    private static func ensureHostKeys(root: String) throws -> Bool? {
        let directory = root + "/etc/ssh"
        guard isDirectory(directory) else {
            return false
        }
        let keys = ["ed25519", "ecdsa", "rsa"].map { "\(directory)/ssh_host_\($0)_key" }
        if keys.allSatisfy({ itemExists(URL(fileURLWithPath: $0)) }) {
            return false
        }
        let tool = root + "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return nil
        }
        try runBootstrapTool(tool, ["-A"])
        return true
    }

    private static func modificationTime(_ path: String) throws -> Double? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw GuestAPIError.operationFailed("Could not inspect \(path): \(String(cString: strerror(errno)))")
        }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// Runs a bootstrap tool by its physical path. It loads libroothide
    /// through the `.jbroot` link beside it, so its arguments are vroot
    /// paths: `/etc` in the child is `root/etc`.
    private static func runBootstrapTool(_ path: String, _ arguments: [String]) throws {
        var argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else {
            throw GuestAPIError.operationFailed("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        vp_spawn_file_actions_init(&actions)
        vp_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        vp_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        vp_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO)
        vp_spawn_file_actions_addclose(&actions, outputPipe[0])
        vp_spawn_file_actions_addclose(&actions, outputPipe[1])
        var pid: pid_t = 0
        let spawned = vp_spawn(&pid, path, &actions, nil, &argv, environ)
        vp_spawn_file_actions_destroy(&actions)
        close(outputPipe[1])
        guard spawned == 0 else {
            close(outputPipe[0])
            throw GuestAPIError.operationFailed("Could not run \(path): \(String(cString: strerror(spawned)))")
        }
        // Drain to EOF so a chatty tool never blocks on a full pipe.
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(outputPipe[0], &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            if count <= 0 {
                break
            }
            if output.count < 4096 {
                output.append(contentsOf: buffer.prefix(min(count, 4096 - output.count)))
            }
        }
        close(outputPipe[0])
        var status: Int32 = 0
        var waited = waitpid(pid, &status, 0)
        while waited < 0, errno == EINTR {
            waited = waitpid(pid, &status, 0)
        }
        guard waited == pid, status == 0 else {
            let details = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestAPIError.operationFailed("\(path) \(arguments.joined(separator: " ")) exited with status \(status): \(details)")
        }
    }
}
