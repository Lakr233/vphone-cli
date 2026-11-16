import ArgumentParser
import Foundation
import VPhoneCommandKit
import VPhoneCoreKit

// MARK: - Slimming switches

/// The slimming switches `vm create` and `vm template setup` share.
struct VPhoneTemplateSlimmingOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Slim the template: on (default) | off. off keeps every service and app; Setup is skipped either way",
        valueName: "on|off",
    ))
    var slim: String?
    @Option(help: ArgumentHelp(
        "System files the template deletes offline: standard (default) | conservative | none. Part of the template key; vm template trim describes the tiers",
        valueName: "tier",
    ))
    var trim: String?
    @Option(help: ArgumentHelp("Languages whose linguistic data --trim standard keeps (en is always kept)", valueName: "en,zh-Hans,zh"))
    var keepLanguages: String?
    @Option(help: ArgumentHelp("Service profile the template applies: trimmed (default) | none", valueName: "profile"))
    var serviceProfile: String?
    @Option(help: ArgumentHelp("Remove the default system apps (App Store, TV, News, …): on (default) | off", valueName: "on|off"))
    var removeApps: String?
    @Option(
        help: ArgumentHelp("Bundle IDs of default-removed apps to keep, comma-separated (com.apple.findmy,com.apple.Passbook)", valueName: "ids"),
        transform: { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } },
    )
    var keepApps: [String] = []
    @Flag(help: "Also turn off the Apple Account daemons (akd, amsaccountsd, appleaccountd); the guest then cannot sign in")
    var accountsOff = false

    var request: VPhoneTemplateSlimmingRequest {
        get throws {
            try VPhoneTemplateSlimmingRequest(
                slim: slim.map { try VPhoneVirtualMachineConfigCommand.parseSwitch($0, option: "--slim") },
                trimTier: trim,
                keepLanguages: keepLanguages,
                serviceProfile: serviceProfile,
                removeApps: removeApps.map { try VPhoneVirtualMachineConfigCommand.parseSwitch($0, option: "--remove-apps") },
                keepApps: keepApps,
                accountsOff: accountsOff,
            )
        }
    }

    /// The slimming asked for, as a ValidationError when switches disagree.
    func resolve() throws -> VPhoneMachineTemplateSlimming {
        do {
            return try request.resolve()
        } catch let error as VPhoneTemplateSlimmingError {
            throw ValidationError(error.description)
        }
    }
}
