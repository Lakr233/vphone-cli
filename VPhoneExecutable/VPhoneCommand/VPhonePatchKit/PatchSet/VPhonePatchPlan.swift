// VPhonePatchPlan.swift — Resolving a preset into the patches that will run.
//
// The resolver is the only place that decides whether a patch applies, and it
// decides once, before anything is written. Every disagreement is an error
// rather than a silent choice: a conflict, an unmet requirement, a duplicate
// patch identifier and a name that matches nothing all stop the run. A plan that
// resolves is a plan whose every patch is accounted for.

import Foundation

public struct VPhonePatchPlan: Sendable, Hashable {
    /// The preset this plan came from.
    public let presetIdentifier: String
    /// The resolved sets, ordered so each runs after what it declared `After`.
    public let patchSets: [VPhonePatchSetManifest]
    /// The selection actually applied, preset plus any per-VM blocks.
    public let selection: VPhonePatchSelection
    /// The patch identifiers that will run.
    public let enabled: Set<String>
    /// Declared patches the selection kept but the OS pairing ruled out.
    /// Reported so a log can say "not applicable here" rather than nothing.
    public let skippedByVersion: Set<String>
    /// Boot-essential patches this plan leaves out, in set order. Empty for a
    /// plan whose guest is expected to boot unaided.
    public let droppedBootEssentials: [String]
    /// The preset's knobs, passed through to whichever set reads them.
    public let parameters: [String: String]

    /// Whether `identifier` — a declared patch identifier — runs.
    public func isEnabled(_ identifier: String) -> Bool {
        enabled.contains(identifier)
    }

    /// Whether the patch that emits `recordIdentifier` runs.
    ///
    /// Record identifiers are sometimes built at runtime (`kernel-boot-sandbox_ext.3`,
    /// `dyld-cfw-camera.<family>.<symbol>`), so this maps a record back to the
    /// declaration that owns it instead of matching the full string.
    public func isRecordEnabled(_ recordIdentifier: String) -> Bool {
        guard let declaration = declaration(coveringRecord: recordIdentifier) else { return false }
        return enabled.contains(declaration.identifier)
    }

    /// The declaration owning a record identifier, across every resolved set.
    public func declaration(coveringRecord recordIdentifier: String) -> VPhonePatchDeclaration? {
        for set in patchSets {
            if let declaration = set.declaration(coveringRecord: recordIdentifier) {
                return declaration
            }
        }
        return nil
    }

    /// Every declared patch across the resolved sets, in set then declared order.
    public var declarations: [VPhonePatchDeclaration] {
        patchSets.flatMap(\.patches)
    }

    /// Whether this plan turns on any patch aimed at `target`.
    ///
    /// The pipeline asks before it insists a component produced patches: a preset
    /// that turned everything off for one component leaves it legitimately
    /// untouched, which is different from a patcher failing to find its site.
    public func hasEnabledPatches(target: VPhonePatchTarget) -> Bool {
        declarations.contains { $0.target == target && enabled.contains($0.identifier) }
    }

    /// Whether the plan includes the set with this identifier.
    public func includesPatchSet(_ identifier: String) -> Bool {
        patchSets.contains { $0.identifier == identifier }
    }

    /// The declaration for an identifier, if any set declares it.
    public func declaration(for identifier: String) -> VPhonePatchDeclaration? {
        for set in patchSets {
            if let match = set.patches.first(where: { $0.identifier == identifier }) {
                return match
            }
        }
        return nil
    }
}

// MARK: - Errors

public enum VPhonePatchPlanError: Error, CustomStringConvertible, Sendable, Hashable {
    /// The preset names a set nothing supplied.
    case unknownPatchSet(preset: String, patchSet: String)
    /// Two resolved sets claim the same identity.
    case duplicatePatchSet(String)
    /// Two sets declare the same patch identifier, so a selection naming it
    /// would be ambiguous and both would write the same site.
    case duplicatePatch(identifier: String, patchSets: [String])
    /// A set needs a capability no resolved set provides.
    case missingRequirement(patchSet: String, capability: String)
    /// Two resolved sets declare they cannot sit together.
    case conflict(patchSet: String, with: String, over: String)
    /// The selection names a patch no resolved set declares.
    case unknownPatch(preset: String, identifier: String)
    /// A set needs a newer PatchKit than this framework is.
    case patchKitTooOld(patchSet: String, required: VPhoneVersion, available: VPhoneVersion)
    /// `After` declarations form a cycle, so no order satisfies them all.
    case cyclicOrder([String])

