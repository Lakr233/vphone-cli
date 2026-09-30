// PatchSetModelTests.swift — The manifest, preset and resolver model.
//
// These tests use small hand-made manifests rather than the shipped catalogue, so
// they pin the rules themselves: what a version gate means, what a plist round trip
// must preserve, and which disagreements between patch sets are errors rather than
// a silent choice. `FirmwarePatchSetCatalogTests` then checks the real catalogue
// against those rules.

import Foundation
import Testing
import VPhonePatchKit

// MARK: - Versions

@Suite("Version requirements")
struct VPhoneVersionRequirementTests {
    @Test
    func `A product version splits into major, minor and patch`() {
        #expect(VPhoneVersion("27")?.major == 27)
        #expect(VPhoneVersion("27")?.minor == 0)
        #expect(VPhoneVersion("26.4")?.minor == 4)
        #expect(VPhoneVersion("18.6.2")?.patch == 2)
        // A version nothing could read is nil rather than zero, so it cannot
        // accidentally satisfy a gate that names a real release.
        #expect(VPhoneVersion(nil) == nil)
        #expect(VPhoneVersion("") == nil)
        #expect(VPhoneVersion("26.x") == nil)
        #expect(VPhoneVersion("1.2.3.4") == nil)
    }

    @Test
    func `Trailing zeros do not change a version`() throws {
        #expect(VPhoneVersion("27") == VPhoneVersion("27.0"))
        #expect(VPhoneVersion("27.0") == VPhoneVersion("27.0.0"))
        #expect(try #require(VPhoneVersion("26.4")) < VPhoneVersion("26.4.1")!)
    }

    @Test
    func `Each requirement matches exactly the releases it names`() {
        let eighteen = VPhoneVersion("18.6.2")
        let twentySixZero = VPhoneVersion("26.0")
        let twentySixFour = VPhoneVersion("26.4")
        let twentySeven = VPhoneVersion("27.0")

        #expect(VPhoneVersionRequirement.any.matches(nil))
        #expect(VPhoneVersionRequirement.major(18).matches(eighteen))
        #expect(!VPhoneVersionRequirement.major(18).matches(twentySeven))

        #expect(VPhoneVersionRequirement.release(major: 26, minor: 0).matches(twentySixZero))
        #expect(!VPhoneVersionRequirement.release(major: 26, minor: 0).matches(twentySixFour))

        #expect(VPhoneVersionRequirement.atLeast(major: 26, minor: 4).matches(twentySixFour))
        #expect(VPhoneVersionRequirement.atLeast(major: 26, minor: 4).matches(twentySeven))
        #expect(!VPhoneVersionRequirement.atLeast(major: 26, minor: 4).matches(twentySixZero))

        let either = VPhoneVersionRequirement.oneOf([.release(major: 26, minor: 0), .major(18)])
        #expect(either.matches(twentySixZero))
        #expect(either.matches(eighteen))
        #expect(!either.matches(twentySixFour))
    }

    @Test
    func `A version gate never matches an unreadable version`() {
        // The one case that must not fail open: a patch pinned to a release must
        // not apply when nothing knows which release this is.
        for requirement: VPhoneVersionRequirement in [
            .major(27),
            .release(major: 26, minor: 4),
            .atLeast(major: 18, minor: 0),
            .oneOf([.major(18), .major(27)]),
        ] {
            #expect(!requirement.matches(nil))
        }
    }

    @Test
    func `A requirement survives a plist round trip`() throws {
        let cases: [VPhoneVersionRequirement] = [
            .any,
            .major(27),
            .release(major: 26, minor: 0),
            .atLeast(major: 26, minor: 4),
            .oneOf([.major(18), .release(major: 26, minor: 0)]),
        ]
        for requirement in cases {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode([requirement])
            let decoded = try PropertyListDecoder().decode([VPhoneVersionRequirement].self, from: data)
            #expect(decoded == [requirement])
        }
    }

