---
name: vphone-guest-control
description: Install vphone-launchpad and VPhone.bundle, create and run vphone virtual iPhones, and drive a running guest from the command line with vphone-launchpad-cli and the per-machine vphone.sock. Make sure to use this skill whenever the user mentions vphone, vphone-launchpad, vphone-launchpad-cli, VPhone.bundle, vphoned, vphone.sock, or a virtual iPhone on their Mac, even if they do not name the tool. That includes setting vphone up, creating/starting/stopping a machine, tapping/swiping/typing/taking screenshots in the guest, calling a vphoned method (apps, files, logs, processes, UI tree), installing an IPA into a guest, installing the roothide/rootless bootstrap (Irisin), ssh into a guest, installing a .deb, or debugging a guest that shows a black screen or will not boot to the UI.
---

# Driving vphone

vphone runs a virtual iPhone on an Apple Silicon Mac through
Virtualization.framework. Two pieces matter to you:

| Piece | Role |
| --- | --- |
| `vphone-launchpad` (Mac app) | Downloads and verifies `VPhone.bundle`, creates machines, runs them. Owns the only root helper. |
| `vphone-launchpad-cli` | A stateless client of the running app. Every command also appears in the app's window and history. |

Use `vphone-launchpad-cli` for everything. The app does the privileged and
signed work for you; a second route (sudo, a copy of `vphone-cli`, `devicectl`)
either lacks the entitlements, bypasses the checks the app records, or times out
against these guests.

## How a session should go

1. **Find out where the user is.** Run `vphone-launchpad-cli status`. If the
   command does not exist, go to [install](references/install.md). Otherwise the
   JSON tells you the next step:
   - `canInstallBundles: false` or `helper` not `ready`: the user must finish
     Host Setup in the app (administrator password, Developer Tools access).
     You cannot do this for them; say exactly what is missing.
   - `defaultBundle: null` or `bundleReady: false`: install or verify a bundle.
     Each machine runs with its own bundle (`vm list` → `bundle`); the default
     only decides what new machines get.
   - `machines: 0`: create one ([machines](references/machines.md)).
   - Otherwise: list machines, start the one the user named, then control it.
2. **Pick the reference for the task, and read it before acting.**

   | Task | Read |
   | --- | --- |
   | Install Launchpad or a bundle, host requirements, series matching | [references/install.md](references/install.md) |
   | An install step failed: "damaged", Developer Tools access turns off, several macOS installations, `zsh: killed`, not Apple silicon | [references/install-faq.md](references/install-faq.md) |
   | Create, start, stop, retry, update a machine, change its Core Bundle | [references/machines.md](references/machines.md) |
   | Tap, swipe, key, screenshot, anything on `vphone.sock` | [references/guest-socket.md](references/guest-socket.md) |
   | Call a vphoned method: apps, files, logs, UI tree, processes | [references/rpc-methods.md](references/rpc-methods.md) |
   | Installing an IPA | [references/rpc-methods.md](references/rpc-methods.md#installing-an-app) |
   | roothide vs rootless, installing the bootstrap, ssh, `/rootfs`, handing files to vphoned, `.deb` | [references/guest-layout.md](references/guest-layout.md) |
   | Black screen, timeouts, AMFI, "客体代理未连接" | [references/troubleshooting.md](references/troubleshooting.md) |
   | A symptom the above does not cover; which research note or source explains it | [references/finding-docs.md](references/finding-docs.md) |

3. **Verify with the guest, not with assumptions.** After an input, take a
   screenshot or read `ui.describe`; after a launch, check `apps.foreground`.
   The guest is a real device with timing, so a command that returned `ok` has
   not necessarily produced the visible result.

## Output and errors

- Progress lines go to **stderr** as they arrive. The result is **one JSON
  document on stdout**. Exit 0 is success; exit 1 is failure with the reason on
  stderr. Parse stdout, and read stderr when the exit code is 1.
- `vphone-launchpad-cli help` prints every command with its options and is
  authoritative if this skill and the installed version disagree.
- Quote JSON in single quotes: `guest rpc myphone apps.launch '{"bundle_id":"com.apple.Preferences"}'`.
- Interrupting the CLI cancels `exec`, waits and CFW install. A bundle install
  or a machine creation belongs to the app window and keeps going, so do not
  start a second one because the CLI went quiet; run `vm log <name> --kind create`.
- Pass `--root <library>` only when two libraries hold a machine with the same
  name; the error lists the libraries.

## Rules that save the user's machine

These exist because each one has cost the user real time or disk before.

- **Use the machines the user named.** Do not `vm create` to reproduce a
  problem; diagnose on the existing guest. A creation takes tens of GB and
  several restarts, and a half-built machine is harder to clean up than the bug.
- **Creating is one at a time, after checking free disk.** IPSWs plus the
  restore tree are large, and a full disk fails halfway with confusing errors.
- **Never change host security settings** (SIP, boot-args, AMFI, Research
  Guests) and never run `bundle accept`, `bundle remove`, `cfw install` or a
  second `vm create` over existing work unless the user asked. Report what is
  needed; the Mac's owner decides.
- **`force` methods need the user's intent.** A method whose `force` in
  `methods.list` is not `never` (for example `processes.kill`, `system.reboot`)
  refuses to run without `"force":true`. Passing it is the confirmation, so
  pass it only for an action the user asked for.
- **Do not edit a machine's folder (`~/.vphone/machines/<name>/`) while it runs.**
  Use RPC for guest files instead.
- **Keep the host API listener on loopback.** `--api-listen` sends its token in
  clear text.
- **Install apps through installd** (`ideviceinstaller`) when the point is to
  test installation; `apps.install` bypasses installd. Never use
  `xcrun devicectl` to install or launch (it times out); listing devices is fine.
- **When stuck, read before experimenting.** The repository's guides and
  `Research/` notes quote real failures; see
  [references/finding-docs.md](references/finding-docs.md).
