import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - network

/// The NIC of a running VM: show it, or unplug and replug it. Nothing here is
/// saved; `vm config` changes what the next launch uses, and moving to another
/// network needs a restart (see `VPhoneVirtualMachine.setNetworkLink`).
struct VPhoneVirtualMachineNetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Show a running VM's network link, or unplug and replug it",
        discussion: """
        Without options, prints the NIC's state. --link down unplugs the guest's cable and \
        --link up plugs it back in; the guest sees the link drop and come back. Nothing is \
        saved. To move the VM to another network, change it with vm config and restart it.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .long, help: "up | down") var link: String?
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        if let link, link != "up", link != "down" {
            throw ValidationError("--link must be up or down.")
        }
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let socketPath = bundle.url.appendingPathComponent("vphone.sock").path

        var request: [String: Any] = ["t": "network"]
        request["link"] = link
        guard let reply = VPhoneControlSocket.send(request, socketPath: socketPath, timeout: 10) else {
            throw ValidationError("\(name) is not running, or its control socket does not answer. Start it with vm launch.")
        }
        guard reply["ok"] as? Bool == true, let status = reply["result"] as? [String: Any] else {
            throw ValidationError(reply["error"] as? String ?? "the VM refused the request")
        }

        if json {
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard status["device"] as? Bool == true else {
            print("\(name): no network device")
            return
        }
        print("link:       \(status["link"] as? String ?? "?")")
        print("attached:   \(status["attachment"] as? String ?? "?")")
        if let configured = status["configured"] as? String {
            print("configured: \(configured)")
        }
        if let guest = status["guest_ipv4"] as? String, !guest.isEmpty {
            print("guest:      \(guest)")
        }
        for forward in status["forwards"] as? [String] ?? [] {
            print("forward:    \(forward)")
        }
        if let name = status["local_host_name"] as? String, !name.isEmpty {
            print("mdns:       \(name)")
        }
    }
}
