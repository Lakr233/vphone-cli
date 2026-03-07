# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Quick Reference

- **Build:** `make build`
- **Boot (GUI):** `make boot`
- **Boot (DFU):** `make boot_dfu`
- **All targets:** `make help`
- **Python venv:** `make setup_venv` (installs to `.venv/`, activate with `source .venv/bin/activate`)
- **Platform:** macOS 15+ (Sequoia), SIP/AMFI disabled
- **Language:** Swift 6.0 (SwiftPM), private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic)
- **Python deps:** `capstone`, `keystone-engine`, `pyimg4` (see `requirements.txt`)

## Workflow Rules

- Always read `/TODO.md` before starting any substantial work.
- Always update `/TODO.md` when plan, progress, assumptions, blockers, or open questions change.
- If blocked or waiting on user input, write the exact blocker and next action in `/TODO.md`.
- If not exists, continue existing work until complete. If exists, follow `/TODO.md` instructions.

For any changes applying new patches, also update research/0_binary_patch_comparison.md. Dont forget this.

## Local Skills

- If working on kernel analysis, symbolication lookups, or kernel patch reasoning, read `skills/kernel-analysis-vphone600/SKILL.md` first.
- Use this skill as the default procedure for `vphone600` kernel work.

## Firmware Variants

| Variant         | Boot Chain  |    CFW    | Make Targets                                                 |
| --------------- | :---------: | :-------: | ------------------------------------------------------------ |
| **Regular**     | 51 patches  | 10 phases | `fw_patch` + `cfw_install`                                   |
| **Development** | 64 patches  | 12 phases | `fw_patch_dev` + `cfw_install_dev`                           |
| **Jailbreak**   | 126 patches | 14 phases | `fw_patch_jb` + `cfw_install_jb`                             |

> JB finalization (symlinks, Sileo, apt, TrollStore) runs automatically on first boot via `/cores/vphone_jb_setup.sh` LaunchDaemon. Monitor progress: `/var/log/vphone_jb_setup.log`.

See `research/` for detailed firmware pipeline, component origins, patch breakdowns, and boot flow documentation.

## Architecture

```
Makefile                          # Single entry point — run `make help`

sources/
├── vphone.entitlements               # Private API entitlements (5 keys)
└── vphone-cli/                       # Swift 6.0 executable (pure Swift, no ObjC)
    ├── main.swift                    # Entry point — NSApplication + AppDelegate
    ├── VPhoneAppDelegate.swift       # App lifecycle, SIGINT, VM start/stop
    ├── VPhoneCLI.swift               # ArgumentParser options (no execution logic)
    ├── VPhoneBuildInfo.swift         # Auto-generated build-time commit hash
    │
    │   # VM core
    ├── VPhoneVirtualMachine.swift    # @MainActor VM configuration and lifecycle
    ├── VPhoneHardwareModel.swift     # PV=3 hardware model via Dynamic
    ├── VPhoneVirtualMachineView.swift # Touch-enabled VZVirtualMachineView + helpers
    ├── VPhoneError.swift             # Error types
    │
    │   # Guest daemon client (vsock)
    ├── VPhoneControl.swift           # Host-side vsock client for vphoned (length-prefixed JSON)
    │
    │   # Window & UI
    ├── VPhoneWindowController.swift  # @MainActor VM window management + toolbar
    ├── VPhoneKeyHelper.swift         # Keyboard/hardware key event dispatch to VM
    ├── VPhoneLocationProvider.swift  # CoreLocation → guest forwarding over vsock
    ├── VPhoneScreenRecorder.swift    # VM screen recording to file
    │
    │   # Menu bar (extensions on VPhoneMenuController)
    ├── VPhoneMenuController.swift    # Menu bar controller
    ├── VPhoneMenuKeys.swift          # Keys menu — home, power, volume, spotlight
    ├── VPhoneMenuType.swift          # Type menu — paste ASCII text to guest
    ├── VPhoneMenuLocation.swift      # Location menu — host location sync toggle
    ├── VPhoneMenuConnect.swift       # Connect menu — devmode, ping, version, file browser
    ├── VPhoneMenuInstall.swift       # Install menu — IPA installation to guest
    ├── VPhoneMenuRecord.swift        # Record menu — screen recording controls
    ├── VPhoneMenuBattery.swift       # Battery menu — battery status display
    │
    │   # IPA installation
    ├── VPhoneIPAInstaller.swift      # IPA extraction, signing, and installation
    ├── VPhoneSigner.swift            # Mach-O binary signing utilities
    │
    │   # File browser (SwiftUI)
    ├── VPhoneFileWindowController.swift # File browser window (NSHostingController)
    ├── VPhoneFileBrowserView.swift   # SwiftUI file browser with search + drag-drop
    ├── VPhoneFileBrowserModel.swift  # @Observable file browser state + transfers
    └── VPhoneRemoteFile.swift        # Remote file data model

scripts/
├── vphoned/                      # Guest daemon (ObjC, runs inside iOS VM over vsock)
├── patchers/                     # Python patcher modules
│   ├── iboot.py                  #   iBoot patcher (iBSS/iBEC/LLB)
│   ├── iboot_jb.py              #   JB: iBoot nonce skip
│   ├── kernel.py                 #   Kernel patcher (26 patches)
│   ├── kernel_jb.py             #   JB: kernel patches (~40)
│   ├── txm.py                   #   TXM patcher
│   ├── txm_dev.py               #   Dev: TXM entitlements/debugger/dev mode

│   └── cfw.py                   #   CFW binary patcher
├── resources/                    # Resource archives (git submodule)
├── patches/                      # Build-time patches (libirecovery)
├── fw_prepare.sh                 # Download IPSWs, merge cloudOS into iPhone
├── fw_manifest.py                # Generate hybrid BuildManifest/Restore plists
├── fw_patch.py                   # Patch boot chain (regular)
├── fw_patch_dev.py               # Regular + dev TXM patches
├── fw_patch_jb.py                # Regular + JB extensions
├── ramdisk_build.py              # Build SSH ramdisk with trustcache
├── ramdisk_send.sh               # Send ramdisk to device via irecovery
├── cfw_install.sh                # Install CFW (regular)
├── cfw_install_dev.sh            # Regular + rpcserver daemon
├── cfw_install_jb.sh             # Regular + jetsam fix + procursus
├── vm_create.sh                  # Create VM directory
├── setup_machine.sh              # Full automation (setup → first boot)
├── setup_tools.sh                # Install deps, build toolchain, create venv
├── setup_venv.sh                 # Create Python venv
├── setup_venv_linux.sh           # Create Python venv (Linux)
├── setup_libimobiledevice.sh     # Build libimobiledevice from source
└── tail_jb_patch_logs.sh         # Tail JB patch log output

research/                         # Detailed firmware/patch documentation
```

