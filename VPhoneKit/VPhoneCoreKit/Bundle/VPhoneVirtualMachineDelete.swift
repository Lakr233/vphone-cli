import Foundation

// MARK: - VPhoneVirtualMachineDelete

/// Deletes a VM bundle and reports the template, if any, that no machine uses
/// once it is gone. It prints nothing and never prompts.
public enum VPhoneVirtualMachineDelete {
    public struct Result {
        public let name: String
        /// Never deleted here: another create may want it, and rebuilding it
        /// takes a restore.
        public let unusedTemplate: VPhoneMachineTemplate?

        /// The `note: template ...` line `vm delete` prints, nil when no
        /// template became unused.
        public var templateNote: String? {
            guard let template = unusedTemplate else { return nil }
            let size = VPhoneSystemTrim.formatBytes(VPhoneMachineTemplates.allocatedBytes(of: template.url))
            return "note: template \(template.identifier) (~\(size)) is no longer used by any machine; "
                + "remove it with `vphone-cli vm template delete \(template.identifier)`"
        }
    }

    /// With `refuseWhenRunning`, a running VM throws
    /// `VPhoneBundleActivityError.running` and nothing is removed.
    @discardableResult
    public static func delete(named name: String, in library: VPhoneLibrary, refuseWhenRunning: Bool = false) throws -> Result {
        let bundle = try library.bundle(named: name)
        if refuseWhenRunning {
            try VPhoneBundleActivity.requireStopped(bundle)
        }
        let source = VPhoneMachineTemplates.readSource(inBundle: bundle.url)
        try VPhoneBundleOperations.delete(bundleNamed: name, in: library)
        return Result(name: name, unusedTemplate: VPhoneMachineTemplates.unusedTemplate(after: source, in: library))
    }
}
