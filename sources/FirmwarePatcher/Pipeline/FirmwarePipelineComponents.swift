// FirmwarePipelineComponents.swift — Ordered boot-chain component list per variant.
//
// Owns the catalogue half of the pipeline: which firmware components are patched,
// in which order, where their files are searched for, and which patchers run over
// each one for the selected ``FirmwarePipeline/Variant``.
//
// Split out of FirmwarePipeline.swift; the execution loop stays there.

import Foundation

extension FirmwarePipeline {
    // MARK: - Component List Builder

    /// Build the ordered component list based on the variant.
    ///
    /// - Parameters:
    ///   - restoreDir: The `*Restore*` directory `patchAll()` resolved, captured by value
    ///     into the patcher factory closures below.
    ///   - iosBaseIs18: True when the iPhone base is iOS 18.x (read from
    ///     `iPhone-BuildManifest.plist`). Gates the skywalk-netagent boot-arg workaround
    ///     (18.x-specific mDNSResponder crash-loop).
    ///   - iosBaseIs27: True when the iPhone base is iOS 27.x. Gates the iOS-27-only JB
    ///     kernel patches (`KernelJBPatcher.applyIOS27`); false for 18.x/26.x so those
    ///     bases are byte-identical to pre-branch.
    ///   - cloudOSIsFridaCapable: True when the cloudOS kernel is 26.4+; gates the opt-in
    ///     Frida kernel patches.
    func buildComponentList(
        restoreDir: URL,
        iosBaseIs18: Bool,
        iosBaseIs27: Bool,
        cloudOSIsFridaCapable: Bool
    ) -> [ComponentDescriptor] {
        var components: [ComponentDescriptor] = []

        // Captured by value into the patcher factory closures below (avoids
        // capturing self). Always on for iOS 18 bases: 18.6.2's runningboardd/
        // SpringBoard trips GUARD_TYPE_MACH_PORT flavor 10, crash-looping the
        // UI, and the VM won't boot without this patch there. Otherwise off by
        // default and opt-in via `forceExcGuard` (--force-exc-guard):
        // some third-party apps shipping crash-reporting/RASP SDKs call
        // task_swap_exception_ports(), which the research kernel can enforce
        // as a fatal EXC_GUARD/GUARD_TYPE_MACH_PORT/KOBJECT_REPLY_PORT_SEMANTICS
        // violation (see upstream issue #291 / PR #297) — but this isn't
        // required for the VM itself to boot on 26.x, so it stays opt-in
        // rather than always-on for regular/jb/exp.
        let applyExcGuard = iosBaseIs18 || forceExcGuard

        // Same capture-by-value; true only for iOS 27 bases. Gates the iOS-27-only
        // JB kernel patches so 18.x/26.x bases apply none of them.
        let applyIOS27 = iosBaseIs27

        // Opt-in Frida Stalker kernel relaxations (--frida), gated to cloudOS 26.4+.
        let applyFrida = enableFrida && cloudOSIsFridaCapable

        // iOS 18 bases: disable the skywalk flowswitch netagents via boot-arg so
        // Network.framework uses the BSD path (the 26.1-kernel skywalk
        // channel-create traps in the 18.x Network.framework and crash-loops
        // mDNSResponder → no DNS). Empty on 26.x bases (stock boot-args).
        let extraBootArgs = iosBaseIs18 ? "if_attach_nx=0x3" : ""

        // 1. AVPBooter — always present, lives in VM root.
        //    Patched for every non-less variant (regular/dev/jb/exp).
        components.append(ComponentDescriptor(
            name: "AVPBooter",
            inRestoreDir: false,
            searchPatterns: ["AVPBooter*.bin"],
            patcherFactories: {
                if variant != .less {
                    return [
                        { data, verbose in
                            AVPBooterPatcher(data: data, verbose: verbose)
                        },
                    ]
                }
                return []
            }()
        ))

        // 2. iBSS — JB and EXP variants run the base iBSS patcher, then the nonce-skip extension.
        components.append(ComponentDescriptor(
            name: "iBSS",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular, .dev:
                    [{ data, verbose in
                        IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                    }]
                case .jb, .exp:
                    [
                        { data, verbose in
                            IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                        },
                        { data, verbose in
                            IBootJBPatcher(data: data, mode: .ibss, verbose: verbose)
                        },
                    ]
                }
            }()
        ))

        // 3. iBEC - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "iBEC",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"],
            patcherFactories: [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .ibec, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                return p
            }]
        ))

        // 4. LLB - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "LLB",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
            patcherFactories: [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .llb, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                return p
            }]
        ))

        // 5. TXM — dev/jb/exp variants use TXMDevPatcher (adds entitlements, debugger, dev-mode)
        components.append(ComponentDescriptor(
            name: "TXM",
            inRestoreDir: true,
            searchPatterns: ["Firmware/txm.iphoneos.research.im4p"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular:
                    [{ data, verbose in
                        TXMPatcher(data: data, verbose: verbose)
                    }]
                case .dev, .jb, .exp:
                    [{ data, verbose in
                        TXMDevPatcher(data: data, verbose: verbose)
                    }]
                }
            }()
        ))

        // 6. Kernel — JB variant runs base kernel patches first, then JB extensions.
        //    EXP variant runs base + JB + experimental extensions (hv_vmm rename).
        components.append(ComponentDescriptor(
            name: "kernelcache",
            inRestoreDir: true,
            searchPatterns: ["kernelcache.research.vphone600"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular:
                    [{ data, verbose in
                        KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                    }]
                case .dev:
                    [{ data, verbose in
                        KernelPatcher(data: data, verbose: verbose, isDev: true)
                    }]
                case .jb:
                    [
                        { data, verbose in
                            KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                        },
                        { data, verbose in
                            let p = KernelJBPatcher(data: data, verbose: verbose)
                            p.applyIOS27 = applyIOS27
                            p.applyFrida = applyFrida
                            return p
                        },
                    ]
                case .exp:
                    [
                        { data, verbose in
                            KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                        },
                        { data, verbose in
                            let p = KernelJBPatcher(data: data, verbose: verbose)
                            p.applyIOS27 = applyIOS27
                            p.applyFrida = applyFrida
                            return p
                        },
                        { data, verbose in
                            KernelEXPPatcher(data: data, verbose: verbose)
                        },
                    ]
                }
            }()
        ))

        // 7. DeviceTree — base property patches for every variant. EXP additionally
        //    applies the 8 identity-rewrite properties (Tier 1b + 1c) that flip the
        //    device's userland-visible identity toward D47AP / iPhone17,3.
        let dtIncludeIdentity = variant == .exp
        components.append(ComponentDescriptor(
            name: "DeviceTree",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/DeviceTree.vphone600ap.im4p"],
            patcherFactories: [{ data, verbose in
                DeviceTreePatcher(
                    data: data,
                    verbose: verbose,
                    includeIdentityPatches: dtIncludeIdentity
                )
            }]
        ))

        // 8. Filesystem
        components.append(ComponentDescriptor(
            name: "Filesystem",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                return switch variant {
                case .less:
                    [{ data, verbose in
                        CryptexFilesystemPatcher(
                            buildManiest: data,
                            restoreDir: restoreDir,
                            verbose: verbose,
                            noBinpack: self.noBinpack
                        )
                    }]
                case .regular, .dev, .jb, .exp:
                    []
                }
            }()
        ))

        // 9. Firmware Manifest - Only required when excluding the img4 signature patches.
        components.append(ComponentDescriptor(
            name: "Manifest",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                return switch variant {
                case .less:
                    [{ data, verbose in
                        ManifestHashPatcher(data: data, restoreDir: restoreDir, verbose: verbose)
                    }]
                case .regular, .dev, .jb, .exp:
                    []
                }
            }()
        ))

        return components
    }
}
