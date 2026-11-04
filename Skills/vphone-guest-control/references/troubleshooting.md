# Troubleshooting

Work from the symptom to the first thing worth checking. Each entry says what
to read, so the fix comes from evidence on the user's own guest. For deeper
background, [finding-docs](finding-docs.md) maps symptoms to the repository's
notes.

## Contents

- Setup and host
- Creating a machine
- Starting a machine
- Talking to the guest
- Black screen
- Apps and the bootstrap
- Reporting

## Setup and host

| Symptom | Cause and what to do |
| --- | --- |
| `vphone-launchpad-cli: command not found` | Not installed or not on PATH. [install](install.md) |
| `canInstallBundles: false` | `helper` is missing or outdated, or Developer Tools access is not granted. The user fixes it in Launchpad's Host Setup; `status` reads the grant again, no relaunch needed |
| "Unable to Start <name>" with "did not pass host preflight", or "is not installed" | The machine's own bundle (`vm list` → `bundle`) failed its checks or is gone. `bundle verify <version>`, then read `bundle list` → `preflightDetail`; for a missing one, install it or `vm set-bundle` to another version |
| `vphone-vm` is killed before a window opens | AMFI refused the entitled binary. `bundle verify`; a rebuilt bundle has a new cdhash and needs the allowlist again. Host SIP/AMFI settings are the owner's to change |
| Prompt for an administrator password | Expected after the helper's five-minute authorization lapses. Tell the user; do not loop |
| Launchpad too old for the bundle | Series mismatch. Update Launchpad; do not install a newer-series bundle |

## Creating a machine

- Read the failing step from the report (`steps[].status`) and then
  `vm log <name> --kind create --lines 200` (also `dfu`, `patch`).
- Retry from the step with `--from <step>` only if this Launchpad run started
  the creation. Otherwise create again under a **new** name.
- Out of disk shows up late and confusingly. Check free space before retrying.
- The first-boot check waits up to 300 s. A guest that boots but never answers
  is a vphoned problem; look at the console log.
- Do not run two creations at once.

## Starting a machine

| Symptom | Check |
| --- | --- |
| "already running or busy" | `vm list`; wait for the activity, or `vm stop` |
| `--wait` times out | `vm log <name> --lines 200`; look for a panic line. First boots can exceed 300 s; retry with `--timeout 900` before concluding |
| "had a kernel panic" | The log path is in the error. Report it; do not retry blindly |
| "stopped before vphoned answered" | The VM process exited; read the console log tail |
| `controlSocket` is null | The machine is not serving its socket yet |

## Talking to the guest

- **`guest not connected`** (the app shows `客体代理未连接`) in the middle of a call.
  Through the CLI this is exit 1 with the detail on stderr:
  the guest connection flapped. Retry after a second, up to a handful of
  times. If it persists while vphoned's PID has not changed, suspect the reply
  size: vsock close drops replies of roughly 8–16 KiB. Re-ask with `limit`,
  `max_lines`, `max_elements` or a narrower `filter`.
- **`unknown method`:** the guest's vphoned is older than the bundle. Stop the
  machine and run `cfw update-environment <name>`.
- **`ok` but nothing changed on screen:** inputs are asynchronous; wait for the
  attached `image` or take a screenshot. A locked or asleep screen swallows
  taps: run `guest unlock <name>`, or on an older vphoned press `power`, then
  `home`.
- **Taps land in the wrong place:** the socket takes pixels (1290×2796); the
  `input.*` RPCs take points. Use `ui.tree` / `ui.tap_element` instead.
- **Port 22 refused over iproxy:** no sshd yet. Use RPC; see
  [guest-layout](guest-layout.md).

## Black screen

SpringBoard alive but the screen stays black (near-zero CPU) means data
migration is hung, not that the display is broken.

1. `processes.list` with `{"filter":"SpringBoard"}`: check `cpu_seconds` and
   `start_time` for a stuck process.
2. `logs.crashes {}` and look for `stacks+com.apple.datamigrator-*.ips`. Read it
   with `logs.crash {"path":…}`; its `reason` names the plugin, and the
   stackshot's `turnstileInfo` chain shows what it is waiting on.
3. If the chain ends in a crashing system daemon, pull that binary with
   `files.read {"path":…, "binary":true, "limit":…}` and read its crash report.
   One known cause was a daemon crash-looping on a hypervisor-presence check.
4. Read `Research/Patches/hv_vmm_present_usermode_xrefs.md` and
   `Documents/en/help/troubleshooting.md`, then report. Do not recreate the
   machine to test a theory.

## Apps and the bootstrap

- **"Press home to continue" lock screen:** `guest unlock <name>`, or
  `{"t":"key","name":"home"}`.
- **App crashes with `EXC_GUARD` / Mach port guard:** a known kernel-patch
  scope limit on 26.x bases; see `Documents/en/help/troubleshooting.md`.
- **`dyld ... @loader_path/.jbroot/...` crash** after installing a package:
  a loader link is missing. vphoned re-links within about a second of a package
  operation; touch `Library/dpkg` or wait, then relaunch. See
  `Research/roothide_loader_links.md`.
- **First bootstrap package install fails:** do not patch it in place;
  uninstall the bootstrap and start again ([guest-layout](guest-layout.md)).
- **Irisin "Starting…" forever, `id root` fails, sshd resets connections:**
  roothide base items are missing; `Research/Guest/roothide_bootstrap_base.md`.
- **App installed with `apps.install` does not appear:** `system.uicache`.

## Reporting

When you stop, give the user: what you ran, the exact error (stderr), the log
file path, the note you read, and the one decision you need from them. Keep it
to what you observed; do not claim a cause you did not verify.
