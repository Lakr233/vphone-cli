# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Quick Reference

- **Build:** `make build`
- **Boot (GUI):** `make boot`
- **Boot (DFU):** `make boot_dfu`
- **All targets:** `make help`
- **Python venv:** `make setup_venv` (installs to `.venv/`, activate with `source .venv/bin/activate`)
- **Platform:** macOS 14+ (Sequoia), SIP/AMFI disabled
- **Language:** Swift 6.0 (SwiftPM), private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic)
- **Python deps:** `capstone`, `keystone-engine`, `pyimg4` (see `requirements.txt`)

## Project Overview

CLI tool that boots virtual iPhones (PV=3) via Apple's Virtualization.framework, targeting Private Cloud Compute (PCC) research VMs. Used for iOS security research — firmware patching, boot chain modification, and runtime instrumentation.

## Architecture

```
Makefile                          # Single entry point — run `make help`

sources/
├── vphone.entitlements               # Private API entitlements (5 keys)
└── vphone-cli/                       # Swift 6.0 executable (pure Swift, no ObjC)
    ├── main.swift                    # Entry point — NSApplication + AppDelegate
    ├── VPhoneAppDelegate.swift       # App lifecycle, SIGINT, VM start/stop
    ├── VPhoneCLI.swift               # ArgumentParser options (no execution logic)
    ├── VPhoneVM.swift                # @MainActor VM configuration and lifecycle
    ├── VPhoneHardwareModel.swift     # PV=3 hardware model via Dynamic
    ├── VPhoneVMView.swift            # Touch-enabled VZVirtualMachineView + helpers
    ├── VPhoneWindowController.swift  # @MainActor window management
    ├── VPhoneError.swift             # Error types
    └── MainActor+Isolated.swift      # MainActor.isolated helper

scripts/
├── patchers/                     # Python patcher package
│   ├── iboot.py                  # Dynamic iBoot patcher (iBSS/iBEC/LLB)
│   ├── kernel.py                 # Dynamic kernel patcher (25 patches)
│   ├── txm.py                    # Dynamic TXM patcher
│   └── cfw.py                    # CFW binary patcher
├── resources/                    # Resource archives
│   ├── cfw_input.tar.zst
│   └── ramdisk_input.tar.zst
├── fw_prepare.sh                 # Downloads IPSWs, merges cloudOS into iPhone
├── fw_manifest.py                # Generates hybrid BuildManifest.plist & Restore.plist
├── fw_patch.py                   # Patches 6 boot-chain components (41+ modifications)
├── ramdisk_build.py              # Builds SSH ramdisk with trustcache
├── ramdisk_send.sh               # Sends ramdisk to device via irecovery
├── cfw_install.sh                # Installs custom firmware to VM disk
├── vm_create.sh                  # Creates VM directory (disk, SEP storage, ROMs)
├── setup_venv.sh                 # Creates Python venv with native keystone dylib
└── setup_libimobiledevice.sh     # Builds libimobiledevice toolchain from source

researchs/                        # Component analysis and architecture docs
```

### Key Patterns

