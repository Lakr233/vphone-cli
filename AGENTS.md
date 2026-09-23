# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Quick Reference

- **Build:** `make build`
- **Boot (GUI):** `make boot`
- **Boot (DFU):** `make boot_dfu`
- **All targets:** `make help`
- **AMFI refuses `vphone-vm`?** `make amfi_allow` (asks for root). Re-run it after every build — it allowlists cdhashes. `make amfi_status` to look, `make amfi_off` to revert. See Key Patterns.
- **Restore:** `vphone-cli restore`, in process. Vendored libirecovery + idevicerestore (`sources/MobileRecoveryCore`, `sources/MobileRestoreCore`) over the `AppleMobileDeviceLibrary` xcframeworks. No interpreter, no environment to provision, no setup step. See `research/p2_restore_off_python.md`.
- **Platform:** macOS 15+ (Sequoia). `vphone-vm` needs amfid to accept its private entitlements: either SIP off with `amfi_get_out_of_my_way=1`, or SIP on (`--without debug`) plus an allowlist bypass the user runs. Both are in README's "SIP/AMFI Relaxation"; neither is installed by this project.
- **Language:** Swift 6.0 (SwiftPM), private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic). This package's own manifest is `swift-tools-version:6.0`, but the **toolchain floor is Swift 6.2**: `libcapstone-spm` declares 6.2 so that it can reach `CSetting.disableWarning` instead of `.unsafeFlags`, which is what lets it be depended on by version at all.
- **Dependencies:** seven SwiftPM packages, every one resolved by URL and **every one by version** — there is no `vendor/` directory, no `branch:` requirement, and `Package.resolved` pins fourteen once transitives are counted. The only git submodule is `scripts/repos/insert_dylib`, a build-time test reference. **No Python anywhere, and no Homebrew package at runtime** — see Tiers below.
- **Tiers.** Three environments run code here and the rules differ. **build** (the machine that builds the `.app`) may use Xcode, `xcrun`, clang, swift, git and Homebrew. **dist** (the shipped `.app`, on a clean macOS) may use `/usr/lib`, `/System` and the bundle — nothing else, no `PATH` lookup. **guest** (inside the VM) is out of host self-containment scope. Every script declares its tier on **line 2** (`# vphone-tier: dist`); `scripts/dist_manifest.sh` reads those and is what `build.sh` and `make bundle` stage from, so a script that declares nothing ships nowhere. `make check-aux` gates all of it. The dist tier's registered-exception list is **empty** and a release requires it to stay that way.

## Workflow Rules

- Do not create, read, or update `/TODO.md`.
- Ignore `/TODO.md` if it exists locally; it is intentionally not part of the repo workflow anymore.
- Track plan, progress, assumptions, blockers, and next actions in commit history, code comments when warranted, and current research docs instead of a repo TODO file.

For any changes applying new patches, also update research/0_binary_patch_comparison.md. Dont forget this.

## Local Skills

- If working on kernel analysis, symbolication lookups, or kernel patch reasoning, read `skills/kernel-analysis-vphone600/SKILL.md` first.
- Use this skill as the default procedure for `vphone600` kernel work.

## Firmware Mode

The public CLI exposes only JB: `vphone-cli fw patch` and `vphone-cli cfw install`.
The guest contains vphoned and required system patches; package-manager
bootstrap and first-boot installation are outside this project. Do not add
another public variant.

See `research/` for detailed firmware pipeline, component origins, patch breakdowns, and boot flow documentation.

## Architecture

