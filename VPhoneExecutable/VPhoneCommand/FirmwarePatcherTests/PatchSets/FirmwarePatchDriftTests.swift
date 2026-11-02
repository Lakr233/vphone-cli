// FirmwarePatchDriftTests.swift — What a restore records, and what a change still needs.
//
// `FirmwarePatchDrift` is the rule `restore`, `fw patches` and `fw set-patches`
// share. These pin it on small hand-made declarations, plus the bundled
// catalogue where the rule depends on what ships.

import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Patch drift")
struct FirmwarePatchDriftTests {
    private func patch(
        _ identifier: String,
        _ target: VPhonePatchTarget,
        applicability: VPhonePatchApplicability = .always,
    ) -> VPhonePatchDeclaration {
        VPhonePatchDeclaration(identifier: identifier, title: identifier, target: target, applicability: applicability)
    }

    /// The receipt's part rule, restated so the tests do not reach into the CLI.
    private func part(_ target: VPhonePatchTarget) -> String {
        if case let .firmware(component) = target {
            return component.rawValue
        }
        return "Guest"
    }

    private var declarations: [VPhonePatchDeclaration] {
        [
            patch("avp", .firmware(.avpBooter)),
            patch("ibss", .firmware(.iBSS)),
            patch("llb", .firmware(.llb)),
            patch("kernel-a", .firmware(.kernelcache)),
            patch("kernel-b", .firmware(.kernelcache)),
            patch("txm", .firmware(.txm)),
            patch("ramdisk", .firmware(.restoreRamDisk)),
            patch("dyld", .dyldSharedCache),
            patch("dt", .prebootDeviceTree),
            patch("tree-node", .firmware(.deviceTree)),
        ]
    }

    // MARK: - Restore

    @Test
    func `A restore records every component it flashes, empty ones included`() {
        let parts = FirmwarePatchDrift.restoredParts(
            enabledPatches: ["avp", "ibss", "kernel-b", "kernel-a", "dyld"],
            declarations: declarations,
        )
        #expect(Set(parts.keys) == [.iBSS, .iBEC, .llb, .txm, .restoreRamDisk, .kernelcache, .deviceTree, .sep])
        #expect(parts[.iBSS] == ["ibss"])
        #expect(parts[.kernelcache] == ["kernel-a", "kernel-b"])
        // Off in the plan, or declaring nothing: recorded empty, not unknown.
        #expect(parts[.llb] == [])
        #expect(parts[.iBEC] == [])
        #expect(parts[.restoreRamDisk] == [])
        #expect(parts[.deviceTree] == [])
        // AVPBooter never leaves the VM folder, and guest patches are written
        // by cfw install, not by a restore.
        #expect(parts[.avpBooter] == nil)
        #expect(!parts.values.contains { $0.contains("dyld") })
    }

    @Test
    func `A restore of the bundled catalogue records only boot-chain patches`() {
        let everything = Set(FirmwarePatchSetCatalog.allDeclarations.map(\.identifier))
        let parts = FirmwarePatchDrift.restoredParts(enabledPatches: everything)
        let recorded = parts.values.flatMap(\.self)
        for identifier in recorded {
            let declaration = FirmwarePatchSetCatalog.allDeclarations.first { $0.identifier == identifier }
            guard case let .firmware(component)? = declaration?.target else {
                Issue.record("\(identifier) is not a boot-chain patch")
                continue
            }
            #expect(FirmwarePatchDrift.restoredComponents.contains(component))
        }
        #expect(parts[.kernelcache]?.isEmpty == false)
    }

    // MARK: - Wanted