- **Private API access:** Private Virtualization.framework APIs are called via the [Dynamic](https://github.com/mhdhejazi/Dynamic) library (runtime method dispatch from pure Swift). No ObjC bridge needed.
- **App lifecycle:** Explicit `main.swift` creates `NSApplication` + `VPhoneAppDelegate`. CLI args parsed before the run loop starts. AppDelegate drives VM start, window, and shutdown.
- **Configuration:** CLI options parsed via `ArgumentParser`, converted to `VPhoneVM.Options` struct, then used to build `VZVirtualMachineConfiguration`.
- **Error handling:** `VPhoneError` enum with `CustomStringConvertible` for user-facing messages.
- **Window management:** `VPhoneWindowController` wraps `NSWindow` + `VZVirtualMachineView`. Window size derived from configurable screen dimensions and scale factor. Touch input translated from mouse events to multi-touch via `VPhoneVMView`.

---

## Firmware Assembly Pipeline

The firmware is a **PCC/iPhone hybrid** — PCC boot infrastructure wrapping iPhone iOS userland.

### Pipeline Stages

```
1. make fw_prepare          Download iPhone + cloudOS IPSWs, merge, generate hybrid plists
        ↓
2. make fw_patch            Patch 6 boot-chain components for signature bypass + debug
        ↓
3. make ramdisk_build       Build SSH ramdisk from SHSH blob, inject tools, sign with IM4M
        ↓
4. make vm_new              Create VM directory (sparse disk, SEP storage, copy ROMs)
        ↓
5. make boot_dfu            Boot VM in DFU mode
        ↓
6. make ramdisk_send        Load boot chain + ramdisk via irecovery
        ↓
7. make cfw_install         Mount Cryptex, patch userland, install jailbreak tools
```

### Component Origins

The firmware merges two Apple IPSWs:
- **iPhone IPSW:** `iPhone17,3_26.1_23B85_Restore.ipsw` (d47ap)
- **cloudOS IPSW:** PCC vresearch101ap IPSW (CDN hash URL)

`fw_prepare.sh` extracts both, then copies cloudOS boot chain into the
iPhone restore directory (`kernelcache.*`, `Firmware/{agx,all_flash,ane,dfu,pmp}/*`,
`Firmware/*.im4p`). The cloudOS extract is deleted after merge.

#### Boot Chain — from PCC (cloudOS / vresearch101ap)

| Component | File | Patched | Patch Purpose |
|-----------|------|---------|---------------|
| AVPBooter | `AVPBooter.vresearch1.bin` | Yes (1) | DGST signature validation bypass |
| LLB | `Firmware/all_flash/LLB.vresearch101.RELEASE.im4p` | Yes (6) | Serial + image4 bypass + boot-args + rootfs + panic |
| iBSS | `Firmware/dfu/iBSS.vresearch101.RELEASE.im4p` | Yes (2) | Serial labels + image4 callback bypass |
| iBEC | `Firmware/dfu/iBEC.vresearch101.RELEASE.im4p` | Yes (3) | Serial + image4 bypass + boot-args |
| SPTM | `Firmware/all_flash/sptm.vresearch1.release.im4p` | No | — |
| TXM | `Firmware/txm.iphoneos.research.im4p` | Yes (1) | Trustcache validation bypass |
| SEP Firmware | `Firmware/all_flash/sep-firmware.vresearch101.RELEASE.im4p` | No | — |
| DeviceTree | `Firmware/all_flash/DeviceTree.vphone600ap.im4p` | No | — |
| KernelCache | `kernelcache.release.vphone600` | Yes (25) | APFS, MAC, debugger, launch constraints, etc. |
| GPU/ANE/PMP | `Firmware/{agx,ane,pmp}/*` | No | — |

> TXM filename says "iphoneos" but is copied from cloudOS IPSW (`fw_prepare.sh` line 81).

#### OS / Filesystem — from iPhone (iPhone17,3)

| Component | Notes |
|-----------|-------|
| OS | iPhone OS image |
| SystemVolume | System partition |
| StaticTrustCache | Static trust cache |
| Ap,SystemVolumeCanonicalMetadata | System volume metadata |

> Cryptex1 components (SystemOS/AppOS DMGs) are **not** included in the BuildManifest.
> They are only needed by `cfw_install.sh` which reads paths from the original iPhone manifest separately.

### Build Identity

`fw_manifest.py` generates a **single** DFU erase-install identity (20 components).
The VM always boots via DFU restore, so only one identity is needed.

| Variant | Boot Chain | Ramdisk |
|---------|-----------|---------|
| `Darwin Cloud Customer Erase Install (IPSW)` | PCC RELEASE (LLB/iBSS/iBEC) + RESEARCH (iBoot/TXM) | PCC erase |

idevicerestore selects this identity by partial-matching `Info.Variant` against
`"Erase Install (IPSW)"` while excluding `"Research"`.

### Patched Components Summary

**Boot chain patches** (`fw_patch.py`) — all 6 targets from **PCC**:

| Component | Patches | Technique |
|-----------|---------|-----------|
| AVPBooter | 1 | `mov x0, #0` (DGST bypass) |
| iBSS | 2 | Dynamic via `patchers/iboot.py` (string anchors, instruction patterns) |
| iBEC | 3 | Dynamic via `patchers/iboot.py` (string anchors, instruction patterns) |
| LLB | 6 | Dynamic via `patchers/iboot.py` (string anchors, instruction patterns) |
| TXM | 1 | Dynamic via `patchers/txm.py` (trustcache hash lookup bypass) |
| KernelCache | 25 | Dynamic via `patchers/kernel.py` (string anchors, ADRP+ADD xrefs, BL frequency) |

**CFW patches** (`patchers/cfw.py` / `cfw_install.sh`) — all 4 targets from **iPhone** Cryptex SystemOS:

| Binary | Technique | Purpose |
|--------|-----------|---------|
| seputil | String patch (`/%s.gl` → `/AA.gl`) | Gigalocker UUID fix |
| launchd_cache_loader | NOP (disassembly-anchored) | Bypass cache validation |
| mobileactivationd | Return true (disassembly-anchored) | Skip activation check |
| launchd.plist | Plist injection | Add bash/dropbear/trollvnc daemons |

### Boot Flow

```
AVPBooter (ROM, PCC)
  → LLB (PCC, patched)
    → iBSS (PCC, patched, DFU)
      → iBEC (PCC, patched, DFU)
        → SPTM + TXM (PCC, TXM patched)
          → KernelCache (PCC, 25 patches)
            → Ramdisk (PCC or iPhone, SSH-injected)
              → iOS userland (iPhone, CFW-patched)
```

### Ramdisk Build (`ramdisk_build.py`)

1. Extract IM4M from SHSH blob
2. Process 8 components: iBSS, iBEC, SPTM, DeviceTree, SEP, TXM, KernelCache, Ramdisk+Trustcache
3. For ramdisk: extract base DMG → create 254 MB APFS volume → mount → inject SSH tools from `resources/ramdisk_input.tar.zst` → re-sign Mach-Os with ldid + signcert.p12 → build trustcache
4. Sign all components with IM4M manifest → output to `Ramdisk/` directory as IMG4 files

### CFW Installation (`cfw_install.sh`)

7 phases, safe to re-run (idempotent):
1. Decrypt/mount Cryptex SystemOS and AppOS DMGs (`ipsw` + `aea`)
2. Patch seputil (gigalocker UUID)
3. Install GPU driver (AppleParavirtGPUMetalIOGPUFamily)
4. Install iosbinpack64 (jailbreak tools)
5. Patch launchd_cache_loader (NOP cache validation)
6. Patch mobileactivationd (activation bypass)
7. Install LaunchDaemons (bash, dropbear SSH, trollvnc)

---

## Coding Conventions

### Swift

- **Language:** Swift 6.0 (strict concurrency).
- **Style:** Pragmatic, minimal. No unnecessary abstractions.
- **Sections:** Use `// MARK: -` to organize code within files.
- **Access control:** Default (internal). Only mark `private` when needed for clarity.
- **Concurrency:** `@MainActor` for VM and UI classes. `nonisolated` delegate methods use `MainActor.isolated {}` to hop back safely.
- **Naming:** Types are `VPhone`-prefixed (`VPhoneVM`, `VPhoneWindowController`). Match Apple framework conventions.
- **Private APIs:** Use `Dynamic()` for runtime method dispatch. Touch objects use `NSClassFromString` + KVC to avoid designated initializer crashes.

### Shell Scripts

- Use `zsh` with `set -euo pipefail`.
- Scripts resolve their own directory via `${0:a:h}` or `$(cd "$(dirname "$0")" && pwd)`.
- Build uses `make build` which handles compilation and entitlement signing.

### Python Scripts

- Firmware patching uses `capstone` (disassembly), `keystone-engine` (assembly), and `pyimg4` (IM4P handling).
- `patchers/kernel.py` uses dynamic pattern finding (string anchors, ADRP+ADD xrefs, BL frequency analysis) — nothing is hardcoded to specific offsets.
- Each patch is logged with offset and before/after state.
- Scripts operate on a VM directory and auto-discover the `*Restore*` subdirectory.
- **Environment:** Use the project venv (`source .venv/bin/activate`). Create with `make setup_venv`. All deps in `requirements.txt`: `capstone`, `keystone-engine`, `pyimg4`.

## Build & Sign

The binary requires private entitlements to use PV=3 virtualization:

- `com.apple.private.virtualization`
- `com.apple.private.virtualization.security-research`
- `com.apple.security.virtualization`
- `com.apple.vm.networking`
- `com.apple.security.get-task-allow`

Always use `make build` — never `swift build` alone, as the unsigned binary will fail at runtime.

## VM Creation (`make vm_new`)

Creates a VM directory with:
- Sparse disk image (default 64 GB)
- SEP storage (512 KB flat file)
- AVPBooter + AVPSEPBooter ROMs (copied from `/System/Library/Frameworks/Virtualization.framework/`)
- machineIdentifier (created on first boot if missing, persisted for stable ECID)
- NVRAM (created/overwritten each boot)

All paths are passed explicitly via CLI (`--rom`, `--disk`, `--nvram`, `--machine-id`, `--sep-storage`, `--sep-rom`). SEP coprocessor is always enabled.

Display is configurable via `--screen-width`, `--screen-height`, `--screen-ppi`, `--screen-scale` (defaults: 1290x2796 @ 460 PPI, scale 3.0).

Override defaults: `make vm_new VM_DIR=myvm DISK_SIZE=32`.

## Design System

### Intent

**Who:** Security researchers working with Apple firmware and virtual devices. Technical, patient, comfortable in terminals. Likely running alongside GDB, serial consoles, and SSH sessions.

**Task:** Boot, configure, and interact with virtual iPhones for firmware research. Monitor boot state, capture serial output, debug at the firmware level.

**Feel:** Like a research instrument. Precise, informative, honest about internal state. No decoration — every pixel earns its place.

### Palette

- **Background:** Dark neutral (`#1a1a1a` — near-black, low blue to reduce eye strain during long sessions)
- **Surface:** `#242424` (elevated panels), `#2e2e2e` (interactive elements)
- **Text primary:** `#e0e0e0` (high contrast without being pure white)
- **Text secondary:** `#888888` (labels, metadata)
- **Accent — status green:** `#4ade80` (VM running, boot success)
- **Accent — amber:** `#fbbf24` (DFU mode, warnings, in-progress states)
- **Accent — red:** `#f87171` (errors, VM stopped with error)
- **Accent — blue:** `#60a5fa` (informational, links, interactive highlights)

Rationale: Dark surfaces match the terminal-adjacent workflow. Status colors borrow from oscilloscope/JTAG tooling — green for good, amber for attention, red for fault. No brand colors — this is a tool, not a product.

### Typography

- **UI font:** System monospace (SF Mono / Menlo). Everything in this tool is technical — monospace respects the content.
- **Headings:** System sans (SF Pro) semibold, used sparingly for section labels only.
- **Serial/log output:** Monospace, `#e0e0e0` on dark background. No syntax highlighting — raw output, exactly as received.

### Depth

- **Approach:** Flat with subtle 1px borders (`#333333`). No shadows, no blur. Depth through color difference only.
- **Rationale:** Shadows suggest consumer software. Borders suggest instrument panels. This is an instrument.

### Spacing

- **Base unit:** 8px
- **Component padding:** 12px (1.5 units)
- **Section gaps:** 16px (2 units)
- **Window margins:** 16px

### Components

- **Status indicator:** Small circle (8px) with color fill + label. No animation — state changes are instantaneous.
- **VM display:** Full-bleed within its container. No rounded corners on the display itself.
- **Log output:** Scrolling monospace region, bottom-anchored (newest at bottom). No line numbers unless requested.
- **Toolbar (if present):** Icon-only, 32px touch targets, subtle hover state (`#2e2e2e` -> `#3a3a3a`).