    @Test
    func `An empty OneOf is refused, because it would match nothing`() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array><dict>
        <key>Kind</key><string>OneOf</string>
        <key>Options</key><array/>
        </dict></array></plist>
        """
        #expect(throws: (any Error).self) {
            try PropertyListDecoder().decode(
                [VPhoneVersionRequirement].self,
                from: Data(plist.utf8),
            )
        }
    }
}

// MARK: - Selection

@Suite("Patch selection")
struct VPhonePatchSelectionTests {
    @Test
    func `All, allow and block each answer for a patch nobody named`() {
        #expect(VPhonePatchSelection.all.includes("anything"))
        #expect(VPhonePatchSelection.allow(["a"]).includes("a"))
        #expect(!VPhonePatchSelection.allow(["a"]).includes("b"))
        #expect(!VPhonePatchSelection.block(["a"]).includes("a"))
        #expect(VPhonePatchSelection.block(["a"]).includes("b"))
    }

    @Test
    func `Unchecking a box narrows every kind of selection`() {
        #expect(VPhonePatchSelection.all.blocking(["a"]) == .block(["a"]))
        #expect(VPhonePatchSelection.allow(["a", "b"]).blocking(["a"]) == .allow(["b"]))
        #expect(VPhonePatchSelection.block(["a"]).blocking(["b"]) == .block(["a", "b"]))
        // Blocking nothing is not a change.
        #expect(VPhonePatchSelection.allow(["a"]).blocking([]) == .allow(["a"]))
    }

    @Test
    func `Checking a box widens every kind of selection`() {
        #expect(VPhonePatchSelection.all.allowing(["a"]) == .all)
        #expect(VPhonePatchSelection.allow(["a"]).allowing(["b"]) == .allow(["a", "b"]))
        #expect(VPhonePatchSelection.block(["a", "b"]).allowing(["a"]) == .block(["b"]))
    }

    @Test
    func `A selection survives a plist round trip`() throws {
        for selection: VPhonePatchSelection in [.all, .allow(["a", "b"]), .block(["c"])] {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode([selection])
            #expect(try PropertyListDecoder().decode([VPhonePatchSelection].self, from: data) == [selection])
        }
    }
}

// MARK: - Declarations

@Suite("Patch declarations")
struct VPhonePatchDeclarationTests {
    private func declaration(_ identifier: String) -> VPhonePatchDeclaration {
        VPhonePatchDeclaration(identifier: identifier, title: identifier, target: .firmware(.kernelcache))
    }

    @Test
    func `A declaration covers its own record and its per-site records`() {
        let kcall = declaration("kernel-boot-kcall10")
        #expect(kcall.covers(recordIdentifier: "kernel-boot-kcall10"))
        #expect(kcall.covers(recordIdentifier: "kernel-boot-kcall10.sy_call"))

        let rootfs = declaration("llb-boot-rootfs")
        #expect(rootfs.covers(recordIdentifier: "llb-boot-rootfs.cbz_0x3b7"))
        let sandbox = declaration("kernel-boot-sandbox_ext")
        #expect(sandbox.covers(recordIdentifier: "kernel-boot-sandbox_ext.267"))
    }

    @Test
    func `Only a dot starts a site`() {
        // Names are snake_case, so an underscore continues the name: covering
        // `_` suffixes would let `sandbox_ext` claim a sibling `sandbox_ext_2`.
        let sandbox = declaration("kernel-boot-sandbox_ext")
        #expect(!sandbox.covers(recordIdentifier: "kernel-boot-sandbox_ext_267"))
        #expect(!sandbox.covers(recordIdentifier: "kernel-boot-sandbox_ext_2"))
        #expect(sandbox.covers(recordIdentifier: "kernel-boot-sandbox_ext.2"))
    }

    @Test
    func `A bare textual prefix is not a site`() {
        let debugger = declaration("kernel-cfw-debugger")
        #expect(!debugger.covers(recordIdentifier: "kernel-cfw-debuggerless"))
        #expect(!debugger.covers(recordIdentifier: "kernel-cfw-debug"))
    }

    @Test
    func `A declaration survives a plist round trip, including its target`() throws {
        let cases: [VPhonePatchTarget] = [
            .firmware(.kernelcache),
            .dyldSharedCache,
            .prebootDeviceTree,
            .guestExecutable(path: "/usr/libexec/seputil"),
            .guestEntitlements(path: "/sbin/launchd"),
            .guestFile(path: "/usr/local/bin/vphoned"),
        ]
        for target in cases {
            let patch = VPhonePatchDeclaration(
                identifier: "x.y",
                title: "X",
                summary: "why",
                target: target,
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
                bootEssential: true,
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode([patch])
            #expect(try PropertyListDecoder().decode([VPhonePatchDeclaration].self, from: data) == [patch])
        }
    }

    @Test
    func `A guest path must be absolute inside the guest`() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array><dict>
        <key>Kind</key><string>GuestExecutable</string>
        <key>Path</key><string>usr/libexec/seputil</string>
        </dict></array></plist>
        """
        #expect(throws: (any Error).self) {
            try PropertyListDecoder().decode([VPhonePatchTarget].self, from: Data(plist.utf8))
        }
    }
}

