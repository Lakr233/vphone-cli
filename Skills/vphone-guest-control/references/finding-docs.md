# Where to look when something goes wrong

The repository holds the evidence behind almost every behavior. Reading the
right note is faster and safer than experimenting on the user's machine. Paths
are relative to the vphone-cli repository root. With no checkout, read the same
files at <https://github.com/Lakr233/vphone-cli> (`Documents/`, `Research/`).

Order of preference: **the user guides** (`Documents/en/`, current) first, then
**`Research/`** (evidence and history, may mention retired commands), then the
**source**, then the commit log. Trust `vphone-launchpad-cli help` and the
guides over a note's command lines. Symptoms with a fix are in
[troubleshooting](troubleshooting.md).

## Contents

- By symptom
- By subject
- When to stop and report

## By symptom

| Symptom | Start with |
| --- | --- |
| AMFI kill, "Research Guests" | `Documents/en/get-started/host-setup.md`, `Research/Host/macos27_m6_amfi.md` |
| Launchpad/bundle version mismatch | `Documents/en/get-started/downloads.md`, `Documents/en/launchpad/bundle-integration.md` |
| `vm create` failed; restore or DFU trouble | `Documents/en/machines/create-and-run.md`, `Documents/en/firmware/compatibility.md`, `Research/Restore/native_restore_architecture.md`, `Research/Restore/virtual_dfu_probe.md` |
| Black screen, `EXC_GUARD` | `Documents/en/help/troubleshooting.md`, `Research/Patches/hv_vmm_present_usermode_xrefs.md`, `Research/KernelCustomFirmwarePatches/README.md` |
| No package manager or ssh; ssh `PAM: initialisation failed` | `Documents/en/machines/package-environment.md`, `Research/Guest/roothide_bootstrap_base.md` |
| `@loader_path/.jbroot/...` crash | `Research/roothide_loader_links.md` |
| An RPC method's parameters or errors | `Research/vphoned_http_api.md` ("Method catalog") |
| Host API listener, token, 401/403/415/502 | `Research/vphoned_http_api.md` ("Access control") |
| Taps, swipes, keyboard | `Research/Guest/trackpad_gesture_mapping.md`, `Research/Guest/keyboard_event_pipeline.md` |
| What a patch does, why a preset differs | `Research/0_binary_patch_comparison.md`, `Research/KernelCustomFirmwarePatches/README.md` |
| Launchpad command line, Core Bundles | `Documents/en/launchpad/launchpad-cli.md`, `Documents/en/launchpad/core-bundles.md` |

## By subject

- **User manual:** `Documents/en/` (also <https://lakr233.github.io/vphone-cli/>);
  `Documents/en/README.md` indexes it.
- **Research index:** `Research/README.md` lists every note by subject.
- **Kernel analysis:** `Skills/kernel-analysis-vphone600/SKILL.md`; patch
  authoring: `Skills/authoring-patch-sets/SKILL.md`.
- **History:** `Research/History/` is a preserved snapshot and can describe
  scripts that no longer exist.

## When to stop and report

Stop and tell the user, with the log path and the note you read, when:

- the fix needs a host security change (SIP, boot-args, AMFI) or an
  administrator password;
- the note says the symptom is an open issue;
- the next step would destroy state: uninstalling a bootstrap, `cfw install`,
  recreating a machine, removing a bundle;
- the same fix has failed twice.
