import ArgumentParser
import Foundation
import Testing
import VPhonePatchKit
@testable import VPhoneArchiveKit
@testable import VPhoneCommandKit
@testable import VPhoneCoreKit

/// `VPhoneVirtualMachineCreator` for the creates that need no restore and no
/// guest: a clone from a frozen template, every refusal before a template is
/// built, and the failure of a build at its first real step. Every test uses
/// a library, user-data folder and ROMs of its own, so nothing under the real
/// `~/.vphone` is touched.
private let creatorHostIsNested = VPhoneVirtualMachineCreator.isNestedVMHost()

final class CreatorLab {
    let dir: TempDir
    let library: VPhoneLibrary
    let userData: URL
    let roms: (rom: URL, seprom: URL)
    var creator: VPhoneVirtualMachineCreator

    init() throws {
        dir = try TempDir("creator")
        library = VPhoneLibrary(root: dir.url.appendingPathComponent("machines"))
        userData = dir.url.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        roms = try OfflineFixtures.writeROMs(in: dir.url)
        creator = VPhoneVirtualMachineCreator(library: library, resources: VPhoneResources.resolve(), launcher: nil)
        creator.userDataRoot = userData
        creator.romSource = roms.rom
        creator.sepromSource = roms.seprom
    }

    deinit { dir.cleanUp() }

    func key(
        series: String = VPhoneMachineTemplateKeys.currentSeries,
        slimming: VPhoneMachineTemplateSlimming = .none,
    ) throws -> VPhoneMachineTemplateKey {
        let preset = try #require(VPhonePatchPresetStore.preset(named: VPhonePatchPreset.standardIdentifier))
        return try VPhoneMachineTemplateKeys.key(
            device: "iPhone17,3", ios: OfflineFixtures.fixtureIOS, cloudOS: OfflineFixtures.fixtureCloudOS,
            preset: preset, diskSizeGB: 1, series: series, slimming: slimming,
        )
    }

    /// A frozen template for `key`: a real, never-booted machine adopted into `.templates`.
    @discardableResult
    func makeTemplate(_ key: VPhoneMachineTemplateKey, source: String = "tplsrc") throws -> VPhoneMachineTemplate {
        _ = try dir.makeBundle(name: source)
        return try VPhoneMachineTemplates.adopt(machineNamed: source, in: library, record: VPhoneMachineTemplateRecord(key: key))
    }

    func options(
        _ name: String,
        template: VPhoneVirtualMachineCreator.TemplateUse,
        configure: (inout VPhoneVirtualMachineCreator.Options) -> Void = { _ in },
    ) -> VPhoneVirtualMachineCreator.Options {
        var options = VPhoneVirtualMachineCreator.Options(
            name: name,
            ipswCacheDirectory: dir.url.appendingPathComponent("cache"),
            diskSizeGB: 1,
            template: template,
            skipsFirstBoot: true,
            slimming: .none,
        )
        configure(&options)
        return options
    }

    func machineNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }
}

private func creatorRefusal(_ body: () throws -> Void) -> String? {
    do { try body() } catch let error as ValidationError { return error.message } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    return nil
}

struct CreatorTemplateCloneTests {
    @Test("a clone from a named template is a new ordinary machine with this create's settings and ROMs")
    func cloneByIdentifier() throws {
        let lab = try CreatorLab()
        let template = try lab.makeTemplate(lab.key())
        try lab.creator.run(lab.options("clone", template: .identifier(template.identifier)) {
            $0.cpuCount = 4
            $0.memoryMB = 4096
            $0.networkMode = .tunnel
            $0.unlocksAtStartup = true
        })

        let clone = try lab.library.bundle(named: "clone")
        #expect(clone.manifest.cpuCount == 4)
        #expect(clone.manifest.memorySize == 4096 * 1024 * 1024)
        #expect(clone.manifest.networkConfig.mode == .tunnel)
        #expect(clone.manifest.unlocksScreenAtStartup == true)
        // The template's ROMs were Apple's; the clone gets this create's.
        #expect(clone.manifest.romImages?.avpBooter == "OpenAVB.bin")
        #expect(clone.manifest.romImages?.avpSEPBooter == "OpenSEP.bin")
        #expect(try Data(contentsOf: clone.url.appendingPathComponent("OpenAVB.bin")) == Data("OpenBootROM: fixture".utf8))
        #expect(try Data(contentsOf: clone.url.appendingPathComponent("OpenSEP.bin")) == Data([0x5E, 0x9]))
        // Where it came from, and not a template itself.
        let source = try #require(VPhoneMachineTemplates.readSource(inBundle: clone.url))
        #expect(source.identifier == template.identifier)
        #expect(source.build == template.record.build)
        #expect(try VPhoneMachineTemplates.readRecord(inBundle: clone.url) == nil)
        // The template is untouched and still frozen.
        #expect(try VPhoneMachineTemplates.template(template.identifier, in: lab.library).record.frozen)
        #expect(lab.machineNames() == ["clone"])
    }

