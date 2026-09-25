import CryptoKit
import Foundation
import Observation
import Security
import ServiceManagement

/// Installs the privileged helper with SMJobBless and talks to it over XPC.
@MainActor
@Observable
final class VPhoneLaunchpadHelperClient {
    enum State: Equatable {
        case unknown
        case notInstalled
        case outdated(installed: String, bundled: String)
        case ready(String)
        /// This build has no team in its requirements, so SMJobBless and the
        /// XPC checks cannot succeed. See VPhoneLaunchpad.xcconfig.
        case unconfigured
    }

    private(set) var state: State = .unknown
    private var connection: NSXPCConnection?
    private let receiver = VPhoneLaunchpadHelperReceiver()

    nonisolated private static let label = VPhoneLaunchpadHelperIdentity.label

    // MARK: - Status

    /// CFBundleVersion of the helper embedded in this app.
    var bundledVersion: String? {
        let info = CFBundleCopyInfoDictionaryForURL(bundledHelper as CFURL) as? [String: Any]
        return info?["CFBundleVersion"] as? String
    }

    private var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(Self.label)")
    }

    private var installedHelper: URL {
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(Self.label)")
    }

    private var installedHelperMatches: Bool {
        guard let bundled = try? Data(contentsOf: bundledHelper, options: .mappedIfSafe),
              let installed = try? Data(contentsOf: installedHelper, options: .mappedIfSafe)
        else { return false }
        return SHA256.hash(data: bundled) == SHA256.hash(data: installed)
    }

    /// The requirement the app holds the helper to, from SMPrivilegedExecutables.
    private var helperRequirement: String? {
        let executables = Bundle.main.object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: String]
        return executables?[Self.label]
    }

    var isConfigured: Bool {
        guard let helperRequirement else {
            return false
        }
        return !helperRequirement.contains("subject.OU] = \"\"")
    }

    func refresh() async {
        guard isConfigured else {
            state = .unconfigured
            return
        }
        let hasJob = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(Self.label).plist")
        let hasExecutable = FileManager.default.fileExists(atPath: installedHelper.path)
        guard hasJob || hasExecutable else {
            state = .notInstalled
            return
        }
        let bundled = bundledVersion ?? "?"
        guard hasJob && hasExecutable else {
            state = .outdated(installed: "unknown", bundled: bundled)
            return
        }
        do {
            let installed = try await version()
            state = installed == bundled && installedHelperMatches
                ? .ready(installed)
                : .outdated(installed: installed, bundled: bundled)
        } catch {
            state = .outdated(installed: "unknown", bundled: bundled)
        }
    }

    // MARK: - Install

    /// Asks for an administrator and blesses the embedded helper.
    func install() async throws {
        guard isConfigured else {
            throw VPhoneLaunchpadError(
                String(localized: "Unable to Install Helper"),
                detail: String(localized: "This build has no signing team. Rebuild and sign the app with your team, then try again."),
            )
        }
        try await Task.detached { try Self.bless() }.value
        connection?.invalidate()
        connection = nil
        await refresh()
        guard case .ready = state else {
            throw VPhoneLaunchpadError(
                String(localized: "Unable to Install Helper"),
                detail: String(localized: "The installed helper did not match the copy in this app. Try again."),
            )
        }
    }

    func uninstall() async throws {
        try await call { proxy, done in
            proxy.uninstallHelper { message in done(message.map { VPhoneLaunchpadError($0) }) }
        }
        connection?.invalidate()
        connection = nil
        state = .notInstalled
    }

    nonisolated private static func bless() throws {
        var authorization: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw VPhoneLaunchpadError(String(localized: "Unable to Get Administrator Permission"), detail: String(localized: "Try again."))
        }
        defer { AuthorizationFree(authorization, []) }

        status = kSMRightBlessPrivilegedHelper.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil,
                )
            }
        }
        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled {
                throw CancellationError()
            }
            throw VPhoneLaunchpadError(String(localized: "Unable to Get Administrator Permission"), detail: String(localized: "Try again."))
        }

        var error: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, label as CFString, authorization, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? String(localized: "Try again.")
            throw VPhoneLaunchpadError(String(localized: "Unable to Install Helper"), detail: detail)
        }
    }

    // MARK: - Calls

    func version() async throws -> String {
        try await withTimeout(seconds: 5) { proxy, done in
            proxy.helperVersion { done(.success($0)) }
        }
    }

    func installBundle(version: String, archive: FileHandle, sha256: String) async throws {
        try await call { proxy, done in
            proxy.installBundle(version: version, archive: archive, sha256: sha256) { message in
                done(message.map { VPhoneLaunchpadError($0) })
            }
        }
    }

    func removeBundle(version: String) async throws {
        try await call { proxy, done in
            proxy.removeBundle(version: version) { message in done(message.map { VPhoneLaunchpadError($0) }) }
        }
    }

    func allowVirtualMachine(bundleVersion: String) async throws {
        await refresh()
        if case .outdated = state {
            try await install()
        }
        guard case .ready = state else {
            throw VPhoneLaunchpadError(
                String(localized: "Update the privileged helper in Host Setup, then run preflight again."),
            )
        }
        try await call { proxy, done in
            proxy.allowVirtualMachine(bundleVersion: bundleVersion) { message in
                done(message.map { VPhoneLaunchpadError($0) })
            }
        }
    }

    /// Runs `cfw install` as root. Output lines go to `onLine`.
    func installCustomFirmware(
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        forceDyldSharedCacheMaxSlide: Bool,
        keepArtifacts: Bool,
        onLine: @escaping @MainActor @Sendable (String) -> Void,
    ) async throws -> Int32 {
        receiver.setHandler { line in
            DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
        }
        defer { receiver.setHandler(nil) }
        return try await withTaskCancellationHandler {
            try await request { proxy, done in
                proxy.installCustomFirmware(
                    bundleVersion: bundleVersion,
                    machineName: machineName,
                    libraryRoot: libraryRoot,
                    forceDyldSharedCacheMaxSlide: forceDyldSharedCacheMaxSlide,
                    keepArtifacts: keepArtifacts,
                ) { status, message in
                    if let message {
                        done(.failure(VPhoneLaunchpadError(message)))
                    } else {
                        done(.success(status))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelCustomFirmware() }
        }
    }

    func cancelCustomFirmware() {
        let proxy = currentConnection().remoteObjectProxy as? VPhoneLaunchpadHelperProtocol
        proxy?.cancelCustomFirmware {}
    }

    // MARK: - XPC plumbing

    private func currentConnection() -> NSXPCConnection {
        if let connection {
            return connection
        }
        let connection = NSXPCConnection(machServiceName: Self.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneLaunchpadHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: VPhoneLaunchpadHelperClientProtocol.self)
        connection.exportedObject = receiver
        if let helperRequirement {
            connection.setCodeSigningRequirement(helperRequirement)
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// One request whose reply carries a value.
    private func request<T: Sendable>(
        _ body: (VPhoneLaunchpadHelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void,
    ) async throws -> T {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = VPhoneLaunchpadResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
            }
            guard let helper = proxy as? VPhoneLaunchpadHelperProtocol else {
                once.resume(.failure(VPhoneLaunchpadError(String(localized: "Unable to connect to the helper. Quit and reopen the app, then try again."))))
                return
            }
            body(helper) { once.resume($0) }
        }
    }

    /// One request whose reply carries only an optional error.
    private func call(
        _ body: (VPhoneLaunchpadHelperProtocol, @escaping @Sendable (Error?) -> Void) -> Void,
    ) async throws {
        let _: Bool = try await request { proxy, done in
            body(proxy) { error in done(error.map { .failure($0) } ?? .success(true)) }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping (VPhoneLaunchpadHelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void,
    ) async throws -> T {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = VPhoneLaunchpadResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                once.resume(.failure(VPhoneLaunchpadError(String(localized: "The helper did not answer."))))
            }
            guard let helper = proxy as? VPhoneLaunchpadHelperProtocol else {
                once.resume(.failure(VPhoneLaunchpadError(String(localized: "Unable to connect to the helper. Quit and reopen the app, then try again."))))
                return
            }
            body(helper) { once.resume($0) }
        }
    }
}

// MARK: - Support

/// Resumes a continuation exactly once, whichever of reply, error handler or
/// timeout arrives first.
nonisolated final class VPhoneLaunchpadResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

/// Receives output lines the helper streams back during a CFW install.
nonisolated final class VPhoneLaunchpadHelperReceiver: NSObject, VPhoneLaunchpadHelperClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func helperDidEmit(line: String) {
        let handler = lock.withLock { self.handler }
        handler?(line)
    }
}

#if DEBUG
    extension VPhoneLaunchpadHelperClient {
        func applyPreview(_ state: State) {
            self.state = state
        }
    }
#endif