```
Makefile                          # Single entry point — run `make help`

sources/
├── vphone.entitlements               # Private API entitlements (7 keys) — signed ONTO vphone-vm ONLY
│
├── vphone-cli/                       # Entry point. NO entitlements, so it always launches.
│   │                                 # Argument parsing + orchestration; spawns the others.
│   ├── main.swift                    # Parses, and forwards `boot` to vphone-vm
│   ├── VPhoneCLI.swift               # Root command, patch-firmware/patch-component
│   ├── VPhoneFWCLI.swift             # Firmware subcommands
│   ├── VPhoneSetupCLI.swift          # Setup subcommands
│   ├── VPhoneRestoreCLI.swift        # `restore` + the `cfw` subcommand group
│   ├── VPhoneCFWPatchCLI.swift       # `cfw` verbs: cryptex-paths, inject-*, patch-*
│   ├── VPhoneCFWMachOVerbsCLI.swift  # The six Mach-O `cfw patch-*` verbs
│   ├── VPhoneCFWDSCVerbsCLI.swift    # The eight dyld-shared-cache `cfw patch-*` verbs
│   ├── VPhoneSignCLI.swift           # `sign` — VPhoneSign from the command line
│   ├── VPhoneVMCLI.swift             # VM subcommand group
│   ├── VPhoneVMCreateCLI.swift       # VM create
│   ├── VPhoneVMLaunchCLI.swift       # VM launch
│   ├── VPhoneVMTransferCLI.swift     # VM transfer
│   ├── VPhoneCreateOptions.swift     # Create-flow option set
│   ├── VPhoneCreateOrchestrator.swift # Native `vm create` pipeline driver
│   ├── VPhoneCFWInstaller.swift       # Native host-mount JB install
│   ├── VPhoneHostPreflight.swift      # Native host launch check
│   ├── VPhoneFirmwareSelection.swift # Interactive firmware picker
│   ├── VPhoneVMSelection.swift       # Interactive VM picker
│   └── VPhoneProgressBar.swift       # Terminal progress rendering
│
├── vphone-vm/                        # The ONLY entitled binary — a parse and a run loop
│   └── main.swift                    # VPhoneBootCLI.parseOrExit() → VPhoneGuestApp.run()
│
├── vphone-archive/                   # Thin shell over VPhoneArchive
│   └── main.swift                    # extract / create / decompress / list / cat / fingerprint
│
├── VPhoneCore/                       # No UI, no guest — what both entry points share
│   ├── VPhoneBootCLI.swift           # Boot flags, parsed by both binaries; renders argv
│   ├── VPhoneGuestLauncher.swift     # Spawns vphone-vm; explains an amfid refusal
│   ├── VPhoneBundle*.swift           # VM bundle layout, ops, reporting
│   ├── VPhoneVirtualMachineManifest.swift # config.plist (replaced scripts/vm_manifest.py)
│   ├── VPhoneAPFSSnapshot.swift      # Offline APFS boot-snapshot flip
│   └── …                             # networking, resources, process running, pickers
│
├── VPhoneArchive/                    # libarchive: replaces gtar, bsdtar, unzip and zstd
│   ├── VPhoneArchiveExtractor.swift  # Unpack, incl. the hand-written --no-overwrite-dir
│   ├── VPhoneArchiveWriter.swift     # Pack + single-stream decompress
│   ├── VPhoneArchivePaths.swift      # realpath(3) — NOT the Foundation equivalents
│   └── VPhoneTreeFingerprint.swift   # Compare two extracted trees, field by field
│
├── VPhoneSign/                       # Mach-O code signing — replaces ldid, byte for byte
│   ├── VPhoneSigner.swift            # Ad-hoc and PKCS#12 signing
│   ├── VPhoneCodeSignature.swift     # SuperBlob / CodeDirectory construction
│   ├── VPhoneSignEntitlements.swift  # Entitlements plist blob (+ …Reader for reading one back)
│   ├── VPhoneSignDER.swift           # The DER entitlements blob
│   └── VPhoneMachOImage.swift        # Slice parsing. ARM only — an x86 slice is refused
│
├── MobileRecoveryCore/               # libirecovery master, vendored C. IOKit USB, not libusb
│   ├── libirecovery.c                # Upstream's bytes, unmodified. master, NOT 1.3.1 — the
│   │                                 # release predates the iPhone99,11 / vresearch101ap entry
│   │                                 # and without it a restore cannot identify the vphone VM
│   ├── include/libirecovery.h        # Upstream's public header
│   └── config.h                      # Ours — what ./configure concludes on macOS
│
├── MobileRestoreCore/                # idevicerestore, vendored C, built IDEVICERESTORE_NOMAIN
│   ├── restore.c asr.c fdr.c img4.c …# Upstream's bytes, unmodified (~19.5k lines)
│   ├── vphone_restore_bridge.c       # Ours — the library entry point upstream's main() was
│   ├── vphone_zip_stub.c + zip.h     # Ours — libzip has no counterpart here; see zip.h's header
│   ├── config.h                      # Ours
│   └── include/vphone_restore_bridge.h # The only header a dependent sees
│
├── VPhoneRestore/                    # Swift over those two C targets — replaced the Python bridge
│   ├── VPhoneRecoveryProbe.swift     # irecv_open_with_ecid_and_attempts + timeout polling
│   ├── VPhoneRestoreBridge.swift     # The three ported commands: probe, get-shsh, restore
│   ├── VPhoneRestoreTicket.swift     # Undoes idevicerestore's -t: gzipped binary plist → plain
│   ├── VPhoneRestoreRunner.swift     # Drives vphone_restore_run
│   └── …                             # options, identity, restore-tree layout, events, errors
│
├── FirmwarePatcher/                  # The Swift firmware pipeline (largest module)
│   ├── IBoot/ Kernel/ TXM/           # Boot-chain patches; Kernel/JBPatches/ is the JB set
│   ├── DeviceTree/ Filesystem/       # DT edits, cryptex/rootfs work
│   └── ARM64/ Binary/ Core/ Pipeline/ # Disassembly, Mach-O, driver
│
└── VPhoneVMKit/                      # Everything that touches a running guest
    ├── VPhoneGuestApp.swift          # NSApplication wiring (keeps the entry point logic-free)
    ├── VPhoneAppDelegate.swift       # App lifecycle, SIGINT, VM start/stop
    ├── VPhoneHostControl.swift       # Unix-socket automation server (one JSON line in/out)
    ├── VPhoneBootCLI+VirtualMachine.swift # resolveOptions() — the half that needs Virtualization
    │
    ├── VM/                           # VM core
    │   ├── VPhoneVirtualMachine.swift # @MainActor VM configuration and lifecycle
    │   ├── VPhoneVirtualMachineView.swift # Touch-enabled VZVirtualMachineView + helpers
    │   ├── VPhoneHardwareModel.swift # PV=3 hardware model via Dynamic
    │   └── VPhoneError.swift         # Error types
    │
    ├── Guest/                        # Guest daemon client (vsock)
    │   ├── VPhoneControl.swift       # Host-side vsock client for vphoned (length-prefixed JSON)
    │   ├── VPhoneControlApps.swift   # Installed apps — list and launch
    │   ├── VPhoneControlKeychain.swift # Keychain dump
    │   └── VPhoneControlSystem.swift # Device, battery, location, devmode
    │
    ├── Interface/                    # Window & UI
    │   ├── VPhoneWindowController.swift # @MainActor VM window management + toolbar
    │   ├── VPhoneKeyHelper.swift     # Keyboard/hardware key event dispatch to VM
    │   │
    │   ├── Menu/                     # Menu bar (extensions on VPhoneMenuController)
    │   │   ├── VPhoneMenuController.swift # Menu bar controller
    │   │   ├── VPhoneMenuApps.swift  # Apps menu — installed app browser
    │   │   ├── VPhoneMenuBattery.swift # Battery menu — battery status display
    │   │   ├── VPhoneMenuCamera.swift # Camera menu — virtual camera source
    │   │   ├── VPhoneMenuConnect.swift # Connect menu — devmode, ping, version, file browser
    │   │   ├── VPhoneMenuKeys.swift  # Keys menu — home, power, volume, spotlight
    │   │   ├── VPhoneMenuLocation.swift # Location menu — host location sync toggle
    │   │   └── VPhoneMenuRecord.swift # Record menu — screen recording controls
    │   │
    │   └── Browsers/                 # SwiftUI browsers in NSHostingController windows
    │       ├── VPhoneFileBrowserModel.swift # @Observable file browser state + transfers
    │       ├── VPhoneFileBrowserView.swift # SwiftUI file browser with search + drag-drop
    │       ├── VPhoneFileWindowController.swift # File browser window
    │       ├── VPhoneRemoteFile.swift # Remote file data model
    │       ├── VPhoneAppBrowserModel.swift # App browser state
    │       ├── VPhoneAppBrowserView.swift # SwiftUI app browser
    │       ├── VPhoneAppWindowController.swift # App browser window
    │       ├── VPhoneKeychainBrowserModel.swift # Keychain browser state
    │       ├── VPhoneKeychainBrowserView.swift # SwiftUI keychain browser
    │       ├── VPhoneKeychainWindowController.swift # Keychain browser window
    │       ├── VPhoneKeychainItem.swift # Keychain item data model
    │       └── VPhoneQuickLookController.swift # Quick Look preview panel
    │
    └── Devices/                      # Host capability bridges into the running VM
        ├── VPhoneCameraServer.swift  # Virtual-camera server (vsock port 1338)
        ├── VPhoneFrameProducer.swift # BGRA frame sources for the camera server
        ├── VPhoneLocationProvider.swift # CoreLocation → guest forwarding over vsock
        ├── VPhoneTouchIDMonitor.swift # BiometricKit delegate sink
        └── VPhoneScreenRecorder.swift # VM screen recording to file

scripts/                          # Build scripts and payloads only; no runtime shell
├── build.sh                  [b] # Compile, sign and bundle
├── dist_manifest.sh          [b] # Payload allowlist staged by build.sh
├── guest_binaries.mk         [b] # Cross-compiles vphoned (needs the iPhoneOS SDK)
├── check_aux.sh              [b] # The self-containment admission gates — `make check-aux`
├── setup_tools.sh            [b] # Builds insert_dylib, the Mach-O byte-parity test reference
├── payloads/                     # Small GPU driver archive; no bootstrap payloads
├── vphoned/                      # Guest daemon source; only its plist and entitlements ship
├── tweakloader/ vpregister/ vcamcaptured/ camfix/ # Unshipped experimental sources
└── repos/                        # Toolchain source (git submodule: insert_dylib)

research/                         # Detailed firmware/patch documentation
```