### Key Patterns

- **Private API access:** Via [Dynamic](https://github.com/mhdhejazi/Dynamic) library (runtime method dispatch from pure Swift). No ObjC bridge.
- **App lifecycle:** `main.swift` → `NSApplication` + `VPhoneAppDelegate`. CLI args parsed before run loop. AppDelegate drives VM start/window/shutdown.
- **Configuration:** `ArgumentParser` → `VPhoneVirtualMachine.Options` → `VZVirtualMachineConfiguration`.
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

### Python Scripts

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible.
- All replacement instruction bytes must come from Keystone-backed helpers already used by the project (for example `asm(...)`, `NOP`, `MOV_W0_0`, etc.).
- Prefer source-backed semantic anchors: in-image symbol lookup, string xrefs, local call-flow, and XNU correlation. Do not depend on repo-exported per-kernel symbol dumps at runtime.
- When retargeting a patch, write the reveal procedure and validation steps into `TODO.md` before handing off for testing.
- For `patch_bsd_init_auth` specifically, the allowed reveal flow is: recover `bsd_init` -> locate rootvp panic block -> find the unique in-function `call` -> `cbnz w0/x0, panic` -> `bl imageboot_needed` site -> patch the branch gate only.

- Patchers use `capstone` (disassembly), `keystone-engine` (assembly), `pyimg4` (IM4P handling).
- Dynamic pattern finding (string anchors, ADRP+ADD xrefs, BL frequency) — no hardcoded offsets.
- Each patch logged with offset and before/after state.
- Use project venv (`source .venv/bin/activate`). Create with `make setup_venv`.

## Build & Sign

The binary requires private entitlements for PV=3 virtualization. Always use `make build` — never `swift build` alone, as the unsigned binary will fail at runtime.

## Design System

- **Audience:** Security researchers. Terminal-adjacent workflow.
- **Feel:** Research instrument — precise, informative, no decoration.
- **Palette:** Dark neutral (`#1a1a1a` bg), status green/amber/red/blue accents.
- **Typography:** System monospace (SF Mono / Menlo) for UI and log output.
- **Depth:** Flat with 1px borders (`#333333`). No shadows.
- **Spacing:** 8px base unit, 12px component padding, 16px section gaps.
