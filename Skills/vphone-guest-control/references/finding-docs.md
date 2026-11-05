# Where to look when something goes wrong

The repository holds the evidence behind almost every behavior. Reading the
right note is faster and safer than experimenting on the user's machine, and
many notes record the exact symptom, the cause and the fix. Paths are relative
to the vphone-cli repository root. If you have no checkout, read the same files
at <https://github.com/Lakr233/vphone-cli> (`Documents/`, `Research/`), or on the documentation site
<https://lakr233.github.io/vphone-cli/>.

Order of preference: **the user guides** (current instructions) first, then
**`Research/`** (evidence and history, may mention retired commands), then the
**source**, then `git log`. `Research/` notes say so when they describe an
earlier experiment; trust `vphone-launchpad-cli help` and the guides over a
note's command lines.

## Contents

- By symptom
- By subject
- Searching
- Source layout
- When to stop and report

## By symptom

| Symptom | Start with |
| --- | --- |
| `vphone-vm` killed before a window opens; AMFI; "Research Guests" | `Documents/en/get-started/host-setup.md`, `Documents/en/help/troubleshooting.md`, `Research/Host/macos27_m6_amfi.md` |
| Launchpad/bundle version mismatch, which Launchpad is notarized | `Documents/en/get-started/downloads.md`, `Documents/en/launchpad/bundle-integration.md` |
| `vm create` failed at a step; restore or DFU trouble | `Documents/en/machines/create-and-run.md`, `Documents/en/firmware/firmware-preparation.md`, `Documents/en/firmware/compatibility.md`, `Research/Restore/native_restore_architecture.md`, `Research/Restore/virtual_dfu_probe.md` |
| Which iPhone IPSW pairs with which cloudOS | `Documents/en/firmware/compatibility.md`; `vphone-cli fw catalog` (via `exec`) for what exists now |
| Guest boots to a black screen or loops | `Documents/en/help/troubleshooting.md`, `Research/Patches/hv_vmm_present_usermode_xrefs.md`, `Research/Kernel/kernel_jb_patch_notes.md` |
| `EXC_GUARD` / `GUARD_TYPE_MACH_PORT` in an app | `Documents/en/help/troubleshooting.md`, `Research/KernelCustomFirmwarePatches/README.md` |
| No package manager, no ssh, bootstrap install | `Documents/en/machines/package-environment.md`, [guest-layout](guest-layout.md), `Research/Guest/roothide_bootstrap_base.md` |
| `dyld ... @loader_path/.jbroot/...` crash, `sudo` fails to load a library | `Research/roothide_loader_links.md` |
| ssh closes at once or `PAM: initialisation failed`, "no such user" | `Research/Guest/roothide_bootstrap_base.md` (open issues section) |
| An RPC method's parameters, errors, or capability flags | `Research/vphoned_http_api.md` ("Method catalog", "HTTP and WebSocket contract") |
| The host API listener, token, 401/403/415 | `Research/vphoned_http_api.md` ("Access control") |
| Taps or swipes land in the wrong place; gestures; keyboard | `Research/Guest/trackpad_gesture_mapping.md`, `Research/Guest/keyboard_event_pipeline.md` |
| Skipping Setup Assistant, device state after boot | `Research/Guest/setup_assistant_skip.md` |
| Developer Mode, DDI mount errors | `Research/Guest/devmode_xpc_protocol.md` |
| App install fails, signature, profile checks, UDID | `Research/Guest/xcode_install_signature_gate.md` |
| Instruments stacks are bare addresses, `unable to create symbolicator`, a system bundle's seal is invalid | `Research/Guest/instruments_symbolication.md` |
| Location simulation returns `unavailable` | `Research/Guest/location_simulation_26_4_failure.md` |
| `location.*` times out after 120 s, or every CoreLocation client hangs | `Research/Guest/locationd_startup_deadlock.md` |
| Camera / virtual camera | `Research/Guest/virtual_camera_transport.md` |
| Machine identity, clone behaving like the same device | `Research/Guest/machine_identifier_storage_analysis.md` |
| What a patch does, whether it is on, why a preset differs | `Research/0_binary_patch_comparison.md`, `Research/KernelCustomFirmwarePatches/README.md` |
| Which binary does what in the bundle | `Research/Host/host_binary_split.md`, `Documents/en/launchpad/bundle-integration.md` |
| Launchpad command line; Core Bundles and local builds | `Documents/en/launchpad/launchpad-cli.md`, `Documents/en/launchpad/core-bundles.md` |

## By subject

- **User manual** (`Documents/en/`, also at <https://lakr233.github.io/vphone-cli/>):
  `get-started/` (overview, quick-start, host-setup, downloads), `machines/`
  (create-and-run, boot-roms, automation-api, device-name-and-clock,
  package-environment), `firmware/` (compatibility, firmware-preparation,
  iphone-models, ipados), `storage/` (library-and-backups, snapshots,
  templates, template-building, sharing-disk-space, many-machines,
  shader-cache), `networking/`, `launchpad/` (launchpad-cli, core-bundles,
  bundle-integration) and `help/troubleshooting`. `Documents/en/README.md`
  indexes them; `zh/`, `ja/` and `ko/` are translations of the same tree.
- **Research index:** `Research/README.md` lists every note by subject
  (firmware, kernel, restore, host, guest, history).
- **Patch inventory:** `Research/0_binary_patch_comparison.md` is canonical for
  what each patch changes.
- **Kernel evidence:** `Research/Kernel/` and
  `Research/KernelCustomFirmwarePatches/` (one note per patch).
  Kernel analysis and symbol lookups have their own procedure in
  `Skills/kernel-analysis-vphone600/SKILL.md`; read it before touching them.
- **Patch authoring:** `Skills/authoring-patch-sets/SKILL.md`.
- **History:** `Research/History/` is a preserved snapshot; it can describe
  scripts and variants that no longer exist.

## Searching

```sh
grep -rn "PAM: initialisation" Research Documents          # an exact error string
grep -rln "bootstrap.install" Research Documents VPhoneDaemon
git log --oneline --all -i --grep "roothide" | head -20     # why something changed
```

Search the exact error text first; the notes were written from real failures
and quote them. Then search the RPC or file name. Issue numbers in notes
(`#519`, `#520`) are GitHub issues in `Lakr233/vphone-cli`; `gh issue view 520`
reads one.

## Source layout

| Question | Look in |
| --- | --- |
| What does a Launchpad CLI command do | `VPhoneLaunchpad/VPhoneLaunchpad/Control/VPhoneLaunchpadControlCommands.swift`; command table in `VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadControl.swift` |
| What does `vphone.sock` accept | `VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift` (header comment lists the verbs) |
| An RPC method's parameters | `VPhoneDaemon/Daemon/GuestAPI.swift` and `GuestAPI+<Area>.swift` |
| Bootstrap install | `VPhoneDaemon/Daemon/Bootstrap/GuestIrisinInstaller.swift` |
| Creation steps | `VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadCreationPipeline.swift` |
| Firmware patches | `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/` |

## When to stop and report

Stop and tell the user, with the log path and the note you read, when:

- the fix needs a host security change (SIP, boot-args, AMFI) or an
  administrator password;
- the note says the symptom is an open issue (check the "Open issues" sections);
- the next step would destroy state: uninstalling a bootstrap, `cfw install`,
  recreating a machine, removing a bundle;
- the same fix has failed twice. A third blind attempt on a user's guest costs
  more than a question.

A new finding that is not in these docs belongs in a `Research/` note and the
commit message, not in a scratch file.
