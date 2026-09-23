# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Quick Reference

- **Build:** `make build`
- **Boot (GUI):** `make boot`
- **Boot (DFU):** `make boot_dfu`
- **All targets:** `make help`
- **AMFI refuses `vphone-vm`?** `make amfi_command` prints the bypass line for this build. The bypass itself is the user's to install and run; see Key Patterns.
- **Python venv:** `make setup_venv` (installs to `.venv/`, activate with `source .venv/bin/activate`). Needed only for `make restore*` — `scripts/pymobiledevice3_bridge.py` is the one Python program left. The patch pipeline never touches it.
- **Platform:** macOS 15+ (Sequoia). `vphone-vm` needs amfid to accept its private entitlements: either SIP off with `amfi_get_out_of_my_way=1`, or SIP on (`--without debug`) plus an allowlist bypass the user runs. Both are in README's "SIP/AMFI Relaxation"; neither is installed by this project.
- **Language:** Swift 6.0 (SwiftPM), private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic)
- **Python deps:** `typer`, `pymobiledevice3`, `ipsw-parser` (see `requirements.txt`) — the restore bridge's, and nothing else's

## Workflow Rules

- Do not create, read, or update `/TODO.md`.
- Ignore `/TODO.md` if it exists locally; it is intentionally not part of the repo workflow anymore.
- Track plan, progress, assumptions, blockers, and next actions in commit history, code comments when warranted, and current research docs instead of a repo TODO file.

For any changes applying new patches, also update research/0_binary_patch_comparison.md. Dont forget this.

## Local Skills

- If working on kernel analysis, symbolication lookups, or kernel patch reasoning, read `skills/kernel-analysis-vphone600/SKILL.md` first.
- Use this skill as the default procedure for `vphone600` kernel work.

## Firmware Variants

| Variant          | Boot Chain     |    CFW    | Make Targets                       |
| ---------------- | :------------: | :-------: | ---------------------------------- |
| **Regular**      | 52 patches     | 10 phases | `fw_patch` + `cfw_install`         |
| **Development**  | 66 patches     | 12 phases | `fw_patch_dev` + `cfw_install_dev` |
| **Jailbreak**    | 127 patches    | 14 phases | `fw_patch_jb` + `cfw_install_jb`   |
| **Experimental** | 141 patches    | 18 phases | `fw_patch_exp` + `cfw_install_exp` |

> JB finalization (symlinks, Sileo, apt, TrollStore) runs automatically on first boot via `/cores/vphone_jb_setup.sh` LaunchDaemon. Monitor progress: `/var/log/vphone_jb_setup.log`.

> EXP is a JB superset that patches the kernel and DSC to make some Apple services think the device is not a VM, while keeping VM-specific services (graphics passthrough, compute/accel fast paths) working correctly. Other variants are deliberately NOT affected by these changes.

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
│   ├── VPhoneRestoreCLI.swift        # Restore subcommands
│   ├── VPhoneVMCLI.swift             # VM subcommand group
│   ├── VPhoneVMCreateCLI.swift       # VM create
│   ├── VPhoneVMLaunchCLI.swift       # VM launch
│   ├── VPhoneVMTransferCLI.swift     # VM transfer
│   ├── VPhoneCreateOptions.swift     # Create-flow option set
│   ├── VPhoneCreateOrchestrator.swift # Native `vm create` pipeline driver
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

scripts/                          # Shell only — the CFW patchers are `vphone-cli cfw <verb>` now
├── vphoned/                      # Guest daemon (ObjC, runs inside iOS VM over vsock)
├── pymobiledevice3_bridge.py     # The ONE remaining Python program (restore); needs .venv
├── resources/                    # Resource archives (git submodule)
├── repos/                        # Toolchain source repos (git submodules: trustcache, insert_dylib)
├── fw_prepare.sh                 # Download IPSWs, merge cloudOS into iPhone
├── cfw_install.sh                # Install CFW (regular)
├── cfw_install_dev.sh            # Regular + rpcserver daemon
├── cfw_install_jb.sh             # Regular + jetsam fix + procursus
├── cfw_install_exp.sh            # JB + experimental research patches (hv_vmm rename, DT identity)
├── cfw_install_host.sh           # Host-mount CFW driver (attaches Disk.img, VM off; re-execs sudo)
├── vm_create.sh                  # Create VM directory
├── setup_machine.sh              # Full automation (setup → first boot)
├── setup_tools.sh                # Install deps, build toolchain from submodules, create venv
├── setup_venv.sh                 # Create Python venv
├── setup_venv_linux.sh           # Create Python venv (Linux)
└── tail_jb_patch_logs.sh         # Tail JB patch log output