    @Test("an identifier is also found by a unique prefix")
    func cloneByPrefix() throws {
        let lab = try CreatorLab()
        let template = try lab.makeTemplate(lab.key())
        try lab.creator.run(lab.options("clone", template: .identifier(String(template.identifier.prefix(6)))))
        #expect(try VPhoneMachineTemplates.readSource(inBundle: lab.library.bundle(named: "clone").url)?.identifier == template.identifier)
    }

    @Test("options the template cannot give are refused with every conflict, and nothing is created")
    func conflicts() throws {
        let lab = try CreatorLab()
        let key = try lab.key()
        let template = try lab.makeTemplate(key)
        var thrown: (any Error)?
        do {
            try lab.creator.run(lab.options("clone", template: .identifier(template.identifier)) {
                $0.templateRequest = VPhoneMachineTemplateRequest(device: "iPad16,1", patchPreset: "other", diskSizeGB: 8)
            })
        } catch { thrown = error }
        #expect(thrown as? VPhoneMachineTemplateError == .conflicts(identifier: template.identifier, options: [
            "--device iPad16,1: the template's guest is iPhone17,3",
            "--preset other: the template was built with \(key.patchPreset)",
            "--disk-size 8: the template's disk is 1 GB, fixed by its restore",
        ]))
        #expect(lab.machineNames().isEmpty)
    }

    @Test("a stale template that was named is used anyway")
    func staleNamedTemplate() throws {
        let lab = try CreatorLab()
        let template = try lab.makeTemplate(lab.key(series: "0.1"))
        #expect(!VPhoneMachineTemplateKeys.staleReasons(template).isEmpty)
        try lab.creator.run(lab.options("clone", template: .identifier(template.identifier)))
        #expect(lab.machineNames() == ["clone"])
    }

    @Test("an unknown template, a taken name and invalid names are refused before anything is made")
    func refusals() throws {
        let lab = try CreatorLab()
        let template = try lab.makeTemplate(lab.key())
        let id = template.identifier

        var thrown: (any Error)?
        do { try lab.creator.run(lab.options("clone", template: .identifier("0123456789ab"))) } catch { thrown = error }
        #expect(thrown as? VPhoneMachineTemplateError == .notFound("0123456789ab"))

        _ = try lab.dir.makeBundle(name: "taken")
        do { try lab.creator.run(lab.options("taken", template: .identifier(id))) } catch { thrown = error }
        #expect(thrown as? VPhoneLibraryError == .alreadyExists(name: "taken"))
        #expect("\(try #require(thrown))" == "VM 'taken' already exists. Choose a different name.")

        for name in ["", "a/b", ".hidden"] {
            thrown = nil
            do { try lab.creator.run(lab.options(name, template: .identifier(id))) } catch { thrown = error }
            #expect(thrown as? VPhoneLibraryError == .invalidName(name))
        }
        #expect(lab.machineNames() == ["taken"])
    }

    @Test("a clone is removed when its ROMs cannot be installed, and the template is left alone")
    func cleanupOnFailure() throws {
        let lab = try CreatorLab()
        let template = try lab.makeTemplate(lab.key())
        lab.creator.romSource = lab.dir.url.appendingPathComponent("missing-rom.bin")
        #expect(throws: (any Error).self) {
            try lab.creator.run(lab.options("clone", template: .identifier(template.identifier)))
        }
        #expect(lab.machineNames().isEmpty)
        #expect(try VPhoneMachineTemplates.template(template.identifier, in: lab.library).record.frozen)

        // Same for the SEP ROM, which is installed second.
        lab.creator.romSource = lab.roms.rom
        lab.creator.sepromSource = lab.dir.url.appendingPathComponent("missing-sep.bin")
        #expect(throws: (any Error).self) {
            try lab.creator.run(lab.options("clone", template: .identifier(template.identifier)))
        }
        #expect(lab.machineNames().isEmpty)
        // And a retry with good ROMs succeeds: the failed name was not left taken.
        lab.creator.sepromSource = lab.roms.seprom
        try lab.creator.run(lab.options("clone", template: .identifier(template.identifier)))
        #expect(lab.machineNames() == ["clone"])
    }
}

