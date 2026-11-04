# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Quick Reference

- **Build:** `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build`
- **Test:** Run the Xcode test schemes in their owning projects. The `VPhone` build validates the finished bundle.
- **Boot (GUI):** `vphone-cli vm launch <name>`
- **Boot (DFU):** `vphone-cli vm launch <name> --dfu`
- **AMFI refuses `vphone-vm`?** Launchpad uses its SMJobBless helper to run the installed bundle's `vphone-escalator` after checking its receipt. Standalone CLI users can run the allowlist tool as shown in `Documents/Guides/host-setup.md`. Repeat after the VM cdhash changes.
- **Restore:** `vphone-cli restore` runs in process over the vendored recovery and restore C modules in `VPhoneExecutable/VPhoneCommand/VPhoneRestore`.
- **Platform:** macOS 15+ (Sequoia). `vphone-vm` needs amfid to accept its private entitlements: either SIP off with `amfi_get_out_of_my_way=1`, or SIP on (`--without debug`) plus an allowlist bypass. Both are in `Documents/Guides/host-setup.md`. Launchpad's bundle preflight checks SIP and Research Guests and applies the allowlist through its installed helper.
- **Language:** Swift 6.0 in handwritten Xcode projects, private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic).
- **Dependencies:** Host and guest SwiftPM packages resolve dependencies by URL and version; `Package.resolved` pins the full graphs. There are no git submodules. **No Python anywhere, and no Homebrew package at runtime** — see Tiers below.
- **Installing an app on a guest: not `devicectl`.** `xcrun devicectl device install app` / `process launch` time out against vphone guests; do not use them. To go through installd (the path Xcode takes, and the only one that exercises the install-gate hooks), use `ideviceinstaller -u <UDID> install <ipa>`. vphoned's `apps.install` bypasses installd — it re-signs and places the bundle itself — so it proves nothing about installd. Launch with the `apps.launch` RPC.
- **Tiers.** The build machine may use Xcode and build tools. The shipped `VPhone.bundle` must use only system libraries and its own contents at runtime. Guest components run inside the VM. `Build/ValidateBundle.sh` checks bundle admission as part of the `VPhone` build.

## Workflow Rules

- Do not create, read, or update `/TODO.md`.
- Ignore `/TODO.md` if it exists locally; it is intentionally not part of the repo workflow anymore.
- Track plan, progress, assumptions, blockers, and next actions in commit history, code comments when warranted, and current research docs instead of a repo TODO file.

For any changes applying new patches, also update Research/0_binary_patch_comparison.md. Dont forget this.

## Local Skills

- If working on kernel analysis, symbolication lookups, or kernel patch reasoning, read `Skills/kernel-analysis-vphone600/SKILL.md` first.
- Use this skill as the default procedure for `vphone600` kernel work.
- If adding or changing a patch, a patch set, or a preset, read `Skills/authoring-patch-sets/SKILL.md` first. Every patch is declared in a patch set and selected by a preset; a patch in no manifest cannot be turned off and warns on every run.

## Firmware Mode

The public CLI exposes only JB: `vphone-cli fw patch` and `vphone-cli cfw install`.
The guest contains vphoned and required system patches; package-manager
bootstrap and first-boot installation are outside this project. Do not add
another public variant.

See `Research/` for detailed firmware pipeline, component origins, patch breakdowns, and boot flow documentation.

## Architecture

`VPhone.xcworkspace` contains handwritten Xcode projects. Do not introduce project generators, SwiftPM app targets, recovered references, or linked source folders. Source folders should carry the owning project or target name.

