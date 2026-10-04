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
    ) -> [ComponentDescriptor] {
        var components: [ComponentDescriptor] = []

        /// Whether the plan kept a bundled set. True when there is no plan, so a
        /// directly built pipeline runs every patcher its variant names.
        func includesSet(_ identifier: String) -> Bool {
            plan?.includesPatchSet(identifier) ?? true
        }

        let includeBootChain = includesSet(FirmwareBootChainPatchSet.identifier)
        let includeKernelBase = includesSet(FirmwareKernelBasePatchSet.identifier)
        let includeKernelCustomFirmware = includesSet(FirmwareKernelCustomFirmwarePatchSet.identifier)
        let includeDeviceTree = includesSet(FirmwareDeviceTreePatchSet.identifier)

        // An iPad guest boots a device tree of its own (7b) and needs LLB to give
        // it the iPad's display scale (4).
        let guestDevice = readGuestDevice(restoreDir)
        let guestTreeURL = restoreDir.appending(path: FirmwareManifest.guestDeviceTreePath)
        let hasGuestTree = guestDevice.isPad && FileManager.default.fileExists(atPath: guestTreeURL.path)
        let boardTreeURL = restoreDir.appending(path: guestDevice.boardDeviceTreePath)

        /// Whether the plan turned a patch on. Without a plan, fall back to the
        /// release the patch is pinned to, which is the same answer the standard
        /// preset gives.
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

        // Frida Stalker relaxations, off unless the VM asked for them. Their own
        // cloudOS 26.4+ gate decides whether they then land.
        let applyFrida = FirmwareKernelFridaPatchSet.manifest.patches.contains {
            isEnabled($0.identifier, fallback: false)
        }

        // iOS 18 bases: disable the skywalk flowswitch netagents via boot-arg so
        // Network.framework uses the BSD path (the 26.1-kernel skywalk
        // channel-create traps in the 18.x Network.framework and crash-loops
        // mDNSResponder → no DNS). Empty on 26.x bases (stock boot-args).
        let extraBootArgs = baseIs18 ? "if_attach_nx=0x3" : ""

        // 1. AVPBooter — always present, lives in VM root.
        //    Patched for every non-less variant (regular/dev/jb/exp).
        components.append(ComponentDescriptor(
            name: "AVPBooter",
            inRestoreDir: false,
            searchPatterns: ["AVPBooter*.bin"],
            patcherFactories: {
                if variant != .less, includeBootChain {
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

        // 2. iBSS — JB and EXP variants run the base iBSS patcher, then the nonce-skip extension.
        components.append(ComponentDescriptor(
            name: "iBSS",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
            patcherFactories: {
                switch variant {
                case .less:
                    []
                case .regular, .dev:
                    includeBootChain ? [{ data, verbose in
                        let p = IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                        p.gate = gate
                        return p
                    }] : []
                case .jb, .exp:
                    includeBootChain ? [
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

        // 3. iBEC - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "iBEC",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"],
            patcherFactories: includeBootChain ? [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .ibec, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                p.gate = gate
                return p
            }] : [],
        ))

        // 4. LLB - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "LLB",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
            patcherFactories: includeBootChain ? [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .llb, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                p.displayScale = hasGuestTree ? UInt16(guestDevice.screen.scale) : nil
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
                case .less:
                    []
                case .regular:
                    includeBootChain ? [{ data, verbose in
                        let p = TXMPatcher(data: data, verbose: verbose)
                        p.gate = gate
                        return p
                    }] : []
                case .dev, .jb, .exp:
                    includeBootChain ? [{ data, verbose in
                        let p = TXMDevPatcher(data: data, verbose: verbose)
                        p.gate = gate
                        return p
                    }] : []
                }
            }(),
        ))

        // 6. Kernel — the public CFW firmware includes the former EXP
        //    hv_vmm rename after the base and custom-firmware patches.
        components.append(ComponentDescriptor(
            name: "kernelcache",
            inRestoreDir: true,
            searchPatterns: ["kernelcache.research.vphone600"],
            patcherFactories: {
                switch variant {
                case .less:
                    []
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
                        applyFrida: applyFrida,
                        includeBase: includeKernelBase,
                        includeCustomFirmware: includeKernelCustomFirmware,
                        includeHypervisor: includeHypervisor,
                        gate: gate,
                    )
                }
            }(),
        ))

        // 7. DeviceTree — JB includes the former EXP identity and camera
        //    properties so the guest presents a consistent iPhone17,3 identity.
        //    An iPad guest restores with this tree and boots its own copy (7b).
        let dtIncludeIdentity = variant == .jb || variant == .exp
        components.append(ComponentDescriptor(
            name: "DeviceTree",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/DeviceTree.vphone600ap.im4p"],
            patcherFactories: includeDeviceTree ? [{ data, verbose in
                let p = DeviceTreePatcher(
                    data: data,
                    verbose: verbose,
                    includeIdentityPatches: dtIncludeIdentity,
                    device: guestDevice,
                    role: hasGuestTree ? .restore : .shared,
                )
                p.gate = gate
                return p
            }] : [],
        ))

        // 7b. The iPad's installed DeviceTree, which `fw prepare` split off so it
        //     can carry the iPad identity through restore.
        if hasGuestTree {
            components.append(ComponentDescriptor(
                name: "GuestDeviceTree",
                inRestoreDir: true,
                searchPatterns: [FirmwareManifest.guestDeviceTreePath],
                patcherFactories: includeDeviceTree ? [{ data, verbose in
                    let p = DeviceTreePatcher(
                        data: data,
                        verbose: verbose,
                        includeIdentityPatches: dtIncludeIdentity,
                        device: guestDevice,
                        role: .installed,
                        // Read through the originals stash, which keeps a copy: the
                        // restore tree goes once the VM boots, and `cfw install` and
                        // the environment update take the board's audio node from it.
                        sourceTree: try self.loader.load(from: self.pristineInput(for: boardTreeURL).url),
                    )
                    p.gate = gate
                    return p
                }] : [],
            ))
        }

        // 8. Filesystem
        //    Not restorable: it reads BuildManifest.plist but writes cryptex images
        //    all over the restore tree, so putting the manifest back on its own
        //    would describe a tree that no longer exists. See ComponentDescriptor.
        components.append(ComponentDescriptor(
            name: "Filesystem",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                switch variant {
                case .less:
                    [{ data, verbose in
                        CryptexFilesystemPatcher(
                            buildManiest: data,
                            restoreDir: restoreDir,
                            verbose: verbose,
                            noBinpack: self.noBinpack,
                        )
                    }]
                case .regular, .dev, .jb, .exp:
                    []
                }
            }(),
            restorable: false,
        ))

        // 9. Firmware Manifest - Only required when excluding the img4 signature patches.
        //    Not restorable, for the same reason as Filesystem: the hashes it writes
        //    describe files other steps produced, not the manifest's own bytes.
        components.append(ComponentDescriptor(
            name: "Manifest",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                switch variant {
                case .less:
                    [{ data, verbose in
                        ManifestHashPatcher(data: data, restoreDir: restoreDir, verbose: verbose)
                    }]
                case .regular, .dev, .jb, .exp:
                    []
                }
            }(),
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
        applyFrida: Bool,
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
                p.applyFrida = applyFrida
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