// MARK: - Resolver

@Suite("Plan resolution")
struct VPhonePatchPlanTests {
    private func patch(
        _ identifier: String,
        applicability: VPhonePatchApplicability = .always,
        bootEssential: Bool = false,
    ) -> VPhonePatchDeclaration {
        VPhonePatchDeclaration(
            identifier: identifier,
            title: identifier,
            target: .firmware(.kernelcache),
            applicability: applicability,
            bootEssential: bootEssential,
        )
    }

    private func set(
        _ identifier: String,
        patches: [VPhonePatchDeclaration],
        requires: [String] = [],
        provides: [String] = [],
        conflictsWith: [String] = [],
        after: [String] = [],
        minimumPatchKitVersion: VPhoneVersion = VPhoneVersion(major: 1),
    ) -> VPhonePatchSetManifest {
        VPhonePatchSetManifest(
            identifier: identifier,
            name: identifier,
            minimumPatchKitVersion: minimumPatchKitVersion,
            patches: patches,
            requires: requires,
            provides: provides,
            conflictsWith: conflictsWith,
            after: after,
        )
    }

    private func preset(
        _ sets: [String],
        selection: VPhonePatchSelection = .all,
    ) -> VPhonePatchPreset {
        VPhonePatchPreset(
            identifier: "test",
            title: "Test",
            patchSets: sets.map { .bundled($0) },
            selection: selection,
        )
    }

