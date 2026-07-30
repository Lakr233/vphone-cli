import Foundation

// MARK: - VPhoneFirmwarePickerError

public enum VPhoneFirmwarePickerError: Error, CustomStringConvertible, Equatable {
    case aborted
    case invalidSelection

    public var description: String {
        switch self {
        case .aborted: "firmware selection aborted"
        case .invalidSelection: "no valid firmware selection made"
        }
    }
}

// MARK: - VPhoneFirmwareSources

/// The resolved `fw prepare` sources — a URL or local path per component, or
/// nil to let `fw_prepare.sh` fall back to its built-in default.
public struct VPhoneFirmwareSources: Sendable, Equatable {
    public let iphoneSource: String?
    public let cloudosSource: String?
    public init(iphoneSource: String?, cloudosSource: String?) {
        self.iphoneSource = iphoneSource
        self.cloudosSource = cloudosSource
    }
}

// MARK: - VPhoneFirmwarePicker

public enum VPhoneFirmwarePicker {
    /// Resolve the iPhone/cloudOS sources for `vm create`, prompting only for
    /// what's missing. Both given → passthrough. Non-interactive → passthrough
    /// (fw_prepare defaults fill any gap). Neither given → pick a full pairing.
    /// One given → prompt for just the other. Prompts show friendly names; the
    /// result carries URLs. I/O is injected so the logic is unit-testable.
    public static func resolve(
        iphone: String?,
        cloudos: String?,
        isInteractive: Bool,
        maxRetries: Int = 5,
        read: () -> String?,
        write: (String) -> Void
    ) throws -> VPhoneFirmwareSources {
        let iphone = (iphone?.isEmpty == true) ? nil : iphone
        let cloudos = (cloudos?.isEmpty == true) ? nil : cloudos

        // Nothing to prompt for: both supplied, or we can't prompt anyway.
        if (iphone != nil && cloudos != nil) || !isInteractive {
            return VPhoneFirmwareSources(iphoneSource: iphone, cloudosSource: cloudos)
        }

        if iphone == nil, cloudos == nil {
            let p = try pickPairing(maxRetries: maxRetries, read: read, write: write)
            return VPhoneFirmwareSources(iphoneSource: p.iosURL, cloudosSource: p.cloudosURL)
        }
        if iphone == nil {   // cloudOS supplied, choose the iPhone build
            let p = try pickIPhone(maxRetries: maxRetries, read: read, write: write)
            return VPhoneFirmwareSources(iphoneSource: p.iosURL, cloudosSource: cloudos)
        }
        // iPhone supplied, choose the cloudOS image
        let c = try pickCloudOS(maxRetries: maxRetries, read: read, write: write)
        return VPhoneFirmwareSources(iphoneSource: iphone, cloudosSource: c.url)
    }

    // MARK: - Prompts

    static func pickPairing(
        maxRetries: Int, read: () -> String?, write: (String) -> Void
    ) throws -> VPhoneFirmwarePairing {
        let pairings = VPhoneFirmwareCatalog.pairings
        let w = pairings.map(\.iosName.count).max() ?? 0
        let idx = try choose(
            "Select a firmware pairing to download:",
            pairings.map { $0.iosName.padding(toLength: w, withPad: " ", startingAt: 0)
                + "  (→ \($0.cloudosName))" },
            maxRetries: maxRetries, read: read, write: write)
        let p = pairings[idx]
        write("→ \(p.iosName) + \(p.cloudosName)")
        return p
    }

    static func pickIPhone(
        maxRetries: Int, read: () -> String?, write: (String) -> Void
    ) throws -> VPhoneFirmwarePairing {
        let pairings = VPhoneFirmwareCatalog.pairings
        let idx = try choose(
            "Select an iPhone firmware to download:",
            pairings.map(\.iosName),
            maxRetries: maxRetries, read: read, write: write)
        let p = pairings[idx]
        write("→ \(p.iosName)")
        return p
    }

    static func pickCloudOS(
        maxRetries: Int, read: () -> String?, write: (String) -> Void
    ) throws -> VPhoneCloudOSOption {
        let options = VPhoneFirmwareCatalog.cloudOSOptions
        let idx = try choose(
            "Select a cloudOS firmware to download:",
            options.map(\.name),
            maxRetries: maxRetries, read: read, write: write)
        let c = options[idx]
        write("→ \(c.name)")
        return c
    }

    /// Show a numbered menu and read a 1-based index (mirrors VPhoneVMPicker).
    static func choose(
        _ prompt: String, _ labels: [String],
        maxRetries: Int, read: () -> String?, write: (String) -> Void
    ) throws -> Int {
        write(prompt)
        let iw = String(labels.count).count   // right-align indices so labels start in one column
        for (i, label) in labels.enumerated() {
            let n = String(i + 1)
            let padded = String(repeating: " ", count: iw - n.count) + n
            write("  [\(padded)] \(label)")
        }
        for _ in 0..<maxRetries {
            write("Enter number: ")
            guard let line = read() else { throw VPhoneFirmwarePickerError.aborted }
            let choice = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if choice.isEmpty { continue }
            if let n = Int(choice), n >= 1, n <= labels.count { return n - 1 }
            write("  '\(choice)' is not a valid selection.")
        }
        throw VPhoneFirmwarePickerError.invalidSelection
    }
}
