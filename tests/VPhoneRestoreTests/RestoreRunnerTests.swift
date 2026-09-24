import Foundation
import Testing
@testable import VPhoneRestore

/// The only tests here that really call `vphone_restore_run`.
///
/// Every case below is one the C bridge rejects in its own argument checks,
/// BEFORE `vphone_drive_idevicerestore` — so no USB is opened, nothing is sent
/// to Apple, and no device is needed. What they prove is the plumbing: that the
/// C strings survive the call, that the log callback reaches a Swift closure
/// through `void *context`, and that a result code becomes the right typed
/// error. None of them says a real restore works; that needs a phone in DFU.
///
/// `.serialized` for two reasons. The bridge allows one restore per process and
/// answers a second with `VPHONE_RESTORE_E_BUSY`, and it redirects the
/// process's `stdout` into itself while it runs — so anything else printing
/// during that window arrives at the log callback instead of on the terminal.
/// The window is a few milliseconds per case; it is still why these are not
/// spread through the other suites.
@Suite(.serialized)
struct RestoreRunnerTests {
    // MARK: - Fixtures

    /// Thread-safe, because the callbacks come off idevicerestore's worker
    /// threads and `@Sendable` is not a suggestion.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [VPhoneRestoreEvent] = []

        func record(_ event: VPhoneRestoreEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.compactMap { event in
                if case let .log(_, message) = event {
                    return message
                }
                return nil
            }
        }

        var errorMessages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.compactMap { event in
                if case let .log(level, message) = event, level == .error {
                    return message
                }
                return nil
            }
        }
    }

    private func withTemporaryDirectory<R>(_ body: (URL) throws -> R) throws -> R {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    // MARK: - Restore directory

    @Test func `an absent restore directory is rejected and reported`() throws {
        let absent = URL(fileURLWithPath: "/nonexistent/vphone/iPhone17,3_Restore")
        let collector = Collector()

        #expect(throws: VPhoneRestoreBackendError.restoreDirectoryUnusable(absent)) {
            try VPhoneRestoreRunner.run(
                VPhoneRestoreOptions(restoreDirectory: absent),
                onEvent: { collector.record($0) },
            )
        }

        // The log callback reached Swift, and the path it names is the one that
        // was passed — which is the whole `void *context` + strdup round trip.
        let errors = collector.errorMessages
        #expect(!errors.isEmpty)
        #expect(errors.contains { $0.contains("/nonexistent/vphone/iPhone17,3_Restore") })
    }

    @Test func `a file is not A restore directory`() throws {
        try withTemporaryDirectory { root in
            // This build has no libzip, so a .ipsw is refused here by name
            // rather than failing four layers down in src/ipsw.c.
            let archive = root.appendingPathComponent("iPhone17,3_Restore.ipsw")
            try Data("PK\u{03}\u{04}not really".utf8).write(to: archive)
            let collector = Collector()

            #expect(throws: VPhoneRestoreBackendError.restoreDirectoryUnusable(archive)) {
                try VPhoneRestoreRunner.run(
                    VPhoneRestoreOptions(restoreDirectory: archive),
                    onEvent: { collector.record($0) },
                )
            }
            #expect(collector.errorMessages.contains { $0.contains("not a directory") })
        }
    }

    // MARK: - Ticket

    @Test func `an offline ticket that is not A plist is rejected`() throws {
        try withTemporaryDirectory { root in
            // A real directory, so the run gets past the restore-dir checks and
            // into the offline-ticket loader — still without a device, because
            // the ticket is read before idevicerestore is started at all.
            let restoreDirectory = root.appendingPathComponent("iPhone17,3_Restore", isDirectory: true)
            try FileManager.default.createDirectory(at: restoreDirectory, withIntermediateDirectories: true)
            let ticket = root.appendingPathComponent("000000011A2B3C4D.shsh")
            try Data("this is not a property list".utf8).write(to: ticket)
            let collector = Collector()

            #expect(throws: VPhoneRestoreBackendError.ticketUnreadable(ticket)) {
                try VPhoneRestoreRunner.run(
                    VPhoneRestoreOptions(restoreDirectory: restoreDirectory, ticketPath: ticket),
                    onEvent: { collector.record($0) },
                )
            }
            #expect(collector.errorMessages.contains { $0.contains(ticket.path) })
        }
    }

    @Test func `a run without A callback is still safe`() throws {
        // The default handler discards, and the C side takes NULL for the
        // context it never uses. Nothing here may dereference it anyway.
        let absent = URL(fileURLWithPath: "/nonexistent/vphone/iPhone17,3_Restore")
        #expect(throws: VPhoneRestoreBackendError.restoreDirectoryUnusable(absent)) {
            try VPhoneRestoreRunner.run(VPhoneRestoreOptions(restoreDirectory: absent))
        }
    }

    // MARK: - The facade

    @Test func `fetching ASHSH stops at the missing restore tree`() throws {
        // `VPhoneRestoreBridge` finds the restore tree BEFORE it starts a run,
        // so an empty bundle never reaches idevicerestore at all.
        try withTemporaryDirectory { root in
            #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(root)) {
                try VPhoneRestoreBridge.fetchSHSH(vmDir: root, ecid: nil, udid: nil, out: nil)
            }
        }
    }

    @Test func `restoring stops at the missing restore tree`() throws {
        try withTemporaryDirectory { root in
            #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(root)) {
                try VPhoneRestoreBridge.restore(
                    vmDir: root,
                    ecid: nil,
                    udid: nil,
                    erase: true,
                    ticketPath: nil,
                )
            }
        }
    }

    @Test func `the cached SHSH notice is printed before the restore starts`() throws {
        try withTemporaryDirectory { root in
            // Python printed "[+] Using cached SHSH: …" the moment it loaded
            // the blob. Users grep for that line, so it has to survive — and it
            // has to come out even when the restore then fails.
            let restoreDirectory = root.appendingPathComponent("iPhone17,3_Restore", isDirectory: true)
            try FileManager.default.createDirectory(at: restoreDirectory, withIntermediateDirectories: true)
            let ticket = root.appendingPathComponent("000000011A2B3C4D.shsh")
            try Data("not a plist".utf8).write(to: ticket)
            let collector = Collector()

            #expect(throws: VPhoneRestoreBackendError.ticketUnreadable(ticket)) {
                try VPhoneRestoreBridge.restore(
                    vmDir: root,
                    ecid: 0x0000_0001_1A2B_3C4D,
                    udid: nil,
                    erase: true,
                    ticketPath: ticket,
                    onEvent: { collector.record($0) },
                )
            }
            #expect(collector.messages.contains("[+] Using cached SHSH: \(ticket.path)"))
        }
    }
}