@Suite(.enabled(if: !creatorHostIsNested))
struct CreatorAutomaticTemplateTests {
    private func sources(_ lab: CreatorLab) throws -> (phone: URL, cloud: URL) {
        try OfflineFixtures.writePair(in: lab.dir.url)
    }

    @Test("without both IPSW sources an automatic create is refused")
    func needsSources() throws {
        let lab = try CreatorLab()
        let text = "Specify both iPhone and cloudOS IPSW sources when running without a terminal."
        #expect(creatorRefusal { try lab.creator.run(lab.options("m", template: .automatic)) } == text)
        #expect(creatorRefusal { try lab.creator.run(lab.options("m", template: .automatic) { $0.iphoneSource = "/x" }) } == text)
        #expect(creatorRefusal { try lab.creator.run(lab.options("m", template: .automatic) { $0.cloudosSource = "/x" }) } == text)
        #expect(lab.machineNames().isEmpty)
    }

    @Test("a trim without the setup boot is refused before any IPSW is read")
    func trimNeedsSetupBoot() throws {
        let lab = try CreatorLab()
        let slimming = VPhoneMachineTemplateSlimming(trimTier: "standard/1/en", setupBoot: false)
        let text = creatorRefusal {
            try lab.creator.run(lab.options("m", template: .automatic) {
                $0.iphoneSource = "/nonexistent-phone.ipsw"
                $0.cloudosSource = "/nonexistent-cloud.ipsw"
                $0.slimming = slimming
            })
        }
        #expect(text == "Cannot build this template: \(slimming.problems.joined(separator: "; ")). Pass --trim none.")
        #expect(text?.hasPrefix("Cannot build this template: trim standard/1/en needs the setup boot") == true)
    }

    @Test("an existing template for the IPSWs' key is cloned, with no build and no download")
    func existingTemplateIsCloned() throws {
        let lab = try CreatorLab()
        let pair = try sources(lab)
        let template = try lab.makeTemplate(lab.key())
        try lab.creator.run(lab.options("clone", template: .automatic) {
            $0.iphoneSource = pair.phone.path
            $0.cloudosSource = pair.cloud.path
        })
        #expect(lab.machineNames() == ["clone"])
        #expect(try VPhoneMachineTemplates.readSource(inBundle: lab.library.bundle(named: "clone").url)?.identifier == template.identifier)
        // No second template was built.
        #expect(try VPhoneMachineTemplates.list(in: lab.library).templates.map(\.identifier) == [template.identifier])
        #expect(!FileManager.default.fileExists(atPath: lab.dir.url.appendingPathComponent("cache").path))
    }