- `VPhoneExecutable/VPhoneVirtualization`: `VPhone.bundle`, `vphone-vm`, and `VPhoneVirtualMachineKit`. The bundle is the distributable output and has no app launcher.
- `VPhoneExecutable/VPhoneCommand`: `vphone-cli`, firmware patcher, signer, and command tests.
- `VPhoneExecutable/VPhoneCommand/VPhoneRestore`: native restore code and tests.
- `VPhoneExecutable/VPhoneEscalator`: the AMFI allowlist program, built for arm64e. It is not a general privilege service.
- `VPhoneKit`: shared core, archive, and external access kits with their tests.
- `VPhoneDaemon`: guest `vphoned`, native operations, and daemon configuration.
- `VPhoneGuestComponents`: guest dylibs built by Makefile from the bundle build phase.
- `VPhoneWebsite`: the documentation site (Rspress, Node at build time only). `scripts/sync-docs.mjs` generates its pages from `README.md`, `Documents/` and the section tables of `Documents/README.md`, which also make the sidebar; `Documents/` stays the only source. `.github/workflows/website.yml` builds it and deploys GitHub Pages from main.
- `VPhoneLaunchpad`: `vphone-launchpad.app`, the workstation app that downloads and manages `VPhone.bundle` releases and drives each VM through the `vphone-cli` of the Core Bundle that machine is bound to (`launchpad.json` in the machine folder; the default bundle only seeds new machines and library-wide commands), plus its SMJobBless helper `com.vphone.launchpad.helper`, `vphone-launchpad-cli`, a stateless client of the running app over a same-user Unix socket (`Documents/Guides/launchpad-cli.md`; use it to install and test a local `VPhone.bundle` build), and `vphone-launchpad-launcher`, the responsible process for each VM it starts. Shipped separately from the bundle. Settings live only in `VPhoneLaunchpad/Configuration/*.xcconfig`; the pbxproj holds none.

The `VPhone` scheme puts host programs in `VPhone.bundle/Contents/MacOS` and everything installed into the guest (vphoned, guest dylibs, their plists) in `Contents/Resources/guest-resources`. Xcode targets have `CODE_SIGNING_ALLOWED=NO`; the bundle build phase signs each binary ad hoc with only its own entitlements, then seals the outer bundle. `VPhoneVirtualization.entitlements` belongs to `vphone-vm`; `VPhoneDaemon.entitlements` belongs to `vphoned`. The bundle and CLI have no private entitlements.

### Key Patterns

- New machines boot **OpenAVB**, not Apple's AVPBooter: `VPhone.bundle/Contents/Resources/OpenAVB/OpenAVB.bin`, checked in prebuilt under `VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/` from a pinned OpenAVB commit plus any patches in `patches/` beside it (none at present). Rebuild or check it only with `Build/UpdateOpenAVB.sh` (Homebrew LLVM/LLD, outside the repo). `fw patch` skips AVPBooter on an OpenAVB machine; `vphone-cli restore` uploads the iBSS identity first (`MobileRestoreCore/Recovery/openavb.c`); `vm config --rom` switches ROM. See `Research/Firmware/openavb_boot_rom.md`.
- New machines start the SEP from **OpenSEP**, not Apple's AVPSEPBooter: `VPhone.bundle/Contents/Resources/OpenSEP/OpenSEP.bin`, checked in prebuilt under `VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/` from a pinned OpenSEP commit (`vresearch1` platform) plus any patches in `patches/` beside it. Rebuild or check it only with `Build/UpdateOpenSEP.sh`. Neither SEP ROM is patched; `vm config --seprom` switches it without a restore. See `Research/Firmware/opensep_sep_rom.md`.

