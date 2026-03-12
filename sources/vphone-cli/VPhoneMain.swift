import AppKit
import ArgumentParser
import Foundation

@main
struct VPhoneMain {
    static func main() async {
        if ProcessInfo.processInfo.environment["VPHONE_SSH_ASKPASS"] == "1" {
            print(ProcessInfo.processInfo.environment["VPHONE_SSH_PASSWORD"] ?? "alpine")
            return
        }

        do {
            let command = try VPhoneCLI.parseAsRoot()
            if let helpType = requestedHelpType(arguments: CommandLine.arguments) {
                print(helpMessage(for: helpType))
                return
            }

            switch command {
            case let boot as VPhoneBootCLI:
                let app = NSApplication.shared
                let delegate = VPhoneAppDelegate(cli: boot)
                app.delegate = delegate
                app.run()

            case var patch as PatchFirmwareCLI:
                try patch.run()

            case var patch as PatchComponentCLI:
                try patch.run()

            case var command as VMCreateCLI:
                try await command.run()

            case var command as GenerateVMManifestCLI:
                try command.run()

            case var command as BootHostPreflightCLI:
                try await command.run()

            case var command as StartAmfidontCLI:
                try await command.run()

            case var command as GenerateFirmwareManifestCLI:
                try command.run()

            case var command as PrepareFirmwareCLI:
                try await command.run()

            case var command as RestoreGetSHSHCLI:
                try await command.run()

            case var command as RestoreDeviceCLI:
                try await command.run()

            case var command as BuildRamdiskCLI:
                try await command.run()

            case var command as SendRamdiskCLI:
                try await command.run()

            case var command as SetupToolsCLI:
                try await command.run()

            case var command as SetupMachineCLI:
                try await command.run()

            case var command as BuildHostCLI:
                try await command.run()

            case var command as BundleAppCLI:
                try await command.run()

            case var command as BuildVphonedCLI:
                try await command.run()

            case var command as CFWInstallCLI:
                try await command.run()

            case var command as USBMuxListCLI:
                try command.run()

            case var command as USBMuxForwardCLI:
                try command.run()

            case var command as CFWCryptexPathsCLI:
                try command.run()

            case var command as CFWPatchSeputilCLI:
                try command.run()

            case var command as CFWPatchLaunchdCacheLoaderCLI:
                try command.run()

            case var command as CFWPatchMobileactivationdCLI:
                try command.run()

            case var command as CFWPatchLaunchdJetsamCLI:
                try command.run()

            case var command as CFWInjectDaemonsCLI:
                try await command.run()

            case var command as CFWInjectLaunchDaemonCLI:
                try command.run()

            case var command as CFWInjectDylibCLI:
                try await command.run()

            default:
                break
            }
        } catch {
            VPhoneCLI.exit(withError: error)
        }
    }

    static func requestedHelpType(arguments: [String]) -> ParsableCommand.Type? {
        var commandArguments = Array(arguments.dropFirst())
        if commandArguments.isEmpty {
            return nil
        }
        if commandArguments.first == "help" {
            commandArguments.removeFirst()
        } else if !commandArguments.contains("--help"), !commandArguments.contains("-h") {
            return nil
        }

        commandArguments.removeAll { $0 == "--help" || $0 == "-h" }
        guard let first = commandArguments.first, !first.hasPrefix("-") else {
            return VPhoneCLI.self
        }

        return VPhoneCLI.configuration.subcommands.first {
            $0.configuration.commandName == first
        } ?? VPhoneCLI.self
    }

    static func helpMessage(for commandType: ParsableCommand.Type) -> String {
        if commandType == VPhoneCLI.self {
            return VPhoneCLI.helpMessage()
        }
        return VPhoneCLI.helpMessage(for: commandType)
    }
}
