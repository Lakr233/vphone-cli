// FirmwarePipelineComponents.swift — Ordered boot-chain component list per variant.
//
// Owns the catalogue half of the pipeline: which firmware components are patched,
// in which order, where their files are searched for, and which patchers run over
// each one for the selected ``FirmwarePipeline/Variant``.
//
// Split out of FirmwarePipeline.swift; the execution loop stays there.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

extension FirmwarePipeline {
    // MARK: - Component List Builder

    /// Build the ordered component list based on the variant.
    ///
    /// - Parameters:
    ///   - restoreDir: The `*Restore*` directory `patchAll()` resolved, captured by value
    ///     into the patcher factory closures below.
    ///   - iOSBase: The iPhone base `ProductVersion` read from `iPhone-BuildManifest.plist`,
    ///     or nil when it could not be read. Two patchers still branch on the release
    ///     itself rather than on a patch being selected: the skywalk-netagent boot-arg is
    ///     18.x-only, and `KernelCustomFirmwarePatcher.applyIOS27` changes the shapes a patch
    ///     method looks for rather than whether it runs.
    ///   - plan: The resolved preset, or nil when there is none. A patcher whose whole
    ///     patch set the preset left out is not built at all: its records would be
    ///     declared by nothing, and an undeclared record applies rather than being
    ///     dropped (see ``VPhonePatchGate``), so leaving the set out has to mean
    ///     leaving the patcher out.
    ///   - gate: Handed to each patcher built below, so a blocked patch is never written.
    func buildComponentList(
        restoreDir: URL,
        iOSBase: VPhoneVersion?,
        plan: VPhonePatchPlan? = nil,
        gate: VPhonePatchGate = .unrestricted,
    ) throws -> [ComponentDescriptor] {
        var components: [ComponentDescriptor] = []

        // Whether the plan kept a bundled set. True when there is no plan, so a
        // directly built pipeline runs every patcher its variant names.
        func includesSet(_ identifier: String) -> Bool {
            plan?.includesPatchSet(identifier) ?? true
        }

        let includeBootChain = includesSet(FirmwareBootChainPatchSet.identifier)

        // Whether the plan turns on any patch for a boot chain component. A
        // preset that keeps the set for some components only (`minimal`: iBEC and
        // LLB) leaves the others stock, and a patcher built to write nothing
        // would only log that it found nothing.
        func patchesBootChain(_ component: VPhoneFirmwareComponent) -> Bool {
            guard includeBootChain else { return false }
            guard let plan else { return true }
            return plan.declarations.contains { $0.target == .firmware(component) && plan.isEnabled($0.identifier) }
        }
        let includeKernelBase = includesSet(FirmwareKernelBasePatchSet.identifier)
        let includeKernelCustomFirmware = includesSet(FirmwareKernelCustomFirmwarePatchSet.identifier)
        let includeDeviceTree = includesSet(FirmwareDeviceTreePatchSet.identifier)

        // A guest that presents its board boots a device tree of its own (7b),
        // and an iPad needs LLB to give it the iPad's display scale (4).
        let guestDevice = readGuestDevice(restoreDir)
        let guestTreeURL = restoreDir.appending(path: FirmwareManifest.guestDeviceTreePath)
        let hasGuestTree = guestDevice.presentsBoard && FileManager.default.fileExists(atPath: guestTreeURL.path)
        let boardTreeURL = restoreDir.appending(path: guestDevice.boardDeviceTreePath)

        // Whether the plan turned a patch on. Without a plan, fall back to the
        // release the patch is pinned to, which is the same answer the standard
        // preset gives.
        func isEnabled(_ identifier: String, fallback: Bool) -> Bool {
            plan?.isEnabled(identifier) ?? fallback
        }

        // The hypervisor concealment. Its set holds this one patch, so the patcher
        // goes when the patch does — the gate would refuse the write anyway, but a
        // patcher built to write nothing is a patcher whose log lines lie.
        // `standard` blocks it: see FirmwareKernelHypervisorPatchSet.
        let includeHypervisor = includesSet(FirmwareKernelHypervisorPatchSet.identifier)
            && isEnabled("kernel-exp-hv_vmm", fallback: false)

        let baseIs18 = iOSBase?.major == 18
        let baseIs27 = iOSBase?.major == 27
        let cloudIs264 = cloudOSProductVersion?.major == 26 && cloudOSProductVersion?.minor == 4

        // The Mach port guard disable. Pinned to iOS 18, whose runningboardd and
        // SpringBoard trip GUARD_TYPE_MACH_PORT flavor 10 and crash-loop the UI —
        // the VM does not boot there without it. On 26.x and 27.x it only hides
        // violations, so it is off unless a VM checks it on.
        let applyExcGuard = isEnabled("kernel-boot-thread_guard_violation", fallback: baseIs18)

        // Not a selection: `applyIOS27` changes which shapes the JB patch methods
        // look for, and which sandbox hook is left real for the fpfs trampoline.
        // It follows the base release, and the gate decides separately whether each
        // of those patches is written.
        let applyIOS27 = baseIs27

        // The AppleSEPKeyStore keybag-unlock external method began sending
        // inputScalarCount == 5 in iOS 26.6 (26.5 and earlier send 4), so a
        // 26.6-or-newer userland needs the count-5 acceptance patch on the
        // 26.4-kernel hybrid — not just a 27 base. The patch's anchor self-guards
        // on a kernel that already accepts 5, so no cloudOS condition is needed.
        let applyAksUnlockBag5 = baseIs27
            || (iOSBase?.major == 26 && (iOSBase?.minor ?? 0) >= 6)

        // Frida Stalker relaxations, off unless the VM asked for them. Their own
        // cloudOS 26.4+ gate decides whether they then land.
        let applyFrida = FirmwareKernelFridaPatchSet.manifest.patches.contains {
            isEnabled($0.identifier, fallback: false)
        }

        // ProMotion, the 120 Hz display timing: on in `standard`, on every base.
        let applyProMotion = isEnabled(FirmwarePatchSetCatalog.proMotionPatch, fallback: true)
        // The paravirtual user-client allowlist, on in `standard` and pinned to the
        // 26.x and 18.x bases (27 opens the whole gate instead).
        let applyParavirtUserClients = isEnabled(
            FirmwarePatchSetCatalog.paravirtUserClientsPatch,
            fallback: baseIs18 || iOSBase?.major == 26,
        )

        // iOS 18 bases: disable the skywalk flowswitch netagents via boot-arg so
        // Network.framework uses the BSD path (the 26.1-kernel skywalk
        // channel-create traps in the 18.x Network.framework and crash-loops
        // mDNSResponder → no DNS). Empty on 26.x bases (stock boot-args).
        let extraBootArgs = (baseIs18 || iOSBase?.major == 17) ? "if_attach_nx=0x3" : ""

        // 1. AVPBooter — Apple's ROM, in the VM root. Patched when the plan keeps
        //    the boot chain set. A machine booting OpenAVB has nothing
        //    here to patch: OpenAVB checks no image digest, so the digest
        //    bypass the plan selects already holds, and an Apple ROM kept in
        //    the folder beside it is not the one that boots.
        if VPhoneBootROM.kind(ofMachineAt: vmDirectory) != .openAVB {
            components.append(ComponentDescriptor(
                name: "AVPBooter",
                inRestoreDir: false,
                searchPatterns: ["AVPBooter*.bin"],
                patcherFactories: {
                    if patchesBootChain(.avpBooter) {
                        return [
                            { data, verbose in
                                let p = AVPBooterPatcher(data: data, verbose: verbose)
                                p.gate = gate
                                return p
                            },
                        ]
                    }
                    return []
                }(),
            ))
        }

        // 2. iBSS — JB and EXP variants run the base iBSS patcher, then the nonce-skip extension.
        components.append(ComponentDescriptor(
            name: "iBSS",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
            patcherFactories: {
                switch variant {
                case .regular, .dev:
                    patchesBootChain(.iBSS) ? [{ data, verbose in
                        let p = IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                        p.gate = gate
                        return p
                    }] : []
                case .jb, .exp:
                    patchesBootChain(.iBSS) ? [
                        { data, verbose in
                            let p = IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                            p.gate = gate
                            return p
                        },
                        { data, verbose in
                            let p = IBootCustomFirmwarePatcher(data: data, mode: .ibss, verbose: verbose)
                            p.gate = gate
                            return p
                        },
                    ] : []
                }
            }(),
        ))

        // 3. iBEC
        components.append(ComponentDescriptor(
            name: "iBEC",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"],
            patcherFactories: patchesBootChain(.iBEC) ? [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .ibec, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                p.gate = gate
                return p
            }] : [],
        ))