    @Test("a template whose boot chain drifted from its receipt is refused as stale")
    func staleTemplateRefused() throws {
        let lab = try CreatorLab()
        let pair = try sources(lab)
        let template = try lab.makeTemplate(lab.key())
        let wanted = try OfflineFixtures.wantedBootChain()
        let missing = try #require(wanted.map(\.identifier).sorted().first)
        try VPhonePatchPresetStore.updateReceipt(forVM: template.url) { receipt in
            for part in Set(wanted.map(\.part)) {
                let live = wanted.filter { $0.part == part && $0.identifier != missing }.map(\.identifier)
                receipt.record(part, patches: live, writer: "restore", bundleVersion: nil)
            }
        }
        var thrown: (any Error)?
        do {
            try lab.creator.run(lab.options("clone", template: .automatic) {
                $0.iphoneSource = pair.phone.path
                $0.cloudosSource = pair.cloud.path
            })
        } catch { thrown = error }
        #expect(thrown as? VPhoneMachineTemplateError == .stale(
            identifier: template.identifier,
            reasons: ["boot-chain patches differ from its receipt: \(missing)"],
        ))
        #expect(lab.machineNames().isEmpty)
    }

    @Test("a build that fails at its first real step names the missing component and leaves its staging folder, no template and no machine")
    func buildFailureLeavesStaging() throws {
        let lab = try CreatorLab()
        let pair = try sources(lab)
        let key = try lab.key()
        var thrown: (any Error)?
        do {
            try lab.creator.run(lab.options("clone", template: .automatic) {
                $0.iphoneSource = pair.phone.path
                $0.cloudosSource = pair.cloud.path
            })
        } catch { thrown = error }
        let failure = try #require(thrown)
        let text = (failure as? LocalizedError)?.errorDescription ?? "\(failure)"
        #expect(text.hasPrefix("A firmware component is missing: "))
        #expect(text.contains("/cloudOS/Firmware/agx. Check that the IPSW is complete"))

        #expect(lab.machineNames().isEmpty)
        let listing = try VPhoneMachineTemplates.list(in: lab.library)
        #expect(listing.templates.isEmpty)
        #expect(listing.staging.count == 1)
        // The failed build is left for `vm template delete`, as the message says.
        let templates = VPhoneMachineTemplates.directory(in: lab.library)
        let left = try FileManager.default.contentsOfDirectory(atPath: templates.path).filter { $0.hasPrefix(".building-\(key.identifier)-") }
        #expect(left.count == 1)
        let stagingName = try #require(left.first)
        let staged = templates.appendingPathComponent(stagingName).appendingPathComponent(key.identifier)
        let recorded = try VPhoneMachineTemplates.readRecord(inBundle: staged)
        let record = try #require(recorded)
        #expect(!record.frozen)
        #expect(record.key == key)
        #expect(record.sourceMachine == "clone")
        #expect(record.sources == VPhoneMachineTemplateSources(iPhone: pair.phone.path, cloudOS: pair.cloud.path))
        // The half-built restore tree and merge folders were removed by the preparer.
        let entries = try FileManager.default.contentsOfDirectory(atPath: staged.path)
        #expect(!entries.contains { $0.contains("Restore") || $0.hasPrefix(".firmware-prepare") })
        #expect(entries.contains("OpenAVB.bin"))
    }

    @Test("--keep-artifacts with a template only warns; a non-iPhone source is refused with the fix")
    func keepArtifactsWarning() throws {
        let lab = try CreatorLab()
        let pair = try sources(lab)
        lab.creator.romSource = lab.roms.rom
        try lab.makeTemplate(lab.key())
        try lab.creator.run(lab.options("clone", template: .automatic) {
            $0.iphoneSource = pair.phone.path
            $0.cloudosSource = pair.cloud.path
            $0.keepArtifacts = true
        })
        #expect(lab.machineNames() == ["clone"])
        // A cloudOS image given as the iPhone source is the swapped-sources refusal.
        #expect(creatorRefusal {
            try lab.creator.run(lab.options("again", template: .automatic) {
                $0.iphoneSource = pair.cloud.path
                $0.cloudosSource = pair.phone.path
            })
        } == "The iPhone and cloudOS IPSWs are swapped: cloud.ipsw is a cloudOS IPSW and phone.ipsw is an iPhone IPSW. Swap the two sources, then try again.")
        #expect(lab.machineNames() == ["clone"])
    }
}

struct CreatorOptionsTests {
    @Test("the defaults are an independent 8 CPU, 8 GB, 64 GB machine on the standard preset, first boot included")
    func defaults() {
        let options = VPhoneVirtualMachineCreator.Options(name: "m")
        #expect(options.name == "m")
        #expect(options.cpuCount == 8)
        #expect(options.memoryMB == 8192)
        #expect(options.diskSizeGB == 64)
        #expect(options.patchPreset == VPhonePatchPreset.standardIdentifier)
        #expect(options.template == .none)
        #expect(!options.skipsFirstBoot)
        #expect(!options.keepArtifacts)
        #expect(options.iphoneSource == nil && options.cloudosSource == nil)
        #expect(options.bootstrapLayout == nil)
        #expect(options.templateRequest == VPhoneMachineTemplateRequest())
        #expect(VPhoneVirtualMachineCreator.templateSlimming(options) == options.slimming)
    }

    @Test("TemplateUse compares by case and identifier")
    func templateUse() {
        typealias Use = VPhoneVirtualMachineCreator.TemplateUse
        #expect(Use.identifier("a") == .identifier("a"))
        #expect(Use.identifier("a") != .identifier("b"))
        #expect(Use.automatic != .none)
    }
}
