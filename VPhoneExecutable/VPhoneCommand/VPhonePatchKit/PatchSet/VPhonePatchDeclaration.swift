// VPhonePatchDeclaration.swift — One selectable patch, as its set declares it.
//
// The identifier is the contract. It is the prefix of the ``PatchRecord``
// identifiers the patch emits, so a patch writing four records under
// `kernel-boot-cred_label_update_execve.*` declares one identifier and is selected or
// blocked as a unit — a half-applied patch of that shape would not boot.

import Foundation

public struct VPhonePatchDeclaration: Sendable, Hashable, Codable, Identifiable {
    /// Stable selection identity, and the record-identifier prefix.
    public var identifier: String
    /// Short label for a preset picker. One line, no trailing period.
    public var title: String
    /// What the patch does and why the guest needs it.
    public var summary: String
    /// What the patch writes to.
    public var target: VPhonePatchTarget
    /// The OS pairings the patch applies to.
    public var applicability: VPhonePatchApplicability
    /// True when the guest does not boot without this patch.
    ///
    /// Blocking one is allowed — that is how an external set replaces it — but
    /// every caller that offers a choice says so first, and the resolver reports
    /// which essentials a plan dropped.
    public var bootEssential: Bool

    public var id: String {
        identifier
    }

    public init(
        identifier: String,
        title: String,
        summary: String = "",
        target: VPhonePatchTarget,
        applicability: VPhonePatchApplicability = .always,
        bootEssential: Bool = false,
    ) {
        self.identifier = identifier
        self.title = title
        self.summary = summary
        self.target = target
        self.applicability = applicability
        self.bootEssential = bootEssential
    }

    private enum CodingKeys: String, CodingKey {
        case identifier = "Identifier"
        case title = "Title"
        case summary = "Summary"
        case target = "Target"
        case applicability = "Applicability"
        case bootEssential = "BootEssential"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        guard !identifier.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: container,
                debugDescription: "A patch identifier is what a preset names; it cannot be empty",
            )
        }
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        target = try container.decode(VPhonePatchTarget.self, forKey: .target)
        applicability = try container.decodeIfPresent(
            VPhonePatchApplicability.self,
            forKey: .applicability,
        ) ?? .always
        bootEssential = try container.decodeIfPresent(Bool.self, forKey: .bootEssential) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(title, forKey: .title)
        if !summary.isEmpty {
            try container.encode(summary, forKey: .summary)
        }
        try container.encode(target, forKey: .target)
        if applicability != .always {
            try container.encode(applicability, forKey: .applicability)
        }
        if bootEssential {
            try container.encode(bootEssential, forKey: .bootEssential)
        }
    }
}

public extension VPhonePatchDeclaration {
    /// Whether `recordIdentifier` came from this patch.
    ///
    /// A record either is the declaration itself or sits under it as
    /// `<identifier>.<site>` — `kernel-boot-kcall10.sy_call`,
    /// `llb-boot-rootfs.cbz_0x3b7`. Only a dot separates a site: identifiers
    /// are snake_case and contain underscores, so an underscore suffix would
    /// let `kernel-boot-sandbox_mount_check_mount` cover a different patch
    /// that happens to extend its name. A bare textual prefix does not match
    /// either, so `kernel-cfw-debuggerless` is not a site of `kernel-cfw-debugger`.
    func covers(recordIdentifier record: String) -> Bool {
        record == identifier
            || record.hasPrefix(identifier + ".")
    }
}