### Key Patterns

- **Three host binaries, one of them entitled.** `vphone-cli` carries no entitlements, so it launches on any host and is always there to explain what is wrong. `vphone-vm` holds all 7 private keys and is the only thing amfid can refuse. `vphone-archive` does the unpacking. **Do not sign `vphone-cli` with entitlements** — that is how it used to be, and it is why the entry point could not start without a bypass already running.
- **The AMFI bypass is ours, and it writes heap, not code.** `vphone-amfi-allow` (`sources/vphone-amfi-allow/`, this project's copy of [Lakr233/amfi-allow](https://github.com/Lakr233/amfi-allow)) puts the cdhashes of both `vphone-vm` copies into `/Library/Preferences/com.apple.security.coderequirements.plist` — a file AMFI already reads — and flips one byte of `_isRunningInternalBuild` in amfid's `AMFIRequirementsManager` singleton so it consults that file. It is an **allowlist**, scoped to the cdhashes you name; do not describe it as a global switch. `make amfi_allow` runs it, `amfi_status` shows it, `amfi_off` removes it. It is a **per-build** step, because a cdhash changes with every signature. It must be **arm64e** to match amfid's slice, which is why it is a clang rule and not a SwiftPM target. The heap write is the load-bearing detail: `vphone-letmein` and LLDB-based tools dirty an executable page, and on a host with `vm.cs_system_enforcement = 1` the kernel kills amfid for that and takes the guest with it.
- **Guest launches go through `VPhoneGuestLaunchPlanner`** (`VPhoneCore`). It resolves `vphone-vm` as a sibling of the running image — never through `PATH` — and probes once per command with `vphone-vm --help`, looking for SIGKILL. A refusal is reported with the exact command the user has to run; the planner never arranges a bypass itself. Never spawn the guest directly.
- **Restore runs in `vphone-cli`'s own process.** `VPhoneRestore` calls `vphone_restore_run()` in `MobileRestoreCore`; there is no subprocess, no bridge script and no environment to resolve first. The three commands the old Python bridge exposed became `restore --get-shsh`, `restore` and `restore --offline`; its fourth, `usbmux-list`, had no call site and was not ported. `research/p2_restore_off_python.md` has the decision and the behaviour table.
- **Private API access:** Via [Dynamic](https://github.com/mhdhejazi/Dynamic) library (runtime method dispatch from pure Swift). No ObjC bridge.
- **App lifecycle:** `vphone-vm/main.swift` → `VPhoneGuestApp.run()` → `NSApplication` + `VPhoneAppDelegate`. Entry points hold no logic.
- **Configuration:** `ArgumentParser` → `VPhoneBootCLI` (in `VPhoneCore`, parsed by both binaries) → `VPhoneVirtualMachine.Options` → `VZVirtualMachineConfiguration`.
- **Guest daemon (vphoned):** ObjC daemon inside iOS VM, vsock port 1337, length-prefixed JSON protocol. Host side is `VPhoneControl` with auto-reconnect.
- **Menu system:** `VPhoneMenuController` + per-menu extensions (Keys, Type, Location, Connect, Install, Record).
- **File browser:** SwiftUI (`VPhoneFileBrowserView` + `VPhoneFileBrowserModel`) in `NSHostingController`. Search, sort, upload/download, drag-drop via `VPhoneControl`.
- **IPA installation:** `VPhoneIPAInstaller` extracts + re-signs via `VPhoneSigner` + installs over vsock.
- **Screen recording:** `VPhoneScreenRecorder` captures VM display. Controls via Record menu.

---

## Coding Conventions

### Swift

- **Language:** Swift 6.0 (strict concurrency).
- **Style:** Pragmatic, minimal. No unnecessary abstractions.
- **Sections:** Use `// MARK: -` to organize code within files.
- **Access control:** Default (internal). Only mark `private` when needed for clarity.
- **Concurrency:** `@MainActor` for VM and UI classes. `nonisolated` delegate methods use `MainActor.isolated {}` to hop back safely.
- **Naming:** Types are `VPhone`-prefixed. Match Apple framework conventions.
- **Private APIs:** Use `Dynamic()` for runtime method dispatch. Touch objects use `NSClassFromString` + KVC to avoid designated initializer crashes.
- **NSWindow `isReleasedWhenClosed`:** Always set `window.isReleasedWhenClosed = false` for programmatically created windows managed by an `NSWindowController`. The default `true` causes `objc_release` crashes on dangling pointers during CA transaction commit.

### Shell Scripts

- Use `zsh` with `set -euo pipefail`.
- Scripts resolve their own directory via `${0:a:h}` or `$(cd "$(dirname "$0")" && pwd)`.

### Patchers

Every patcher is Swift, in `sources/FirmwarePatcher`. The boot chain and kernel
run through `patch-firmware`; the CFW/DSC patchers are `vphone-cli cfw <verb>`,
one verb per patch, driven by `scripts/cfw_install*.sh` only.

- Disassembly is Capstone via `ARM64Disassembler` (the `libcapstone-spm` package). Assembly is `ARM64Encoder` plus the pre-encoded constants in `ARM64` (`ARM64Constants.swift`) — together they replace keystone's `asm()` / `asm_at()`, and `ARM64.nop` / `ARM64.movW0_0` are the old `NOP` / `MOV_W0_0`. IM4P containers go through `IM4PHandler` (the `libimg4-spm` package), which replaces pyimg4. Both resolve by URL; there is no `vendor/` directory to check out first.
- Dynamic pattern finding (string anchors, ADRP+ADD xrefs, BL frequency) — no hardcoded offsets.
- Each patch logged with offset and before/after state.
- No interpreter, no Python environment, no native-library repair: `make build` is the whole toolchain.

### Python

There is none, and adding any is a regression.

- No `.py` file is tracked in this repository, no shell script embeds a Python
  heredoc, and nothing resolves a `python3` at runtime. `git ls-files '*.py'`
  returns nothing; that is the standing check.
- There is no environment to activate and no dependency list to install. The
  restore backend was the last holdout and is now `sources/VPhoneRestore` over
  two vendored C targets — see `research/p2_restore_off_python.md`.
- A patch, a probe, a format reader or a device protocol belongs in Swift,
  where it is built, signed, gated by `make check-aux` and tested with
  everything else. Adding an interpreter back brings with it a provisioning
  step, a silent system-`python3` fallback, and a dependency closure
  `make check-aux` cannot see.
- There is no counter-example left. `amfidont` used to be cited as one — a
  third-party tool the user installed into their own Python — and it is gone
  too: the AMFI bypass is `sources/vphone-amfi-allow`, one C file built by
  clang, and it needs no interpreter, no LLDB and no Xcode.

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible. `ARM64Disassembler` is the only decoder — match on the decoded mnemonic and operand detail, never on a formatted operand string.
- All replacement instruction bytes must come from Keystone-backed helpers already used by the project: `ARM64Encoder.encode*` and the `ARM64` constants, which were generated by keystone-engine, verified by Capstone round-trip, and are asserted word for word against keystone in `tests/FirmwarePatcherTests/ARM64EncoderTests.swift`. Never write a literal instruction word at a patch site. A new instruction means a new encoder plus its keystone-checked test case, not a raw `Data`. Keystone is deliberately **not** a project dependency any more — nothing at runtime or in the test suite calls it, and the expected words are frozen constants. To derive a new one, stand keystone up in a throwaway environment **outside this repository** (`brew install keystone`, plus `keystone-engine` in a scratch interpreter somewhere under `/tmp`) and run the one-liner in that test file's header against it. There is no dependency list here to add it to and no environment here to install it into; creating either is the regression the "Python" section above forbids. Do not invent an expected word without checking it.
- Prefer source-backed semantic anchors: in-image symbol lookup, string xrefs, local call-flow, and XNU correlation. Do not depend on repo-exported per-kernel symbol dumps at runtime.
- When retargeting a patch, write the reveal procedure and validation steps into the relevant research doc or commit notes before handing off for testing. Do not create `TODO.md`.
- For `patchBsdInitAuth` (`Kernel/JBPatches/Storage/KernelJBPatchBsdInitAuth.swift`, named `patch_bsd_init_auth` in the research docs) specifically, the allowed reveal flow is: recover `bsd_init` -> locate rootvp panic block -> find the unique in-function `call` -> `cbnz w0/x0, panic` -> `bl imageboot_needed` site -> patch the branch gate only.

## Build & Sign

The binary requires private entitlements for PV=3 virtualization. Always use `make build` — never `swift build` alone, as the unsigned binary will fail at runtime.

## Design System

- **Audience:** Security researchers. Terminal-adjacent workflow.
- **Feel:** Research instrument — precise, informative, no decoration.
- **Palette:** Dark neutral (`#1a1a1a` bg), status green/amber/red/blue accents.
- **Typography:** System monospace (SF Mono / Menlo) for UI and log output.
- **Depth:** Flat with 1px borders (`#333333`). No shadows.
- **Spacing:** 8px base unit, 12px component padding, 16px section gaps.