    public var description: String {
        switch self {
        case let .unknownPatchSet(preset, patchSet):
            "Preset \(preset) names patch set \(patchSet), which is not available"
        case let .duplicatePatchSet(identifier):
            "Patch set \(identifier) is resolved twice"
        case let .duplicatePatch(identifier, patchSets):
            "Patch \(identifier) is declared by more than one set: \(patchSets.joined(separator: ", "))"
        case let .missingRequirement(patchSet, capability):
            "Patch set \(patchSet) requires \(capability), which no selected set provides"
        case let .conflict(patchSet, other, capability):
            "Patch sets \(patchSet) and \(other) conflict over \(capability)"
        case let .unknownPatch(preset, identifier):
            "Preset \(preset) names patch \(identifier), which no selected set declares"
        case let .patchKitTooOld(patchSet, required, available):
            "Patch set \(patchSet) needs PatchKit \(required); this is \(available)"
        case let .cyclicOrder(identifiers):
            "Patch set ordering is cyclic: \(identifiers.joined(separator: " → "))"
        }
    }
}

// MARK: - Resolve

extension VPhonePatchPlan {
    /// Resolve a preset against the sets that were loaded for it.
    ///
    /// - Parameters:
    ///   - preset: The preset to resolve.
    ///   - patchSets: Every manifest available, looked up by identifier. The
    ///     caller loads these; an external reference is checked against the
    ///     identifier its manifest declares before it gets here.
    ///   - iOSBase: The iPhone base `ProductVersion`, or nil when unread.
    ///   - cloudOS: The cloudOS `ProductVersion`, or nil when unread.
    ///   - blocked: Patch identifiers this VM turned off on top of the preset.
    ///   - allowed: Patch identifiers this VM turned on that the preset left off.
    ///     Together these two are the VM's checkmark state. Neither touches the
    ///     version gate: a patch pinned to one OS release still applies only there,
    ///     however it was selected.
    ///   - patchKitVersion: The API version to check sets against.
    public static func resolve(
        preset: VPhonePatchPreset,
        patchSets available: [VPhonePatchSetManifest],
        iOSBase: VPhoneVersion?,
        cloudOS: VPhoneVersion?,
        blocked: Set<String> = [],
        allowed: Set<String> = [],
        patchKitVersion: VPhoneVersion = .currentPatchKit,
    ) throws -> VPhonePatchPlan {
        var byIdentifier: [String: VPhonePatchSetManifest] = [:]
        for set in available {
            guard byIdentifier.updateValue(set, forKey: set.identifier) == nil else {
                throw VPhonePatchPlanError.duplicatePatchSet(set.identifier)
            }
        }

        // 1. Every reference resolves, exactly once.
        var resolved: [VPhonePatchSetManifest] = []
        var seen = Set<String>()
        for reference in preset.patchSets {
            guard let set = byIdentifier[reference.identifier] else {
                throw VPhonePatchPlanError.unknownPatchSet(
                    preset: preset.identifier,
                    patchSet: reference.identifier,
                )
            }
            guard seen.insert(set.identifier).inserted else {
                throw VPhonePatchPlanError.duplicatePatchSet(set.identifier)
            }
            resolved.append(set)
        }

        // 2. This PatchKit is new enough for all of them.
        for set in resolved where set.minimumPatchKitVersion > patchKitVersion {
            throw VPhonePatchPlanError.patchKitTooOld(
                patchSet: set.identifier,
                required: set.minimumPatchKitVersion,
                available: patchKitVersion,
            )
        }

        // 3. No two sets declare the same patch. A replacement set gives its
        //    patch a new identifier and the preset blocks the original, so
        //    shadowing never has to be guessed at.
        var owner: [String: String] = [:]
        for set in resolved {
            for patch in set.patches {
                if let previous = owner[patch.identifier] {
                    throw VPhonePatchPlanError.duplicatePatch(
                        identifier: patch.identifier,
                        patchSets: [previous, set.identifier],
                    )
                }
                owner[patch.identifier] = set.identifier
            }
        }

        // 4. Capabilities: requirements met, and nothing conflicting present.
        //    A capability may have more than one provider, so every provider is
        //    recorded — ordering against only one of them would be a silent choice
        //    about which `After` meant.
        var capabilityProviders: [String: [String]] = [:]
        for set in resolved {
            for capability in set.capabilities.sorted() {
                capabilityProviders[capability, default: []].append(set.identifier)
            }
        }
        for set in resolved {
            for capability in set.requires where capabilityProviders[capability] == nil {
                throw VPhonePatchPlanError.missingRequirement(
                    patchSet: set.identifier,
                    capability: capability,
                )
            }
        }
        for set in resolved {
            for capability in set.conflictsWith {
                for other in capabilityProviders[capability] ?? [] where other != set.identifier {
                    throw VPhonePatchPlanError.conflict(
                        patchSet: set.identifier,
                        with: other,
                        over: capability,
                    )
                }
            }
        }

        // 5. Order by `After`, keeping the preset's listing order as the
        //    tie-break so a plan is reproducible.
        let ordered = try order(resolved, capabilityProviders: capabilityProviders)

        // 6. The selection must name only patches that exist, so a typo in a
        //    prewritten preset fails here instead of turning nothing on.
        let declared = Set(owner.keys)
        let selection = preset.selection.allowing(allowed).blocking(blocked)
        for identifier in preset.selection.namedIdentifiers.union(allowed).union(blocked)
            where !declared.contains(identifier)
        {
            throw VPhonePatchPlanError.unknownPatch(preset: preset.identifier, identifier: identifier)
        }

        // 7. Selection first, then the version gate, so a patch that is off and
        //    a patch that does not apply here stay distinguishable in the log.
        var enabled = Set<String>()
        var skippedByVersion = Set<String>()
        var droppedBootEssentials: [String] = []
        for set in ordered {
            for patch in set.patches {
                guard selection.includes(patch.identifier) else {
                    if patch.bootEssential {
                        droppedBootEssentials.append(patch.identifier)
                    }
                    continue
                }
                if patch.applicability.matches(iOSBase: iOSBase, cloudOS: cloudOS) {
                    enabled.insert(patch.identifier)
                } else {
                    skippedByVersion.insert(patch.identifier)
                }
            }
        }

        return VPhonePatchPlan(
            presetIdentifier: preset.identifier,
            patchSets: ordered,
            selection: selection,
            enabled: enabled,
            skippedByVersion: skippedByVersion,
            droppedBootEssentials: droppedBootEssentials,
            parameters: preset.parameters,
        )
    }

