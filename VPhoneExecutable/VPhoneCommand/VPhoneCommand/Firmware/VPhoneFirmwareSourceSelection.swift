import ArgumentParser
import Foundation
import VPhoneCoreKit

enum VPhoneFirmwareSourceSelection {
    private static var isTTY: Bool {
        isatty(FileHandle.standardInput.fileDescriptor) != 0
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Resolve `vm create`'s iPhone/cloudOS sources, prompting on a TTY for
    /// whichever component the user didn't pass, from `device`'s builds (the
    /// iPhone list when nil). Non-interactive or fully specified → returns the
    /// inputs unchanged for caller validation.
    static func resolve(iphone: String?, cloudos: String?, device: String? = nil) throws -> VPhoneFirmwareSources {
        try VPhoneFirmwarePicker.resolve(
            iphone: iphone,
            cloudos: cloudos,
            device: device,
            isInteractive: isTTY,
            read: { readLine(strippingNewline: true) },
            write: { err($0) },
        )
    }

    // MARK: Version Selectors

    /// The compatibility guide whose Tested Environments table rates each build.
    static func compatibilityGuide(_ resources: VPhoneResources) -> String {
        let source = resources.base.appendingPathComponent("Documents/Guides/compatibility.md")
        let bundle = resources.base.appendingPathComponent("docs/guides/compatibility.md")
        return FileManager.default.fileExists(atPath: source.path) ? source.path : bundle.path
    }

    /// The device whose IPSWs a version selector looks up: a device without an
    /// IPSW lists and resolves its restore base's.
    static func lookupDevice(_ device: String?) -> String {
        VPhoneGuestDevice.named(device)?.restoreBase?.productType ?? device ?? VPhoneFirmwareCatalog.device
    }

    static func restoreURLs(forDevice device: String) throws -> String {
        try vphoneRunBlocking {
            try await VPhoneFirmwareIndex.restoreURLs(forDevice: device)
        }.joined(separator: "\n")
    }

    /// The downloadable IPSW `--iphone-version`/`--iphone-build` select.
    static func release(
        device: String,
        version: String?,
        build: String?,
        readme: String,
        downloadURLs: String,
    ) throws -> VPhoneFirmwareRelease {
        let selection = VPhoneFirmwareMatrix.selection(
            device: device,
            version: version ?? "",
            build: build ?? "",
            readme: try? String(contentsOfFile: readme, encoding: .utf8),
            downloadURLs: downloadURLs,
            style: .forStream(FileHandle.standardError.fileDescriptor),
        )
        switch selection {
        case let .selected(release, _): return release
        case let .ambiguous(message), let .unmatched(message):
            throw ValidationError(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
