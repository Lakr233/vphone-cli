# The host binary split: vphone-cli / vphone-vm / vphone-letmein

> 2026-09-23, branch `vphone-intg-update`.
> Supersedes the single-executable layout and the `amfidont` helper.

## The problem it solves

All seven private entitlements used to be signed onto `vphone-cli` — the binary
a user types. amfid will not accept Apple-private entitlements on an ad-hoc
signature, so the kernel killed the entry point at exec. `vphone-cli --help`
printed nothing and exited 137.

That is a chicken-and-egg: the tool could not run in order to arrange the
conditions under which it could run. The only way out was to leave a bypass
daemon running all the time, so that every process on the machine was being
told that every signature was valid, for as long as the machine was up.

## The shape now

| binary | entitlements | what it is |
| --- | :---: | --- |
| `vphone-cli` | **none** | argument parsing and orchestration. Launches anywhere. |
| `vphone-vm` | **all 7** | a parse and an `NSApplication` run loop over `VPhoneVMKit`. |
| `vphone-letmein` | none (needs root) | opens an AMFI window. Plain C. |

`vphone-cli` is now always able to start, which is what lets it do something
about amfid instead of being the thing amfid stops. When it is asked for a
guest it hands the boot to `vphone-vm`, opening a window around the exec if it
has to and closing it immediately after.

The compensating control moved from **scope** to **time**. The old helper
claimed a path/CDHash allowlist; that is not reproducible on macOS 26, because
deciding per-validation means interrupting amfid, and amfid carries
`com.apple.developer.hardened-process`, which gates exactly those debugger
operations behind Apple-private entitlements. So the switch is global while it
is open — and the answer is to keep it open for one exec rather than all day.

**Do not describe `vphone-letmein` as scoped to a binary or a path.** It is not.

## Why the split was cheap

The CLI/VM boundary was already a process boundary. `vm launch` and four sites
in the create orchestrator all spawned the running executable through
`VPhoneResources.runningExecutable()`. The change is mostly *what* they spawn.

## Things that are easy to get wrong

### `Bundle.main.executableURL` cannot find this process any more

It reads `CFBundleExecutable`, which is now `vphone-vm`. Ask it while running
`vphone-cli` — in the same `Contents/MacOS` — and it answers `vphone-vm`.
`runningExecutable()` uses `_NSGetExecutablePath`, which is the path the kernel
exec'd and owes nothing to any plist.

### `CFBundleExecutable` is `vphone-vm`, deliberately

The `.app` is never opened through Launch Services; every caller runs a binary
inside it directly. It exists to give the process that becomes an
`NSApplication` a bundle — icon, `LSUIElement`, the `NSLocation*UsageDescription`
strings. That process is `vphone-vm`.

### An unentitled `vphone-vm` is worse than a broken one

It launches perfectly. The AMFI probe therefore concludes nothing is wrong, the
boot proceeds, and it fails much later trying to create a PV=3 machine — far
from the cause. A bare `swift build -c release` leaves exactly that state
behind, because only `make build` / `scripts/build.sh` sign. Both now verify
the entitlements actually landed and fail if they did not. This was found by
walking into it.

### Bridged networking nearly broke silently

`availableBridgeInterfaces()` returns an empty list without
`com.apple.vm.networking` — which `vphone-cli` no longer has. The old code read
that as "this host has no bridgeable interfaces" and rejected `--network
bridged` on a machine full of them. An empty list is now treated as *cannot
tell*: the requested name is recorded and `vphone-vm`, which is entitled,
validates it at boot where the error can name the real problem. With no name
given and nothing to enumerate, `bridgeInterfaceMustBeNamed` says so.

This is the general hazard of the split — **anything that read host state
through an entitled API from the CLI side is now reading it unprivileged.**
Nothing else in `VPhoneCore` does, but new code might.

## The probe

`vphone-vm --help`. amfid decides at exec, before any of the target's own code
runs, so a `--help` that never prints is the same refusal a real boot would
hit. It costs nothing and touches no VM state. A refusal is `SIGKILL`, which
Foundation reports as termination status 9. Any *other* non-zero exit is raised
rather than escalated into a sudo prompt — we only ask for root on the one
signature we recognise.

`VPHONE_LETMEIN=auto|always|never`, and `--let-me-in` on `vm launch`. `never`
still probes: it means "do not open a window", not "do not tell me why", and
skipping the probe would hand the user a bare exit 9 with no explanation, which
is the failure this path exists to remove.

## `--hold` changed meaning

Upstream `exec --hold N` restored the patch after N seconds and returned
immediately, leaving the child running. That loses the guest's exit status and
every signal path to it, so `vphone-cli` could not report or cancel a boot.

Now `--hold N` restores after N seconds and *keeps supervising*: the window is
still only one launch long, but the guest's exit status and signals still reach
the caller. The old behaviour is `--hold N --detach`. `SIGINT`/`SIGTERM`/`SIGHUP`
are also forwarded to the child before the supervisor leaves — without that, a
Ctrl-C took down the supervisor and left the guest parentless, which looks
exactly like a hang.

## Verified, and not

**Verified on 2026-09-23** (AMFI window closed, no sudo available):

| | |
| --- | --- |
| `vphone-cli` entitlements | 0 keys |
| `vphone-vm` entitlements | 7 keys |
| `vphone-cli --help` | exits 0 and prints |
| `vphone-vm --help` | exits 137 — amfid refuses it, as expected |
| probe + `VPHONE_LETMEIN=never` | reports the refusal in full, never touches sudo |
| probe + `auto` | builds `sudo …/vphone-letmein exec --hold 10 -- …/vphone-vm --config …`, confirmed in the process tree |
| sibling resolution | resolves through the `.build/release` symlink to the real `Products/Release` directory |
| entitlement guard | fails as required on an unentitled binary |
| `VPhoneCoreTests` | 130/130 |
| `vphone-letmein` | builds `-Wall -Wextra` clean; `otool -L` shows only Foundation, libSystem, libobjc |

**Not verified — needs root and a real guest:**

1. **Whether `vphone-vm` can actually start a VM holding the entitlements
   alone.** Everything here rests on it. Nothing about the split is proven
   until a guest boots.
2. **`--hold 10` — is 10 seconds right?** A guess. Too short and the exec is
   still being validated when the window shuts; too long and it is open for no
   reason. Measure it.
3. **The `auto` path end to end**, including the sudo prompt, `--hold`
   restoring while the guest keeps running, and Ctrl-C reaching the guest.
4. **Location and TouchID**, which depend on TCC attributing the usage strings
   to `vphone-vm`. It is `CFBundleExecutable`, so it should — but TCC's view of
   a binary inside someone else's bundle is worth confirming rather than
   assuming.
5. **Bridged networking**, now that the name is validated at boot instead of at
   config time.
