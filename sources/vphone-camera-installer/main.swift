import Foundation
import SystemExtensions
import VPhoneCameraShared

private enum InstallerExit: Int32 {
    case enabled = 0
    case failed = 1
    case awaitingApproval = 3
    case restartRequired = 4
    case malformedInvocation = 64
}

private enum InstallerOperation {
    case activate
    case deactivate

    var verb: String {
        switch self {
        case .activate: "activation"
        case .deactivate: "deactivation"
        }
    }

    static func parse(arguments: ArraySlice<String>) -> InstallerOperation? {
        switch Array(arguments) {
        case ["--activate"]: .activate
        case ["--deactivate"]: .deactivate
        default: nil
        }
    }
}

@MainActor
private final class CameraExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    private var finished = false
    private var exitCode: InstallerExit = .awaitingApproval
    private var approvalRequested = false
    private var request: OSSystemExtensionRequest?

    func run(operation: InstallerOperation) -> InstallerExit {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.deletingLastPathComponent().path == "/Applications" else {
            print("VPhone Display: install vphone-cli-camera-installer.app in /Applications first")
            return .failed
        }
        if operation == .activate {
            let extensionURL = bundle.appendingPathComponent(
                "Contents/Library/SystemExtensions/\(VPhoneVirtualCamera.extensionIdentifier).systemextension")
            guard FileManager.default.fileExists(atPath: extensionURL.path) else {
                print("VPhone Display: bundled camera extension is missing")
                return .failed
            }
        }

        let request: OSSystemExtensionRequest
        switch operation {
        case .activate:
            request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: VPhoneVirtualCamera.extensionIdentifier, queue: .main)
        case .deactivate:
            request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: VPhoneVirtualCamera.extensionIdentifier, queue: .main)
        }
        request.delegate = self
        self.request = request
        OSSystemExtensionManager.shared.submitRequest(request)
        print("VPhone Display: \(operation.verb) requested")

        let deadline = Date().addingTimeInterval(10)
        while !finished, !approvalRequested, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if approvalRequested, !finished {
            let pendingMessage = operation == .activate
                ? "VPhone Display: awaiting approval; use Go to System Settings in the macOS dialog"
                : "VPhone Display: awaiting approval to deactivate"
            print(pendingMessage)
            return .awaitingApproval
        }
        if !finished {
            print("VPhone Display: \(operation.verb) is still pending; check System Settings and retry")
            return .awaitingApproval
        }
        self.request = nil
        return exitCode
    }

    nonisolated func request(
        _: OSSystemExtensionRequest,
        actionForReplacingExtension _: OSSystemExtensionProperties,
        withExtension _: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        Task { @MainActor in
            approvalRequested = true
            print("VPhone Display: macOS requires your approval")
        }
    }

    nonisolated func request(
        _: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            exitCode = result == .completed ? .enabled : .restartRequired
            finished = true
            print(result == .completed
                ? "VPhone Display: request completed"
                : "VPhone Display: request completed after restart")
        }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        Task { @MainActor in
            print("VPhone Display: activation failed (\(error.localizedDescription) "
                + "[\(nsError.domain):\(nsError.code)])")
            exitCode = .failed
            finished = true
        }
    }
}

guard let operation = InstallerOperation.parse(arguments: CommandLine.arguments.dropFirst()) else {
    fputs("usage: vphone-camera-installer --activate|--deactivate\n", stderr)
    exit(InstallerExit.malformedInvocation.rawValue)
}
private let activator = CameraExtensionActivator()
exit(activator.run(operation: operation).rawValue)