cfw-kit/                          # Variant-layered CFW installer, vendored as-is
├── run.sh                        # Entry point
├── lib/                          # common.sh (cfw_cli / ldid_sign / $TAR seams), base_stages.sh
├── vanilla/ jb/                  # Per-flavour install.sh; jb/userland/* are empty slots
└── docs/phase-matrix.md

research/                         # Detailed firmware/patch documentation
```

### Key Patterns

- **Three host binaries, one of them entitled.** `vphone-cli` carries no entitlements, so it launches on any host and is always there to explain what is wrong. `vphone-vm` holds all 7 private keys and is the only thing amfid can refuse. `vphone-archive` does the unpacking. **Do not sign `vphone-cli` with entitlements** — that is how it used to be, and it is why the entry point could not start without a bypass already running.
- **The AMFI bypass is the user's, not ours.** This project does not ship, install, spawn or supervise one. Relaxing AMFI at boot is the plain route; where that is not wanted, `amfidont` (`xcrun python3 -m pip install --user amfidont`, needs Xcode) allows `vphone-vm` by path or CDHash through LLDB. It is an **allowlist**, scoped to the binaries you name — do not describe it as a global switch. `make amfi_command` prints the line for the current build and prints only; the CDHash changes with every build. No Python dependency enters this repo for it; `scripts/pymobiledevice3_bridge.py` stays the only Python program here.
- **Guest launches go through `VPhoneGuestLaunchPlanner`** (`VPhoneCore`). It resolves `vphone-vm` as a sibling of the running image — never through `PATH` — and probes once per command with `vphone-vm --help`, looking for SIGKILL. A refusal is reported with the exact command the user has to run; the planner never arranges a bypass itself. Never spawn the guest directly.
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
one verb per patch, driven by `scripts/cfw_install*.sh` and `cfw-kit/`.

- Disassembly is Capstone via `ARM64Disassembler` (`vendor/libcapstone-spm`). Assembly is `ARM64Encoder` plus the pre-encoded constants in `ARM64` (`ARM64Constants.swift`) — together they replace keystone's `asm()` / `asm_at()`, and `ARM64.nop` / `ARM64.movW0_0` are the old `NOP` / `MOV_W0_0`. IM4P containers go through `IM4PHandler` (`vendor/libimg4-spm`), which replaces pyimg4.
- Dynamic pattern finding (string anchors, ADRP+ADD xrefs, BL frequency) — no hardcoded offsets.
- Each patch logged with offset and before/after state.
- No interpreter, no venv, no native-library repair: `make build` is the whole toolchain.

### Python Scripts

- One program is left: `scripts/pymobiledevice3_bridge.py`, the restore backend. Use the project venv (`source .venv/bin/activate`); create it with `make setup_venv`.
- Do not add a second one. A patch, a probe or a format reader belongs in Swift, where it is built, signed and tested with everything else.

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible. `ARM64Disassembler` is the only decoder — match on the decoded mnemonic and operand detail, never on a formatted operand string.
- All replacement instruction bytes must come from Keystone-backed helpers already used by the project: `ARM64Encoder.encode*` and the `ARM64` constants, which were generated by keystone-engine, verified by Capstone round-trip, and are asserted word for word against keystone in `tests/FirmwarePatcherTests/ARM64EncoderTests.swift`. Never write a literal instruction word at a patch site. A new instruction means a new encoder plus its keystone-checked test case, not a raw `Data`. Keystone is deliberately **not** a project dependency any more — nothing at runtime or in the test suite calls it, and the expected words are frozen constants. To derive a new one, build it a throwaway environment: `brew install keystone && python3 -m venv /tmp/ks && /tmp/ks/bin/pip install keystone-engine`, then the one-liner in that test file's header. Do not add it back to `requirements.txt` or the venv, and do not invent an expected word without checking it.
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
