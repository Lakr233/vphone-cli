import Foundation
import VPhoneCoreKit

/// The half of VPhoneBootCommand that needs the Virtualization framework. The
/// options themselves live in VPhoneCoreKit so vphone-cli can parse and forward
/// them without linking any of this.
extension VPhoneBootCommand {
    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        return try VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages != nil
                ? manifest.resolve(path: manifest.romImages!.avpBooter, in: vmDir)
                : nil,
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages != nil
                ? manifest.resolve(path: manifest.romImages!.avpSEPBooter, in: vmDir)
                : nil,
            screenWidth: manifest.screenConfig.width,
            screenHeight: manifest.screenConfig.height,
            screenPPI: manifest.screenConfig.pixelsPerInch,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
        )
    }
}
