# The host binary split: vphone-cli / vphone-vm

> 2026-09-23, branch `vphone-intg-update`.
> Supersedes the single-executable layout.
>
> **Corrected later the same day.** This document originally argued the split
> alongside `vphone-letmein`, a helper that opened a global AMFI window for the
> length of one exec. The split is unchanged and still right. The helper is
> removed: it cannot work on a host that enforces code signing, and the reason
> it gave for being global was wrong. Both corrections are in *[What changed,
> and what it cost](#what-changed-and-what-it-cost)*; the original reasoning is
> kept in place so the correction has something to correct.

## The problem it solves

All seven private entitlements used to be signed onto `vphone-cli` — the binary
a user types. amfid will not accept Apple-private entitlements on an ad-hoc
signature, so the kernel killed the entry point at exec. `vphone-cli --help`
printed nothing and exited 137.

That is a chicken-and-egg: the tool could not run in order to arrange the
conditions under which it could run. The only way out was to have the bypass
already in place before anything of ours executed — arranged out of band, by
hand, and kept up for as long as you wanted to use the tool. Nothing in the
project could take part in its own admission, and a user who got it wrong got
`Killed: 9` with no diagnosis, because the binary that would have explained was
the binary being refused.

## The shape now

| binary | entitlements | what it is |
| --- | :---: | --- |
| `vphone-cli` | **none** | argument parsing and orchestration. Launches anywhere. |
| `vphone-vm` | **all 7** | a parse and an `NSApplication` run loop over `VPhoneVMKit`. |
| `vphone-archive` | none | libarchive front end. Unrelated to amfid; listed for completeness. |

`vphone-cli` is now always able to start, which is what lets it say something
about amfid instead of being the thing amfid stops. When it is asked for a
guest it hands the boot to `vphone-vm`; if amfid refuses that exec, the entry
point is alive to print why and what to do about it.

> **Superseded paragraph, kept for the record.** What stood here was: *"The
> compensating control moved from scope to time. The old helper claimed a
> path/CDHash allowlist; that is not reproducible on macOS 26, because deciding
> per-validation means interrupting amfid, and amfid carries
> `com.apple.developer.hardened-process`, which gates exactly those debugger
> operations behind Apple-private entitlements. So the switch is global while it
> is open — and the answer is to keep it open for one exec rather than all day.
> **Do not describe `vphone-letmein` as scoped to a binary or a path.** It is
> not."*
>
> "Not reproducible on macOS 26" is false — `amfidont` does exactly that, and
> does it under code-signing enforcement as well. The tool the paragraph defends
> is gone. See below.

## What changed, and what it cost

Two things were learned after the split shipped. Neither touches the split
itself; both kill the helper that shipped with it.

### 1. Writing amfid's `__TEXT` is fatal under `vm.cs_system_enforcement`

`vphone-letmein` opened its window by patching amfid's `__TEXT` in place. That
makes the page private, dirty and unsigned. On a host where the kernel enforces
code signing system-wide, the next fault into that page is validated, finds no
signature, and the kernel kills amfid:

```
exception    EXC_BAD_ACCESS, SIGKILL (Code Signature Invalid)
termination  namespace CODESIGNING, code 2, indicator "Invalid Page"
fault        0x23cea8c68, inside -[AMFIPathValidator_macos validateWithError:]
region       __TEXT 23cea8000-23ceb0000  r-x/rwx  SM=COW
```

Measured twice on macOS 27.0 (26A428), arm64e, with SIP `enabled --without
debug` plus `allow-research-guests enable` — the configuration the README calls
Option B. The write lands, the read-back verifies, amfid dies at that instant,
and the guest is `SIGKILL`ed anyway because amfid never answered its
validation. The gate is the read-only sysctl `vm.cs_system_enforcement`, which
reads **1** there, so nothing can relax it at runtime and no amount of care in
the tool changes the outcome. `csrutil enable --without debug` does not clear
it: that flag buys `task_for_pid`, not permission to execute a modified page.

Do not re-derive this. The approach is closed on such a host, and that is why
the tool was removed rather than fixed.

### 2. "A per-binary allowlist is impossible" was wrong

The superseded paragraph above reasoned from `vphone-letmein`'s own position —
it could not decide per validation, so it concluded nobody could. `amfidont`
does exactly that, by driving amfid through LLDB: `debugserver` carries the
Apple-private debugger entitlements, and a debugger sets arm64 breakpoints in
the CPU's debug registers rather than writing the page. That is the same reason
it survives enforcement where a text patch cannot — no page is ever dirtied.

So the trade was never scope *versus* time. A text patch buys neither scope nor
a host that enforces signing; the debugger route buys both.

Measured on the same host, with `vm.cs_system_enforcement` still reading 1:
with `sudo amfidont daemon --cdhash <vphone-vm's> --spoof-apple --verbose`
running, `vphone-vm --help` exits 0 instead of being `SIGKILL`ed, and amfid is
still alive afterwards. That is the case `vphone-letmein` could not reach at
all.

**`amfidont` is an allowlist, not a global switch.** It decides per binary, by
path prefix or by CDHash. The "global switch, not an allowlist" wording that
`vphone-letmein` carried was true of `vphone-letmein` and must not be copied
onto its replacement.

`amfidont` is by this project's own author —
<https://github.com/zqxwce/amfidont>, PyPI `amfidont`, 0.0.3 at the time of
writing — but it is a separate program, not a component of this repo.

### 3. The bypass is now outside this project

Policy, decided 2026-09-23: `vphone-cli` does not install, spawn, supervise or
depend on any AMFI bypass. It probes, and on a refusal it prints the exact
command to run. Arranging AMFI is the user's own business — either relax it at
boot, or run `amfidont` and allow `vphone-vm`'s CDHash:

```bash
xcrun python3 -m pip install --user amfidont       # Apple's python3 is 3.9
codesign -dv --verbose=4 <path>/vphone-vm 2>&1 | sed -n 's/^CDHash=//p' | head -1
sudo amfidont daemon --cdhash <cdhash> --spoof-apple --verbose
```

`make amfi_command` renders that second and third line for the binaries the
current build produced, and does nothing else — it installs nothing, starts
nothing, and does not check whether `amfidont` is even on the machine. Re-run it
after every build: the CDHash changes with the bytes.

It is `vphone-vm`'s CDHash that matters, never `vphone-cli`'s — `vphone-cli`
carries no entitlements and amfid never objects to it. `amfidont` re-execs
Xcode's python3, so Xcode is required; Homebrew's python refuses the install
under PEP 668, which is why the system interpreter is the documented one. No
Python dependency is added to this repo for any of it.

### 4. One lesson worth keeping from the helper

Upstream's `exec --hold N` restored the patch after N seconds and returned
immediately, leaving the child running. That loses the guest's exit status and
every signal path to it, so the caller could neither report nor cancel a boot;
a Ctrl-C took down the supervisor and left the guest parentless, which looks
exactly like a hang. Anything that ever wraps the guest again — a sudo shim, a
supervisor, a launchd job — has to forward `SIGINT`/`SIGTERM`/`SIGHUP` and
surface the child's exit status, or it will reintroduce that.

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
as itself — we recognise exactly one signature and do not guess at the rest.

The probe is now the whole of what the CLI does about amfid. It never arranges
a bypass, and it never asks for root; on a refusal it explains the refusal and
names the command the user has to run. Skipping the probe would hand back a
bare exit 9 with no explanation, which is the failure this path exists to
remove, so there is no way to turn it off.

## Verified, and not

**Verified on 2026-09-23** (amfid refusing `vphone-vm`, no bypass in place):

| | |
| --- | --- |
| `vphone-cli` entitlements | 0 keys |
| `vphone-vm` entitlements | 7 keys |
| `vphone-cli --help` | exits 0 and prints |
| `vphone-vm --help` | exits 137 — amfid refuses it, as expected |
| probe on a refusal | reports it in full, never touches sudo |
| sibling resolution | resolves through the `.build/release` symlink to the real `Products/Release` directory |
| entitlement guard | fails as required on an unentitled binary |
| `VPhoneCoreTests` | 130/130 |

Two rows that stood here — the `VPHONE_LETMEIN` env var and the `sudo …
vphone-letmein exec --hold 10 --` command line confirmed in the process tree —
measured a tool that no longer exists. They were true when taken; they describe
nothing in the tree now.

**Not verified — needs root and a real guest:**

1. **Whether `vphone-vm` can actually start a VM holding the entitlements
   alone.** — **settled**, see `research/restore/p2_dfu_spike.md`: it booted a guest
   and libirecovery saw its DFU endpoint. Everything here rested on this, and
   it is the one item the DFU spike closed on the way past.
2. **That the instructions printed on a refusal are the ones that work**, on a
   host with `vm.cs_system_enforcement` = 1 and nothing installed yet. The
   `amfidont` install and daemon invocation were measured on this machine (see
   `research/0_binary_patch_comparison.md`); the CLI's rendering of them into
   an error message was not measured against a fresh host.
3. **Location and TouchID**, which depend on TCC attributing the usage strings
   to `vphone-vm`. It is `CFBundleExecutable`, so it should — but TCC's view of
   a binary inside someone else's bundle is worth confirming rather than
   assuming.
4. **Bridged networking**, now that the name is validated at boot instead of at
   config time.
