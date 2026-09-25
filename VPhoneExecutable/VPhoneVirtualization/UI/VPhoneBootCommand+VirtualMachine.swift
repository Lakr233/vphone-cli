import Foundation
import VPhoneCoreKit

/// The half of VPhoneBootCommand that needs the Virtualization framework. The
/// options themselves live in VPhoneCoreKit so vphone-cli can parse and forward
/// them without linking any of this.
extension VPhoneBootCommand {
    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        // config.plist is rewritten on first boot; a symbolic link here would
        // be read from and written back through to a file outside the bundle.
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: config) else {
            throw VPhoneManifestError.loadFailed(path: config.path)
        }
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        return try VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages.map { try manifest.resolve(path: $0.avpBooter, in: vmDir) },
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages.map { try manifest.resolve(path: $0.avpSEPBooter, in: vmDir) },
            screenWidth: manifest.screenConfig.width,
            screenHeight: manifest.screenConfig.height,
            screenPPI: manifest.screenConfig.pixelsPerInch,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
        )
    }
}
