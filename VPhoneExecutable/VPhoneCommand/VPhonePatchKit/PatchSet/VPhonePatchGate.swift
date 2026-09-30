// VPhonePatchGate.swift — What a patcher asks before it writes.
//
// A gate is the plan reduced to the one question a patch site has: do I apply?
// It is a value, not a reference, so a patcher can hold one without owning the
// plan, and it defaults to ``unrestricted`` — a patcher built directly, as the
// tests build them, behaves exactly as it did before gates existed.
//
// Gates answer about *record* identifiers, because that is what a patch site has
// in hand, and record identifiers are finer than declarations: one declaration
// covers `kernel-boot-kcall10.sy_call` and its three siblings. A record no declaration
// covers is a gap in a manifest, not a patch the user turned off, so the gate
// applies it and says so. Failing open keeps a missed declaration from silently
// changing the firmware; the warning is what makes the gap findable.

import Foundation

public struct VPhonePatchGate: Sendable, Hashable {
    private enum Policy: Sendable, Hashable {
        case unrestricted
        /// Declared identifiers, longest first, plus those that are enabled.
        case plan(declared: [String], enabled: Set<String>)
    }

    private let policy: Policy

    private init(policy: Policy) {
        self.policy = policy
    }

    /// Every patch applies. The default, and what a directly built patcher gets.
    public static let unrestricted = VPhonePatchGate(policy: .unrestricted)

    /// Only the plan's enabled patches apply.
    public init(plan: VPhonePatchPlan) {
        policy = .plan(
            // Longest first, so `kernel-boot-sandbox_mount_check_mount` is consulted
            // before a shorter declaration that also happens to cover the record.
            declared: plan.declarations.map(\.identifier).sorted { $0.count > $1.count },
            enabled: plan.enabled,
        )
    }

    /// Only these declarations exist, and only these are on. For tests, and for a
    /// caller that knows its own set without a preset in the way.
    public init(declared: Set<String>, enabled: Set<String>) {
        policy = .plan(declared: declared.sorted { $0.count > $1.count }, enabled: enabled)
    }

    /// Whether the patch declaring `identifier` is on.
    ///
    /// For a patch method that knows its own declared identifier. A method whose
    /// sites carry finer record identifiers asks ``allows(record:)`` instead.
    public func isEnabled(_ identifier: String) -> Bool {
        switch policy {
        case .unrestricted: true
        case let .plan(_, enabled): enabled.contains(identifier)
        }
    }

    /// Whether the site emitting `recordIdentifier` should be written.
    ///
    /// An undeclared record applies. See the file comment: a manifest gap must
    /// not change the output.
    public func allows(record recordIdentifier: String) -> Bool {
        switch policy {
        case .unrestricted:
            return true
        case let .plan(declared, enabled):
            guard let owner = Self.declaration(covering: recordIdentifier, in: declared) else {
                return true
            }
            return enabled.contains(owner)
        }
    }

    /// True when `recordIdentifier` belongs to no declaration, so ``allows(record:)``
    /// let it through only because failing open is safer than dropping it. The
    /// caller logs this; nothing else should depend on it.
    public func isUndeclared(record recordIdentifier: String) -> Bool {
        switch policy {
        case .unrestricted:
            false
        case let .plan(declared, _):
            Self.declaration(covering: recordIdentifier, in: declared) == nil
        }
    }

    /// True when the gate turns nothing off, so a caller can skip reporting.
    public var isUnrestricted: Bool {
        if case .unrestricted = policy {
            return true
        }
        return false
    }

    /// The same rules as ``VPhonePatchDeclaration/covers(recordIdentifier:)``,
    /// over a list already ordered longest first.
    private static func declaration(covering record: String, in declared: [String]) -> String? {
        declared.first {
            record == $0 || record.hasPrefix($0 + ".")
        }
    }
}