    @Test
    func `A resolved plan turns on what the selection and the version gate agree on`() throws {
        let sets = [set("a", patches: [
            patch("always"),
            patch("only27", applicability: VPhonePatchApplicability(iOSBase: .major(27))),
            patch("blocked"),
        ])]
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["a"], selection: .block(["blocked"])),
            patchSets: sets,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(plan.enabled == ["always"])
        // A patch that is off and a patch that does not apply here stay
        // distinguishable, so a log can say which happened.
        #expect(plan.skippedByVersion == ["only27"])
        #expect(!plan.isEnabled("blocked"))
        #expect(!plan.isEnabled("only27"))
    }

    @Test
    func `A VM's own boxes compose onto the preset`() throws {
        let sets = [set("a", patches: [patch("one"), patch("two"), patch("three")])]
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["a"], selection: .block(["two", "three"])),
            patchSets: sets,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
            blocked: ["one"],
            allowed: ["two"],
        )
        #expect(plan.enabled == ["two"])
    }

    @Test
    func `Checking a box cannot defeat a version gate`() throws {
        let sets = [set("a", patches: [
            patch("only27", applicability: VPhonePatchApplicability(iOSBase: .major(27))),
        ])]
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["a"], selection: .block(["only27"])),
            patchSets: sets,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
            allowed: ["only27"],
        )
        #expect(plan.enabled.isEmpty)
        #expect(plan.skippedByVersion == ["only27"])
    }

    @Test
    func `A record maps back to the declaration that owns it`() throws {
        let sets = [set("a", patches: [patch("kernel-cfw-sandbox"), patch("kernel-cfw-sandbox.mount_check_mount")])]
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["a"], selection: .allow(["kernel-cfw-sandbox"])),
            patchSets: sets,
            iOSBase: nil,
            cloudOS: nil,
        )
        // The longest matching declaration wins, so a record is attributed to the
        // most specific patch that claims it.
        #expect(
            plan.declaration(coveringRecord: "kernel-cfw-sandbox.mount_check_mount")?.identifier
                == "kernel-cfw-sandbox.mount_check_mount",
        )
        #expect(plan.isRecordEnabled("kernel-cfw-sandbox.file_check_mmap"))
        #expect(!plan.isRecordEnabled("kernel-cfw-sandbox.mount_check_mount"))
        // A record no declaration covers is not enabled by this plan; the gate,
        // not the plan, decides that it applies anyway.
        #expect(!plan.isRecordEnabled("something.else"))
    }

    @Test
    func `A preset naming an absent set is an error`() {
        #expect(throws: VPhonePatchPlanError.unknownPatchSet(preset: "test", patchSet: "b")) {
            try VPhonePatchPlan.resolve(
                preset: preset(["b"]),
                patchSets: [set("a", patches: [patch("one")])],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `A selection naming a patch nothing declares is an error`() {
        // The point of checking: a typo in a prewritten preset would otherwise be
        // an allow list that turns nothing on, or a block list that blocks nothing.
        #expect(throws: VPhonePatchPlanError.unknownPatch(preset: "test", identifier: "typo")) {
            try VPhonePatchPlan.resolve(
                preset: preset(["a"], selection: .block(["typo"])),
                patchSets: [set("a", patches: [patch("one")])],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `Two sets declaring the same patch is an error`() {
        #expect(throws: (any Error).self) {
            try VPhonePatchPlan.resolve(
                preset: preset(["a", "b"]),
                patchSets: [
                    set("a", patches: [patch("shared")]),
                    set("b", patches: [patch("shared")]),
                ],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `An unmet requirement is an error`() {
        #expect(throws: VPhonePatchPlanError.missingRequirement(patchSet: "b", capability: "cap.a")) {
            try VPhonePatchPlan.resolve(
                preset: preset(["b"]),
                patchSets: [
                    set("a", patches: [patch("one")], provides: ["cap.a"]),
                    set("b", patches: [patch("two")], requires: ["cap.a"]),
                ],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `A conflict is an error from either side`() throws {
        let a = set("a", patches: [patch("one")], provides: ["cap.a"])
        let bDeclares = set("b", patches: [patch("two")], conflictsWith: ["cap.a"])
        let bSilent = set("b", patches: [patch("two")], provides: ["cap.b"])
        let aDeclares = set("a", patches: [patch("one")], provides: ["cap.a"], conflictsWith: ["cap.b"])

        // The newer set names the older one.
        #expect(throws: (any Error).self) {
            try VPhonePatchPlan.resolve(
                preset: preset(["a", "b"]),
                patchSets: [a, bDeclares],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
        // And the other way round, so a set need not be patched to learn about a
        // rival that came later.
        #expect(throws: (any Error).self) {
            try VPhonePatchPlan.resolve(
                preset: preset(["a", "b"]),
                patchSets: [aDeclares, bSilent],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `A set needing a newer PatchKit is refused`() {
        #expect(throws: (any Error).self) {
            try VPhonePatchPlan.resolve(
                preset: preset(["a"]),
                patchSets: [set(
                    "a",
                    patches: [patch("one")],
                    minimumPatchKitVersion: VPhoneVersion(major: 99),
                )],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `After puts the sets in order, and a cycle is an error`() throws {
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["c", "b", "a"]),
            patchSets: [
                set("a", patches: [patch("one")], provides: ["cap.a"]),
                set("b", patches: [patch("two")], provides: ["cap.b"], after: ["cap.a"]),
                set("c", patches: [patch("three")], after: ["cap.b"]),
            ],
            iOSBase: nil,
            cloudOS: nil,
        )
        #expect(plan.patchSets.map(\.identifier) == ["a", "b", "c"])

        #expect(throws: (any Error).self) {
            try VPhonePatchPlan.resolve(
                preset: preset(["a", "b"]),
                patchSets: [
                    set("a", patches: [patch("one")], provides: ["cap.a"], after: ["cap.b"]),
                    set("b", patches: [patch("two")], provides: ["cap.b"], after: ["cap.a"]),
                ],
                iOSBase: nil,
                cloudOS: nil,
            )
        }
    }

    @Test
    func `A blocked boot-essential patch is reported, not refused`() throws {
        // Blocking one is allowed: that is how an external set replaces it. It
        // must never be quiet, though.
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["a"], selection: .block(["vital"])),
            patchSets: [set("a", patches: [patch("vital", bootEssential: true), patch("other")])],
            iOSBase: nil,
            cloudOS: nil,
        )
        #expect(plan.droppedBootEssentials == ["vital"])
        #expect(plan.enabled == ["other"])
    }

    @Test
    func `A plan knows whether a component has anything left to do`() throws {
        let sets = [VPhonePatchSetManifest(
            identifier: "a",
            name: "a",
            patches: [
                VPhonePatchDeclaration(identifier: "k", title: "k", target: .firmware(.kernelcache)),
                VPhonePatchDeclaration(identifier: "d", title: "d", target: .firmware(.deviceTree)),
            ],
        )]
        let plan = try VPhonePatchPlan.resolve(
            preset: preset(["a"], selection: .block(["d"])),
            patchSets: sets,
            iOSBase: nil,
            cloudOS: nil,
        )
        #expect(plan.hasEnabledPatches(target: .firmware(.kernelcache)))
        #expect(!plan.hasEnabledPatches(target: .firmware(.deviceTree)))
    }
}

// MARK: - Gate

@Suite("Patch gate")
struct VPhonePatchGateTests {
    @Test
    func `An unrestricted gate applies everything`() {
        let gate = VPhonePatchGate.unrestricted
        #expect(gate.isUnrestricted)
        #expect(gate.allows(record: "anything"))
        #expect(!gate.isUndeclared(record: "anything"))
    }

    @Test
    func `A gate answers about record identifiers, not just declarations`() {
        let gate = VPhonePatchGate(
            declared: ["kernel-boot-kcall10", "kernel-boot-sandbox_ext"],
            enabled: ["kernel-boot-kcall10"],
        )
        #expect(gate.allows(record: "kernel-boot-kcall10.sy_call"))
        #expect(!gate.allows(record: "kernel-boot-sandbox_ext.267"))
    }

    @Test
    func `An undeclared record applies, and says so`() {
        // Dropping bytes over a missing declaration would change the firmware
        // silently. Applying it and flagging the gap is the safer failure.
        let gate = VPhonePatchGate(declared: ["known"], enabled: [])
        #expect(gate.isUndeclared(record: "brand.new.patch"))
        #expect(gate.allows(record: "brand.new.patch"))
        #expect(!gate.isUndeclared(record: "known"))
        #expect(!gate.allows(record: "known"))
    }

    @Test
    func `The longest declaration owns a record`() {
        let gate = VPhonePatchGate(
            declared: ["kernel-cfw-sandbox", "kernel-cfw-sandbox.mount_check_mount"],
            enabled: ["kernel-cfw-sandbox"],
        )
        #expect(!gate.allows(record: "kernel-cfw-sandbox.mount_check_mount"))
        #expect(gate.allows(record: "kernel-cfw-sandbox.file_check_mmap"))
    }
}
