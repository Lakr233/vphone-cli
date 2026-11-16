import ArgumentParser
import Foundation
import VPhoneCommandKit
import VPhoneCoreKit

struct VPhoneCustomFirmwareInstallRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-root", abstract: "Internal privileged CFW disk install",
        shouldDisplay: false,
    )

    @Argument(help: "VM bundle path") var bundle: String
    @Option(help: "Resource base") var resources: String
    @Option(name: .customLong("work-parent"), help: "Root-owned private CFW temporary directory")
    var workParent = VPhoneCustomFirmwareInstaller.defaultWorkParent

    func run() throws {
        try VPhoneCustomFirmwareInstaller(
            bundle: URL(fileURLWithPath: bundle),
            resources: VPhoneResources(base: URL(fileURLWithPath: resources)),
            workParent: workParent,
        ).run()
    }
}
