import AppKit
import CryptoKit
import Foundation
import VPhoneCoreKit

/// Controls only the per-user job installed by the optional guest SOCKS5 add-on.
/// The job follows vphone.sock independently of the menu, also for headless boots.
struct VPhoneSOCKS5Addon: Sendable {
    let label: String
    let agent: URL
    private let domain: String

    init(machine: URL) {
        let path = machine.resolvingSymlinksInPath().standardizedFileURL.path
        let suffix = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        label = "com.vphone.socks5.\(suffix)"
        agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        domain = "gui/\(getuid())"
    }

    var installed: Bool { FileManager.default.fileExists(atPath: agent.path) }

    func isEnabled() throws -> Bool {
        try run(["print", "\(domain)/\(label)"]).succeeded
    }

    /// launchd remembers the setting across logins. Bootout also closes the
    /// current guest session. Restore the previous setting if the transition fails.
    func setEnabled(_ enabled: Bool) throws {
        let target = "\(domain)/\(label)"
        guard try isEnabled() != enabled else { return }
        try requireSuccess([enabled ? "enable" : "disable", target])
        do {
            try requireSuccess(enabled ? ["bootstrap", domain, agent.path] : ["bootout", target])
        } catch {
            try? requireSuccess([enabled ? "disable" : "enable", target])
            throw error
        }
    }

    private func requireSuccess(_ arguments: [String]) throws {
        let result = try run(arguments)
        guard result.succeeded else {
            throw NSError(domain: "SOCKS5", code: Int(result.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    private func run(_ arguments: [String]) throws -> VPhoneProcessResult {
        try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/bin/launchctl"), arguments)
    }
}

@MainActor
final class VPhoneSOCKS5Menu: NSObject, NSMenuDelegate {
    private let addon: VPhoneSOCKS5Addon
    private let item = NSMenuItem(title: "Guest SOCKS5 Server", action: #selector(toggle), keyEquivalent: "")

    init(machine: URL) {
        addon = VPhoneSOCKS5Addon(machine: machine)
    }

    func attach(to menu: NSMenu) {
        item.target = self
        menu.addItem(item)
        menu.delegate = self
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    @objc private func toggle() {
        do {
            try addon.setEnabled(!addon.isEnabled())
        } catch {
            VPhoneAlert.present(title: "Guest SOCKS5 Server", message: error.localizedDescription, style: .warning)
        }
        refresh()
    }

    private func refresh() {
        item.isHidden = !addon.installed
        guard !item.isHidden else { return }
        item.state = (try? addon.isEnabled()) == true ? .on : .off
    }
}