    /// Stable topological sort over `After`. A set whose `After` names something
    /// absent has nothing to wait for, so the edge is simply dropped.
    private static func order(
        _ sets: [VPhonePatchSetManifest],
        capabilityProviders: [String: [String]],
    ) throws -> [VPhonePatchSetManifest] {
        let position = Dictionary(uniqueKeysWithValues: sets.enumerated().map { ($0.element.identifier, $0.offset) })
        var predecessors: [String: Set<String>] = [:]
        var successors: [String: Set<String>] = [:]
        for set in sets {
            predecessors[set.identifier] = []
            successors[set.identifier] = []
        }
        for set in sets {
            for capability in set.after {
                for earlier in capabilityProviders[capability] ?? [] where earlier != set.identifier {
                    predecessors[set.identifier]?.insert(earlier)
                    successors[earlier]?.insert(set.identifier)
                }
            }
        }

        var ready = sets.filter { predecessors[$0.identifier]?.isEmpty ?? true }.map(\.identifier)
        var result: [VPhonePatchSetManifest] = []
        let byIdentifier = Dictionary(uniqueKeysWithValues: sets.map { ($0.identifier, $0) })
        while !ready.isEmpty {
            ready.sort { (position[$0] ?? 0) < (position[$1] ?? 0) }
            let next = ready.removeFirst()
            guard let set = byIdentifier[next] else { continue }
            result.append(set)
            for successor in (successors[next] ?? []).sorted() {
                predecessors[successor]?.remove(next)
                if predecessors[successor]?.isEmpty == true {
                    ready.append(successor)
                }
            }
            successors[next] = []
        }

        guard result.count == sets.count else {
            let placed = Set(result.map(\.identifier))
            throw VPhonePatchPlanError.cyclicOrder(
                sets.map(\.identifier).filter { !placed.contains($0) },
            )
        }
        return result
    }
}
