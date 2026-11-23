import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - pause / resume

/// Stops a running guest where it is, and lets it run on, through the VM's
/// control socket (`{"t":"pause"}`, `{"t":"resume"}`). Nothing is saved: a
/// paused VM still holds its memory, and stopping it ends the guest as usual.
struct VPhoneVirtualMachinePauseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause a running VM's guest until vm resume",
        discussion: """
        The guest stops where it is: its apps, its clock and its network. vphoned does not \
        answer, so commands that need the guest fail until vm resume. The VM keeps its memory \
        while paused; vm stop resumes the guest and shuts it down as usual.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?

    func run() throws {
        try VPhoneVirtualMachinePauseRequest.send("pause", to: name, in: lib.library)
    }
}

struct VPhoneVirtualMachineResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Let a VM paused with vm pause run on",
        discussion: """
        The guest carries on where it stopped. Its clock is set to the Mac's again once \
        vphoned answers.
        """,
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?

    func run() throws {
        try VPhoneVirtualMachinePauseRequest.send("resume", to: name, in: lib.library)
    }
}

private enum VPhoneVirtualMachinePauseRequest {
    static func send(_ type: String, to name: String?, in library: VPhoneLibrary) throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: library)
        let bundle = try library.bundle(named: name)
        let socketPath = bundle.url.appendingPathComponent("vphone.sock").path
        guard let reply = VPhoneHostAutomationProbe.send(["t": type], socketPath: socketPath, timeout: 30) else {
            throw ValidationError("\(name) is not running, or its control socket does not answer. Start it with vm launch.")
        }
        guard reply["ok"] as? Bool == true, let status = reply["result"] as? [String: Any] else {
            throw ValidationError(reply["error"] as? String ?? "the VM refused the request")
        }
        print("\(name): \(status["paused"] as? Bool == true ? "paused" : "running")")
    }
}