- `vphone-cli` is the unentitled entry point. `VPhoneGuestLaunchPlanner` resolves `vphone-vm` beside the running executable, checks its entitlements, probes AMFI, and reports the exact allowlist command on refusal. It never obtains root itself.
- `vphone-escalator` manages AMFI cdhash admission only. It writes amfid heap state, not executable code. Root authorization belongs to the user or to `vphone-launchpad`; neither `vphone-cli` nor the bundle has an SMJobBless or sudo password flow.
- `vphone-launchpad` has no private entitlements. `SignLaunchpad.sh` gives its main executable two hardened-runtime resource entitlements, microphone (`com.apple.security.device.audio-input`) and location (`com.apple.security.personal-information.location`), from `VPhoneLaunchpad/Resources/VPhoneLaunchpad.entitlements`; its helper, CLI and launcher have none. It asks for Developer Tools access (`EPDeveloperTool`) and adds an `EPExecutionPolicy` exception for each installed bundle. `EPDeveloperTool.authorizationStatus` keeps the value the process launched with, while syspolicyd checks the live grant on every exception request, so Host Setup judges access by asking for an exception for Launchpad's own executable; a grant or a revocation in Settings applies without a relaunch. Its helper is the only root surface: it installs verified releases into the root-owned store `/Library/Application Support/vphone-launchpad/Bundles`, runs that bundle's `vphone-escalator allow` for its receipt-pinned `vphone-vm`, runs `cfw install` from that store after rechecking the recorded cdhash, and runs that store bundle's `vphone-cli vm leases --release-orphans` for the caller's own library folders. There is no generic command verb. Launchpad starts `vm launch` detached (own session, responsibility disclaimed) through `vphone-launchpad-launcher` in its `Contents/MacOS`, which starts `vphone-cli` as an ordinary child and stays until it exits, forwarding stop signals and exiting the same way. The launcher is therefore the responsible process for `vphone-vm`. As a tool in the app's `Contents/MacOS` it is attributed to the app, so privacy prompts, usage descriptions and grants (microphone, location) are the app's, asked once for its Developer ID signature instead of for each ad hoc signed bundle build; under the hardened runtime macOS refuses them without asking unless the app carries the matching entitlement. It refuses anything but `vm launch` of a `vphone-cli` in the root-owned store (`VPhoneLaunchpadLauncherPolicy`); without the launcher, Launchpad starts `vphone-cli` directly. Nothing is signed at build time: `VPhoneLaunchpad/Build/SignLaunchpad.sh` signs afterwards, and the team comes from the gitignored `Configuration/Developer.xcconfig`. Never commit a team ID.
- Launchpad and `VPhone.bundle` match by series, the first two numbers of the version: Launchpad 2.2.3 works with any `VPhone.bundle` 2.2.x, and the reverse. Patch releases within a series must stay interchangeable in both directions. A change to anything Launchpad relies on in the bundle (`vphone-cli` arguments or output, `vphone-escalator`, the bundle layout or receipt) needs a new minor version and a raised `minimumBundleComponents` in `VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift`. `Documents/Downloads/README.md` states this rule to users.
- Host VM artifacts, caches, and archives created by vphone use mode `0777` for workstation access. Symlinks are not followed when changing permissions. Guest filesystem modes inside `Disk.img` remain unchanged.
- `VPhoneRestore` runs in the CLI process over vendored libirecovery and idevicerestore. No Python or runtime Homebrew dependency is allowed.
- The VM process owns AppKit windows and the guest control connection. `vphoned` serves HTTP and WebSocket over VSOCK 1339, with camera data on 1338.
- The guest HTTP client, menus, file browser, IPA installation, and screen recorder live in `VPhoneVirtualMachineKit`.

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

Every patcher is Swift, in `VPhoneExecutable/VPhoneCommand/FirmwarePatcher`.
The public firmware mode is JB; the CFW/DSC patchers are `vphone-cli cfw <verb>`.

- Disassembly is Capstone via `ARM64Disassembler` (the `libcapstone-spm` package). Assembly is `ARM64Encoder` plus the pre-encoded constants in `ARM64` (`ARM64Constants.swift`) — together they replace keystone's `asm()` / `asm_at()`, and `ARM64.nop` / `ARM64.movW0_0` are the old `NOP` / `MOV_W0_0`. IM4P containers go through `IM4PHandler` (the `libimg4-spm` package), which replaces pyimg4. Both resolve by URL; there is no `vendor/` directory to check out first.
- Dynamic pattern finding (string anchors, ADRP+ADD xrefs, BL frequency) — no hardcoded offsets.
- Each patch logged with offset and before/after state.
- No interpreter or runtime native-library repair: the `VPhone` Xcode scheme builds the complete bundle.