        // 4. LLB
        components.append(ComponentDescriptor(
            name: "LLB",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
            patcherFactories: patchesBootChain(.llb) ? [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .llb, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                // The boot video word always says 3x, which is already right
                // for an iPhone board.
                p.displayScale = hasGuestTree && guestDevice.screen.scale != 3 ? UInt16(guestDevice.screen.scale) : nil
                p.gate = gate
                return p
            }] : [],
        ))

        // 5. TXM — dev/jb/exp variants use TXMDevPatcher (adds entitlements, debugger, dev-mode)
        components.append(ComponentDescriptor(
            name: "TXM",
            inRestoreDir: true,
            searchPatterns: ["Firmware/txm.iphoneos.research.im4p"],
            patcherFactories: {
                switch variant {
                case .regular:
                    patchesBootChain(.txm) ? [{ data, verbose in
                        let p = TXMPatcher(data: data, verbose: verbose)
                        p.gate = gate
                        return p
                    }] : []
                case .dev, .jb, .exp:
                    patchesBootChain(.txm) ? [{ data, verbose in
                        let p = TXMDevPatcher(data: data, verbose: verbose)
                        p.gate = gate
                        return p
                    }] : []
                }
            }(),
        ))

        // 6. Restore ramdisk and trust cache
        let sealPatch = RestoreRamDiskSealPatcher.patchIdentifier
        let includeSealPatch = includeBootChain
            && isEnabled(sealPatch, fallback: baseIs27 && cloudIs264)
            && !notApplicablePatches.contains(sealPatch)
        let manifestURL = restoreDir.appendingPathComponent("BuildManifest.plist")
        // Empty factories restore both originals when the patch is disabled.
        let includeSealComponents = includeSealPatch || (baseIs27 && cloudIs264)
        if includeSealComponents {
            // Catalogue-only tests have no restore tree.
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let ramdiskPath = try Self.manifestComponentPath("RestoreRamDisk", in: restoreDir)
                let trustCachePath = try Self.manifestComponentPath("RestoreTrustCache", in: restoreDir)
                let sealContext = RestoreRamDiskSealPatchContext()
                components.append(ComponentDescriptor(
                    name: VPhoneFirmwareComponent.restoreRamDisk.rawValue,
                    inRestoreDir: true,
                    searchPatterns: [ramdiskPath],
                    patcherFactories: includeSealPatch ? [{ data, verbose in
                        let patcher = RestoreRamDiskSealPatcher(
                            data: data,
                            context: sealContext,
                            verbose: verbose,
                        )
                        patcher.gate = gate
                        return patcher
                    }] : [],
                ))
                components.append(ComponentDescriptor(
                    name: VPhoneFirmwareComponent.restoreTrustCache.rawValue,
                    inRestoreDir: true,
                    searchPatterns: [trustCachePath],
                    patcherFactories: includeSealPatch ? [{ data, verbose in
                        let patcher = RestoreTrustCacheSealPatcher(
                            data: data,
                            context: sealContext,
                            verbose: verbose,
                        )
                        patcher.gate = gate
                        return patcher
                    }] : [],
                ))
            }
        }

        // 7. Kernel — the public CFW firmware includes the former EXP
        //    hv_vmm rename after the base and custom-firmware patches.
        //    On a cloudOS without vphone600 components the research board's
        //    kernelcache has no iPhone virtualisation kexts: its release kernel
        //    is rebuilt with them first (KernelCacheMixer), and the patchers
        //    run over that.
        let kernelMixPatch = FirmwareResearchBoardPatchSet.kernelMix
        let mixesKernel = includesSet(FirmwareResearchBoardPatchSet.identifier)
            && isEnabled(kernelMixPatch, fallback: true)
            && !notApplicablePatches.contains(kernelMixPatch)
        let restoreKernelPath = try? Self.manifestComponentPath("RestoreKernelCache", in: restoreDir)
        let kernelMix: (() throws -> (container: Data, record: PatchRecord))? = mixesKernel ? { [self] in
            guard let restoreKernelPath else {
                throw PatcherError.fileNotFound("RestoreKernelCache in the restore tree's BuildManifest.plist")
            }
            // As shipped: the stash once a run has put it aside.
            let shipped = try Data(contentsOf: pristineInput(for: restoreDir.appending(path: restoreKernelPath)).url)
            let mixer = try KernelCacheMixer(recipes: .locate(), verbose: verbose)
            let input = KernelCacheMixer.Input(kernelcache: shipped, guest: guestDevice.family.rawValue, restoreTree: restoreDir)
            let base = try mixer.base(for: input)
            let record = PatchRecord(
                patchID: kernelMixPatch,
                component: "kernelcache",
                fileOffset: 0,
                virtualAddress: nil,
                originalBytes: Data(),
                patchedBytes: Data(),
                description: "the \(base.id) research board kernelcache, rebuilt with the kexts of \(base.donors.joined(separator: " and "))",
            )
            return try (mixer.mix(input), record)
        } : nil
        components.append(ComponentDescriptor(
            name: "kernelcache",
            inRestoreDir: true,
            searchPatterns: [(try? Self.manifestComponentPath("KernelCache", in: restoreDir)) ?? "kernelcache.research.vphone600"],
            patcherFactories: {
                switch variant {
                case .regular:
                    includeKernelBase ? [{ data, verbose in
                        let p = KernelPatcher(
                            data: data,
                            verbose: verbose,
                            isDev: false,
                            applyExcGuard: applyExcGuard,
                        )
                        p.gate = gate
                        return p
                    }] : []
                case .dev:
                    includeKernelBase ? [{ data, verbose in
                        let p = KernelPatcher(data: data, verbose: verbose, isDev: true)
                        p.gate = gate
                        return p
                    }] : []
                case .jb, .exp:
                    kernelCustomFirmwareFactories(
                        applyExcGuard: applyExcGuard,
                        applyIOS27: applyIOS27,
                        applyAksUnlockBag5: applyAksUnlockBag5,
                        applyFrida: applyFrida,
                        applyProMotion: applyProMotion,
                        applyTVTPROPagers: isEnabled(FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers, fallback: false),
                        applyParavirtUserClients: applyParavirtUserClients,
                        applyParavirtTask3: isEnabled(FirmwarePatchSetCatalog.paravirtTask3Patch, fallback: false),
                        includeBase: includeKernelBase,
                        includeCustomFirmware: includeKernelCustomFirmware,
                        includeHypervisor: includeHypervisor,
                        gate: gate,
                    )
                }
            }(),
            replacement: kernelMix,
        ))

        // 7a. The kernel restore boots. On a cloudOS without vphone600 components
        //     it is the mix as well, with no patcher over it; vphone600's release
        //     kernel is restored as shipped and needs no component.
        if includesSet(FirmwareResearchBoardPatchSet.identifier),
           Self.researchBoardStandsIn(restoreDir: restoreDir),
           let restoreKernelPath
        {
            components.append(ComponentDescriptor(
                name: "RestoreKernelCache",
                inRestoreDir: true,
                searchPatterns: [restoreKernelPath],
                patcherFactories: [],
                replacement: kernelMix,
            ))
        }

        // 8. DeviceTree — JB includes the former EXP identity and camera
        //    properties so the guest presents a consistent iPhone17,3 identity.
        //    A guest that presents its board restores with this tree and boots
        //    its own copy (7b).
        //    The tree is vphone600's, or the research board's on a cloudOS
        //    without vphone600 components, which the patcher converts first
        //    (FirmwareResearchBoardPatchSet). `RestoreDeviceTree` names it either
        //    way; `DeviceTree` names the board's copy (7b). A tree whose manifest
        //    names none (catalogue tests) keeps vphone600's.
        let dtIncludeIdentity = variant == .jb || variant == .exp
        let convertsResearchBoard = includesSet(FirmwareResearchBoardPatchSet.identifier)
            && !notApplicablePatches.contains(FirmwareResearchBoardPatchSet.deviceTreeConversion)
        let deviceTreePath = (try? Self.manifestComponentPath("RestoreDeviceTree", in: restoreDir))
            ?? "Firmware/all_flash/DeviceTree.vphone600ap.im4p"
        components.append(ComponentDescriptor(
            name: "DeviceTree",
            inRestoreDir: true,
            searchPatterns: [deviceTreePath],
            patcherFactories: includeDeviceTree ? [{ data, verbose in
                let p = DeviceTreePatcher(
                    data: data,
                    verbose: verbose,
                    includeIdentityPatches: dtIncludeIdentity,
                    device: guestDevice,
                    role: hasGuestTree ? .restore : .shared,
                )
                p.gate = gate
                p.convertsResearchBoard = convertsResearchBoard
                return p
            }] : [],
        ))

        // 8b. The board's installed DeviceTree, which `fw prepare` split off so
        //     it can carry the board identity through restore.
        if hasGuestTree {
            components.append(ComponentDescriptor(
                name: "GuestDeviceTree",
                inRestoreDir: true,
                searchPatterns: [FirmwareManifest.guestDeviceTreePath],
                patcherFactories: includeDeviceTree ? [{ data, verbose in
                    let p = try DeviceTreePatcher(
                        data: data,
                        verbose: verbose,
                        includeIdentityPatches: dtIncludeIdentity,
                        device: guestDevice,
                        role: .installed,
                        // Read through the originals stash, which keeps a copy: the
                        // restore tree goes once the VM boots, and `cfw install` and
                        // the environment update take the board's audio node from it.
                        sourceTree: self.loader.load(from: self.pristineInput(for: boardTreeURL).url),
                    )
                    p.gate = gate
                    p.convertsResearchBoard = convertsResearchBoard
                    return p
                }] : [],
            ))
        }

        // 8c. SEP — only the research board's is patched, on a cloudOS without
        //     vphone600 components (FirmwareResearchBoardPatchSet). vphone600's is
        //     restored as Apple ships it.
        let sepPatch = FirmwareResearchBoardPatchSet.sepDispatch
        if includesSet(FirmwareResearchBoardPatchSet.identifier),
           Self.researchBoardStandsIn(restoreDir: restoreDir)
        {
            components.append(ComponentDescriptor(
                name: VPhoneFirmwareComponent.sep.rawValue,
                inRestoreDir: true,
                searchPatterns: [try Self.manifestComponentPath("RestoreSEP", in: restoreDir)],
                patcherFactories: isEnabled(sepPatch, fallback: true) ? [{ data, verbose in
                    let p = SEPResearchBoardPatcher(data: data, verbose: verbose)
                    p.gate = gate
                    return p
                }] : [],
            ))
        }

        // 9. Filesystem — the restore image (`minimal` preset): the merged, resealed
        //    OS image the restore installs instead of a patched boot chain.
        //    Not restorable: it reads BuildManifest.plist but writes cryptex images
        //    all over the restore tree, so putting the manifest back on its own
        //    would describe a tree that no longer exists. See ComponentDescriptor.
        let includeRestoreImage = includesSet(FirmwareRestoreImagePatchSet.identifier)
        let applyCryptexMerge = includeRestoreImage
            && isEnabled(FirmwareRestoreImagePatchSet.cryptexMerge, fallback: false)
        components.append(ComponentDescriptor(
            name: "Filesystem",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: applyCryptexMerge ? [{ data, verbose in
                let p = CryptexFilesystemPatcher(
                    buildManiest: data,
                    restoreDir: restoreDir,
                    verbose: verbose,
                    noBinpack: self.noBinpack,
                )
                p.gate = gate
                return p
            }] : [],
            restorable: false,
        ))

        // 10. Firmware Manifest — the digests of whatever the restore image changed,
        //    so the stock boot chain accepts it.
        //    Not restorable, for the same reason as Filesystem: the hashes it writes
        //    describe files other steps produced, not the manifest's own bytes.
        let applyDigestRehash = includeRestoreImage
            && isEnabled(FirmwareRestoreImagePatchSet.digestRehash, fallback: false)
        components.append(ComponentDescriptor(
            name: "Manifest",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: applyDigestRehash ? [{ data, verbose in
                ManifestHashPatcher(data: data, restoreDir: restoreDir, verbose: verbose)
            }] : [],
            restorable: false,
        ))

        return appendingExternalPatchers(to: components, plan: plan, gate: gate, iOSBase: iOSBase)
    }

    // MARK: - External Patch Sets

    /// Give every loaded `.vphonepatchset` its turn on each component.
    ///
    /// A no-op unless the preset named an external set, which no shipped preset
    /// does. The manifest decides which components a set is asked about, so this
    /// never invents work for a set whose patches are off.
    private func appendingExternalPatchers(
        to components: [ComponentDescriptor],
        plan: VPhonePatchPlan?,
        gate: VPhonePatchGate,
        iOSBase: VPhoneVersion?,
    ) -> [ComponentDescriptor] {
        guard let plan, !loadedPatchSets.isEmpty else { return components }
        let context = VPhonePatchSetContext(
            iOSBase: iOSBase,
            cloudOS: cloudOSProductVersion,
            gate: gate,
            parameters: plan.parameters,
            verbose: verbose,
        )
        return components.map { descriptor in
            guard let component = VPhoneFirmwareComponent(rawValue: descriptor.name) else {
                return descriptor
            }
            return descriptor.appending(
                loadedPatchSets.factories(for: component, plan: plan, context: context),
            )
        }
    }

    // MARK: - Kernel Factories

    /// The kernelcache patcher chain the CFW and EXP variants share.
    ///
    /// Each patcher corresponds to one bundled patch set, and a set the preset
    /// left out drops its patcher rather than being filtered afterwards.
    private func kernelCustomFirmwareFactories(
        applyExcGuard: Bool,
        applyIOS27: Bool,
        applyAksUnlockBag5: Bool,
        applyFrida: Bool,
        applyProMotion: Bool,
        applyTVTPROPagers: Bool,
        applyParavirtUserClients: Bool,
        applyParavirtTask3: Bool,
        includeBase: Bool,
        includeCustomFirmware: Bool,
        includeHypervisor: Bool,
        gate: VPhonePatchGate,
    ) -> [(Data, Bool) throws -> any Patcher] {
        var factories: [(Data, Bool) throws -> any Patcher] = []
        if includeBase {
            factories.append { data, verbose in
                let p = KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                p.gate = gate
                return p
            }
        }
        if includeCustomFirmware {
            factories.append { data, verbose in
                let p = KernelCustomFirmwarePatcher(data: data, verbose: verbose)
                p.applyIOS27 = applyIOS27
                p.applyAksUnlockBag5 = applyAksUnlockBag5
                p.applyFrida = applyFrida
                p.applyProMotion = applyProMotion
                p.applyTVTPROPagers = applyTVTPROPagers
                p.applyParavirtUserClients = applyParavirtUserClients
                p.applyParavirtTask3 = applyParavirtTask3
                p.gate = gate
                return p
            }
        }
        if includeHypervisor {
            factories.append { data, verbose in
                let p = KernelExperimentalPatcher(data: data, verbose: verbose)
                p.gate = gate
                return p
            }
        }
        return factories
    }
}
