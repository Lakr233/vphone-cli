import ArgumentParser
import Foundation
import VPhoneCoreKit

// MARK: - ca

/// Install, remove, and list the guest's trusted custom CA anchors (user or admin trust
/// domain, selected by `install --admin`) by
/// driving the `security.ca_*` RPCs over the target VM's control socket
/// (`vphone.sock`), exactly as `vm network` reaches a running VM. The VM is a
/// positional name; there is no HTTP API, base URL, or token.
struct VPhoneVirtualMachineCACommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ca",
        abstract: "Install, remove, or list the guest's trusted custom CA anchors",
        subcommands: [
            Install.self,
            Remove.self,
            List.self,
        ],
    )

    /// Run the core, mapping its typed errors to the CLI exit contract: a usage
    /// reject is exit 2, any runtime failure exit 1, both on stderr.
    static func dispatch(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as VPhoneGuestCA.UsageError {
            throw stderrExit(error.description, code: 2)
        } catch let error as VPhoneGuestCA.RuntimeError {
            throw stderrExit(error.description, code: 1)
        }
    }

    private static func stderrExit(_ message: String, code: Int32) -> Error {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return ExitCode(code)
    }

    // MARK: install

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a custom CA (single-cert PEM, ≤64 KiB) as a trusted root in the guest",
        )

        @OptionGroup var lib: VPhoneLibraryOption
        @Argument(help: "VM name") var name: String?
        @Argument(help: "PEM file with exactly one certificate") var pemFile: String
        @Flag(help: "Install into the admin trust domain instead of user (default user)")
        var admin = false

        func run() throws {
            let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
            try VPhoneVirtualMachineCACommand.dispatch {
                try VPhoneGuestCA.install(
                    vmName: name, library: lib.library, pemPath: pemFile, admin: admin,
                    rpc: VPhoneHostAutomationProbe.rpc,
                )
            }
        }
    }

    // MARK: remove

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a trusted custom CA from the guest by its 64-char hex sha256",
        )

        @OptionGroup var lib: VPhoneLibraryOption
        @Argument(help: "VM name") var name: String?
        @Argument(help: "64-char hex sha256 of the anchor, as shown by ca list") var sha256: String

        func run() throws {
            let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
            try VPhoneVirtualMachineCACommand.dispatch {
                try VPhoneGuestCA.remove(
                    vmName: name, library: lib.library, sha256: sha256,
                    rpc: VPhoneHostAutomationProbe.rpc,
                )
            }
        }
    }

    // MARK: list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the guest's installed CA anchors (sha256 TAB subject)",
        )

        @OptionGroup var lib: VPhoneLibraryOption
        @Argument(help: "VM name") var name: String?

        func run() throws {
            let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
            try VPhoneVirtualMachineCACommand.dispatch {
                let output = try VPhoneGuestCA.list(
                    vmName: name, library: lib.library,
                    rpc: VPhoneHostAutomationProbe.rpc,
                )
                FileHandle.standardOutput.write(Data(output.utf8))
            }
        }
    }
}