### Python

There is none, and adding any is a regression.

- No `.py` file is tracked in this repository, no shell script embeds a Python
  heredoc, and nothing resolves a `python3` at runtime. `git ls-files '*.py'`
  returns nothing; that is the standing check.
- There is no environment to activate and no dependency list to install. The
  restore backend was the last holdout and is now `VPhoneExecutable/VPhoneCommand/VPhoneRestore` over
  two vendored C targets — see `Research/Restore/native_restore_architecture.md`.
- A patch, a probe, a format reader or a device protocol belongs in Swift,
  where it is built, signed, gated by `Build/ValidateBundle.sh` and tested with
  everything else. Adding an interpreter back brings with it a provisioning
  step, a silent system-`python3` fallback, and a dependency closure
  `Build/ValidateBundle.sh` cannot see.
- There is no counter-example left. `amfidont` used to be cited as one — a
  third-party tool the user installed into their own Python — and it is gone
  too: the AMFI allowlist tool is `VPhoneExecutable/VPhoneEscalator`, a few C
  files built by Xcode for arm64e, with no runtime interpreter or LLDB.

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible. `ARM64Disassembler` is the only decoder — match on the decoded mnemonic and operand detail, never on a formatted operand string.
- All replacement instruction bytes must come from Keystone-backed helpers already used by the project: `ARM64Encoder.encode*` and the `ARM64` constants, which were generated by keystone-engine, verified by Capstone round-trip, and are asserted word for word against keystone in `VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/Core/ARM64EncoderTests.swift`. Never write a literal instruction word at a patch site. A new instruction means a new encoder plus its keystone-checked test case, not a raw `Data`. Keystone is deliberately **not** a project dependency any more — nothing at runtime or in the test suite calls it, and the expected words are frozen constants. To derive a new one, stand keystone up in a throwaway environment **outside this repository** (`brew install keystone`, plus `keystone-engine` in a scratch interpreter somewhere under `/tmp`) and run the one-liner in that test file's header against it. There is no dependency list here to add it to and no environment here to install it into; creating either is the regression the "Python" section above forbids. Do not invent an expected word without checking it.
- Prefer source-backed semantic anchors: in-image symbol lookup, string xrefs, local call-flow, and XNU correlation. Do not depend on repo-exported per-kernel symbol dumps at runtime.
- When retargeting a patch, write the reveal procedure and validation steps into the relevant research doc or commit notes before handing off for testing. Do not create `TODO.md`.
- For `patchBsdInitAuth` (`Kernel/CustomFirmwarePatches/Storage/KernelCustomFirmwarePatchBsdInitAuth.swift`, named `patch_bsd_init_auth` in the research docs) specifically, the allowed reveal flow is: recover `bsd_init` -> locate rootvp panic block -> find the unique in-function `call` -> `cbnz w0/x0, panic` -> `bl imageboot_needed` site -> patch the branch gate only.

## Build & Sign

The VM process requires private entitlements for PV=3 virtualization. Build the `VPhone` scheme in Xcode; its final build phase ad hoc signs each child and seals `VPhone.bundle`. `swift build` alone does not produce the distributable bundle.

## Design System

- **Audience:** Security researchers. Terminal-adjacent workflow.
- **Feel:** Research instrument — precise, informative, no decoration.
- **Palette:** Dark neutral (`#1a1a1a` bg), status green/amber/red/blue accents.
- **Typography:** System monospace (SF Mono / Menlo) for UI and log output.
- **Depth:** Flat with 1px borders (`#333333`). No shadows.
- **Spacing:** 8px base unit, 12px component padding, 16px section gaps.

`vphone-launchpad` is the exception: it is a native SwiftUI Mac app. It uses system controls, grouped `Form`s, `Table`, SF Symbols, toolbar buttons for page actions, and the system appearance. Monospace is only for command text and logs.
