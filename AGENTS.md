# vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs.

## Quick Reference

- **Build:** `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build`
- **Test:** Run the Xcode test schemes in their owning projects. The `VPhone` build validates the finished bundle.
- **Boot (GUI):** `vphone-cli vm launch <name>`
- **Boot (DFU):** `vphone-cli vm launch <name> --dfu`
- **AMFI refuses `vphone-vm`?** Launchpad uses its SMJobBless helper to run the installed bundle's `VPhoneEscalator` after checking its receipt. Standalone CLI users can run the allowlist tool as shown in `Documents/Guides/host-setup.md`. Repeat after the VM cdhash changes.
- **Restore:** `vphone-cli restore` runs in process over the vendored recovery and restore C modules in `VPhoneExecutable/VPhoneCommand/VPhoneRestore`.
- **Platform:** macOS 15+ (Sequoia). `vphone-vm` needs amfid to accept its private entitlements: either SIP off with `amfi_get_out_of_my_way=1`, or SIP on (`--without debug`) plus an allowlist bypass. Both are in `Documents/Guides/host-setup.md`. Launchpad's bundle preflight checks SIP and Research Guests and applies the allowlist through its installed helper.
- **Language:** Swift 6.0 in handwritten Xcode projects, private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic).
- **Dependencies:** Host and guest SwiftPM packages resolve dependencies by URL and version; `Package.resolved` pins the full graphs. There are no git submodules. **No Python anywhere, and no Homebrew package at runtime** — see Tiers below.
- **Tiers.** The build machine may use Xcode and build tools. The shipped `VPhone.bundle` must use only system libraries and its own contents at runtime. Guest components run inside the VM. `Build/ValidateBundle.sh` checks bundle admission as part of the `VPhone` build.

## Workflow Rules

- Do not create, read, or update `/TODO.md`.
- Ignore `/TODO.md` if it exists locally; it is intentionally not part of the repo workflow anymore.
- Track plan, progress, assumptions, blockers, and next actions in commit history, code comments when warranted, and current research docs instead of a repo TODO file.

For any changes applying new patches, also update Research/0_binary_patch_comparison.md. Dont forget this.

## Local Skills

- If working on kernel analysis, symbolication lookups, or kernel patch reasoning, read `Skills/kernel-analysis-vphone600/SKILL.md` first.
- Use this skill as the default procedure for `vphone600` kernel work.

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
- `VPhoneLaunchpad`: `vphone-launchpad.app`, the workstation app that downloads and manages `VPhone.bundle` releases and drives VMs through the active bundle's `vphone-cli`, plus its SMJobBless helper `com.vphone.launchpad.helper`. Shipped separately from the bundle. Settings live only in `VPhoneLaunchpad/Configuration/*.xcconfig`; the pbxproj holds none.

The `VPhone` scheme puts all shipped Mach-O files in `VPhone.bundle/Contents/MacOS`. Guest configuration is in `Contents/Resources`. Xcode targets have `CODE_SIGNING_ALLOWED=NO`; the bundle build phase signs each binary ad hoc with only its own entitlements, then seals the outer bundle. `VPhoneVirtualization.entitlements` belongs to `vphone-vm`; `VPhoneDaemon.entitlements` belongs to `vphoned`. The bundle and CLI have no private entitlements.

### Key Patterns

- `vphone-cli` is the unentitled entry point. `VPhoneGuestLaunchPlanner` resolves `vphone-vm` beside the running executable, checks its entitlements, probes AMFI, and reports the exact allowlist command on refusal. It never obtains root itself.
- `VPhoneEscalator` manages AMFI cdhash admission only. It writes amfid heap state, not executable code. Root authorization belongs to the user or to `vphone-launchpad`; neither `vphone-cli` nor the bundle has an SMJobBless or sudo password flow.
- `vphone-launchpad` has no entitlements. It asks for Developer Tools access (`EPDeveloperTool`) and adds an `EPExecutionPolicy` exception for each installed bundle. Its helper is the only root surface: it installs verified releases into the root-owned store `/Library/Application Support/vphone-launchpad/Bundles`, runs that bundle's `VPhoneEscalator allow` for its receipt-pinned `vphone-vm`, and runs `cfw install` from that store after rechecking the recorded cdhash. There is no generic command verb. Nothing is signed at build time: `VPhoneLaunchpad/Build/SignLaunchpad.sh` signs afterwards, and the team comes from the gitignored `Configuration/Developer.xcconfig`. Never commit a team ID.
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
  too: the AMFI allowlist tool is `VPhoneExecutable/VPhoneEscalator`, one C
  file built by Xcode for arm64e, with no runtime interpreter or LLDB.

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible. `ARM64Disassembler` is the only decoder — match on the decoded mnemonic and operand detail, never on a formatted operand string.
- All replacement instruction bytes must come from Keystone-backed helpers already used by the project: `ARM64Encoder.encode*` and the `ARM64` constants, which were generated by keystone-engine, verified by Capstone round-trip, and are asserted word for word against keystone in `VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/Core/ARM64EncoderTests.swift`. Never write a literal instruction word at a patch site. A new instruction means a new encoder plus its keystone-checked test case, not a raw `Data`. Keystone is deliberately **not** a project dependency any more — nothing at runtime or in the test suite calls it, and the expected words are frozen constants. To derive a new one, stand keystone up in a throwaway environment **outside this repository** (`brew install keystone`, plus `keystone-engine` in a scratch interpreter somewhere under `/tmp`) and run the one-liner in that test file's header against it. There is no dependency list here to add it to and no environment here to install it into; creating either is the regression the "Python" section above forbids. Do not invent an expected word without checking it.
- Prefer source-backed semantic anchors: in-image symbol lookup, string xrefs, local call-flow, and XNU correlation. Do not depend on repo-exported per-kernel symbol dumps at runtime.
- When retargeting a patch, write the reveal procedure and validation steps into the relevant research doc or commit notes before handing off for testing. Do not create `TODO.md`.
- For `patchBsdInitAuth` (`Kernel/JailbreakPatches/Storage/KernelJailbreakPatchBsdInitAuth.swift`, named `patch_bsd_init_auth` in the research docs) specifically, the allowed reveal flow is: recover `bsd_init` -> locate rootvp panic block -> find the unique in-function `call` -> `cbnz w0/x0, panic` -> `bl imageboot_needed` site -> patch the branch gate only.

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