    @Test
    func `A patch pinned to another release is not wanted, however it was selected`() {
        let gated = [
            patch("any", .firmware(.kernelcache)),
            patch("only27", .firmware(.kernelcache), applicability: VPhonePatchApplicability(iOSBase: .major(27))),
        ]
        let on26 = FirmwarePatchDrift.wantedPatches(
            selected: ["any", "only27"],
            declarations: gated,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(on26 == ["any"])
        let on27 = FirmwarePatchDrift.wantedPatches(
            selected: ["any", "only27"],
            declarations: gated,
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(on27 == ["any", "only27"])
        // With no version known there is nothing to gate against.
        let unknown = FirmwarePatchDrift.wantedPatches(
            selected: ["only27"],
            declarations: gated,
            iOSBase: nil,
            cloudOS: nil,
        )
        #expect(unknown == ["only27"])
    }

    // MARK: - States

    private func states(
        wanted: Set<String>,
        planned: Set<String>?,
        applied: [String: Set<String>]?,
        notApplicable: Set<String> = [],
        standIns: [String: String] = [:],
    ) -> [String: FirmwarePatchDrift.PatchState] {
        let list = FirmwarePatchDrift.states(
            declarations: declarations,
            wanted: wanted,
            planned: planned,
            applied: applied,
            notApplicable: notApplicable,
            standIns: standIns,
            part: part,
        )
        return Dictionary(uniqueKeysWithValues: list.map { ($0.identifier, $0) })
    }

    @Test
    func `A guest restored with a customised system takes kernel patches only by restore`() {
        // `cfw update-kernel` refuses a `minimal` guest, so a kernel patch it
        // turns on (userspace debugging) is delivered like the rest of its boot chain.
        let list = FirmwarePatchDrift.states(
            declarations: declarations,
            wanted: ["kernel-a", "dt"],
            planned: [],
            applied: nil,
            restoredCustomisedSystem: true,
            part: part,
        )
        let result = Dictionary(uniqueKeysWithValues: list.map { ($0.identifier, $0) })
        #expect(result["kernel-a"]?.isPending == true)
        #expect(result["kernel-a"]?.delivery == .restore)
        #expect(result["dt"]?.delivery == .updateEnvironment)
        #expect(FirmwarePatchDelivery(target: .firmware(.kernelcache)) == .updateKernel)
    }

    @Test
    func `No plan and no receipt leaves every patch unknown`() {
        let result = states(wanted: ["kernel-a"], planned: nil, applied: nil)
        #expect(result.values.allSatisfy { $0.planned == nil && $0.applied == nil && $0.isPending == nil })
    }

    @Test
    func `The receipt decides where it records the part, and the plan stands in elsewhere`() {
        let result = states(
            wanted: ["avp", "kernel-a", "dyld"],
            planned: ["avp", "kernel-a", "kernel-b", "dyld", "dt"],
            applied: ["kernelcache": ["kernel-a", "kernel-b"], "AVPBooter": ["avp"]],
        )
        // kernel-b was turned off after the restore put it in.
        #expect(result["kernel-b"]?.applied == true)
        #expect(result["kernel-b"]?.isPending == true)
        #expect(result["kernel-b"]?.delivery == .updateKernel)
        #expect(result["kernel-a"]?.isPending == false)
        #expect(result["avp"]?.isPending == false)
        // No Guest part in the receipt: the plan says what the install wrote.
        #expect(result["dt"]?.applied == nil)
        #expect(result["dt"]?.planned == true)
        #expect(result["dt"]?.isPending == true)
        #expect(result["dt"]?.delivery == .updateEnvironment)
        #expect(result["dyld"]?.isPending == false)
    }

    @Test
    func `A patch the guest has nothing for is never pending, on or off`() {
        let on = states(wanted: ["dt"], planned: ["dt"], applied: ["Guest": []], notApplicable: ["dt"])
        #expect(on["dt"]?.isPending == false)
        let off = states(wanted: [], planned: ["dt"], applied: ["Guest": []], notApplicable: ["dt"])
        #expect(off["dt"]?.isPending == false)
        // With no Guest part recorded, the plan still decides.
        let unknown = states(wanted: ["dt"], planned: [], applied: [:], notApplicable: ["dt"])
        #expect(unknown["dt"]?.isPending == true)
    }

    @Test
    func `A boot-chain patch whose Preboot stand-in is live is not pending`() {
        // Restored before the tree patch existed: the plan has no "tree-node",
        // but the Preboot repair "dt" put the same change into the guest.
        let live = states(
            wanted: ["tree-node", "dt"],
            planned: ["dt"],
            applied: ["Guest": ["dt"]],
            standIns: ["tree-node": "dt"],
        )
        #expect(live["tree-node"]?.applied == true)
        #expect(live["tree-node"]?.isPending == false)
        // Without the repair live, the tree patch still needs a restore.
        let missing = states(
            wanted: ["tree-node", "dt"],
            planned: ["dt"],
            applied: ["Guest": []],
            standIns: ["tree-node": "dt"],
        )
        #expect(missing["tree-node"]?.isPending == true)
        #expect(missing["tree-node"]?.delivery == .restore)
    }

    @Test
    func `Every Preboot stand-in names a declared Preboot repair and a declared tree patch`() {
        let byID = Dictionary(FirmwarePatchSetCatalog.allDeclarations.map { ($0.identifier, $0.target) }, uniquingKeysWith: { a, _ in a })
        for (treePatch, repair) in FirmwareGuestSystemPatchSet.prebootRepairs {
            #expect(byID[treePatch] == .firmware(.deviceTree), "\(treePatch)")
            #expect(byID[repair] == .prebootDeviceTree, "\(repair)")
        }
    }

    @Test
    func `A part recorded empty means off, not unknown`() {
        let result = states(
            wanted: ["llb"],
            planned: ["llb"],
            applied: ["LLB": []],
        )
        #expect(result["llb"]?.applied == false)
        #expect(result["llb"]?.isPending == true)
        #expect(result["llb"]?.delivery == .restore)
    }

    // MARK: - Delivery

    @Test
    func `Each target is delivered by the step that owns its bytes`() {
        #expect(FirmwarePatchDelivery(target: .firmware(.avpBooter)) == .firmwarePatch)
        #expect(FirmwarePatchDelivery(target: .firmware(.kernelcache)) == .updateKernel)
        for component in [VPhoneFirmwareComponent.iBSS, .iBEC, .llb, .txm, .deviceTree, .sep] {
            #expect(FirmwarePatchDelivery(target: .firmware(component)) == .restore)
        }
        let guest: [VPhonePatchTarget] = [
            .dyldSharedCache,
            .guestExecutable(path: "/usr/libexec/x"),
            .guestEntitlements(path: "/usr/libexec/x"),
            .guestFile(path: "/etc/x"),
            .prebootDeviceTree,
        ]
        for target in guest {
            #expect(FirmwarePatchDelivery(target: target) == .updateEnvironment)
        }
    }
}
