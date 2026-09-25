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
    private let authorizationSession = VPhoneLaunchpadHelperAuthorizationSession()

    private nonisolated static let label = VPhoneLaunchpadHelperIdentity.label

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
        guard hasJob, hasExecutable else {
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
        let authorization = try await authorizationSession.externalForm()
        try await call { proxy, done in
            proxy.uninstallHelper(authorization: authorization) { message in
                done(message.map { VPhoneLaunchpadError($0) })
            }
        }
        connection?.invalidate()
        connection = nil
        state = .notInstalled
    }

    private typealias JobBless = @convention(c) (
        CFString,
        CFString,
        AuthorizationRef,
        UnsafeMutablePointer<Unmanaged<CFError>?>?,
    ) -> DarwinBoolean

    /// `SMJobBless`, looked up in ServiceManagement at run time. macOS 13
    /// deprecated it in favour of `SMAppService`, but it still works, and the
    /// helper's install, update and client checks are built on it
    /// (SMPrivilegedExecutables and SMAuthorizedClients). Moving to
    /// `SMAppService.daemon` would change all three. The lookup keeps that
    /// choice here instead of as a standing deprecation warning.
    private nonisolated static let jobBless: JobBless? = dlopen(
        "/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement",
        RTLD_LAZY,
    )
    .flatMap { dlsym($0, "SMJobBless") }
    .map { unsafeBitCast($0, to: JobBless.self) }

    private nonisolated static func bless() throws {
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
        guard let jobBless = Self.jobBless,
              jobBless(kSMDomainSystemLaunchd, label as CFString, authorization, &error).boolValue
        else {
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
        let authorization = try await authorizationSession.externalForm()
        try await call { proxy, done in
            proxy.installBundle(
                authorization: authorization,
                version: version,
                archive: archive,
                sha256: sha256,
            ) { message in
                done(message.map { VPhoneLaunchpadError($0) })
            }
        }
    }

    func removeBundle(version: String) async throws {
        let authorization = try await authorizationSession.externalForm()
        try await call { proxy, done in
            proxy.removeBundle(authorization: authorization, version: version) { message in
                done(message.map { VPhoneLaunchpadError($0) })
            }
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
        let authorization = try await authorizationSession.externalForm()
        try await call { proxy, done in
            proxy.allowVirtualMachine(authorization: authorization, bundleVersion: bundleVersion) { message in
                done(message.map { VPhoneLaunchpadError($0) })
            }
        }
    }

    /// Runs `cfw install` as root. Output lines go to `onLine`, on the XPC
    /// connection's queue.
    func installCustomFirmware(
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        forceDyldSharedCacheMaxSlide: Bool,
        keepArtifacts: Bool,
        onLine: @escaping @Sendable (String) -> Void,
    ) async throws -> Int32 {
        let authorization = try await authorizationSession.externalForm()
        receiver.setHandler(onLine)
        defer { receiver.setHandler(nil) }
        return try await withTaskCancellationHandler {
            try await request { proxy, done in
                proxy.installCustomFirmware(
                    authorization: authorization,
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

    /// Never prompts. The helper stops only an install this user started.
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
final nonisolated class VPhoneLaunchpadResumeOnce<T: Sendable>: @unchecked Sendable {
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

/// The app's AuthorizationRef for the helper's privileged right, created once
/// and kept for the app's lifetime, so an administrator's approval lasts for
/// the right's timeout instead of being asked for on every call.
final nonisolated class VPhoneLaunchpadHelperAuthorizationSession: @unchecked Sendable {
    private let lock = NSLock()
    private var reference: AuthorizationRef?
    /// Runs prompts one at a time, off the main actor and the cooperative pool.
    private let queue = DispatchQueue(label: "com.vphone.launchpad.authorization")

    /// Obtains the privileged right, asking for an administrator when needed,
    /// and returns the AuthorizationExternalForm to send to the helper.
    func externalForm() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.authorize() })
            }
        }
    }

    private func authorize() throws -> Data {
        let reference = try lock.withLock {
            if let reference = self.reference {
                return reference
            }
            var created: AuthorizationRef?
            guard AuthorizationCreate(nil, nil, [], &created) == errAuthorizationSuccess, let created else {
                throw Self.failure
            }
            self.reference = created
            return created
        }
        let status = VPhoneLaunchpadHelperIdentity.privilegedRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(
                    reference,
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
            throw Self.failure
        }
        return try Self.externalForm(of: reference)
    }

    private static func externalForm(of reference: AuthorizationRef) throws -> Data {
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &form) == errAuthorizationSuccess else {
            throw failure
        }
        return withUnsafeBytes(of: form.bytes) { Data($0) }
    }

    private static var failure: VPhoneLaunchpadError {
        VPhoneLaunchpadError(
            String(localized: "Unable to Get Administrator Permission"),
            detail: String(localized: "Try again."),
        )
    }
}

/// Receives output lines the helper streams back during a CFW install.
final nonisolated class VPhoneLaunchpadHelperReceiver: NSObject, VPhoneLaunchpadHelperClientProtocol, @unchecked Sendable {
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
