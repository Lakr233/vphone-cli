<div align="right"><strong><a href="./docs/README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./docs/README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./docs/README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./docs/README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="./docs/README_pt.md">🇧🇷Português</a></strong> | <strong>🇬🇧English</strong></div>

# vphone-cli

Boot a virtual iPhone via Apple's Virtualization.framework using PCC research VM infrastructure.

![poc](./docs/demo.jpeg)

## Prerequisites

**To run it:**

- Apple Silicon
- macOS 15+ (Sequoia)
- [SIP/AMFI relaxation to allow private PV=3 entitlements with unsigned-binary](#sipamfi-relaxation)

**Nothing else.** No Homebrew packages, no interpreter, no package environment,
no Xcode. Everything vphone-cli runs is either a system binary under `/usr/bin`,
`/bin`, `/usr/sbin` or `/sbin`, or is inside the `.app` — including the signer
(it replaced `ldid`), the archive reader (`gtar`, `zstd`, `unzip`), the firmware
catalogue and IM4P/AEA handling (`ipsw`), and the five iOS binaries the CFW
installers put in the guest, which are cross-compiled at build time and shipped
rather than built on your machine. `make check-aux` is the gate that keeps it
that way.

**To build it from source**, add Xcode — its iOS SDK is what those guest
binaries are cross-compiled against — and `git-lfs`, which `git clone` needs for
the archives in `scripts/resources`.

## Install

```bash
brew install zqxwce/tap/vphone-cli
```

## Build

```bash
brew install git-lfs
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/build.sh            # build + sign vphone-cli, cross-compile the guest
                              # binaries, bundle the .app

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

`./scripts/setup_tools.sh` is optional and builds one thing: `insert_dylib`, the
independent reference a Mach-O test compares the Swift dylib injector against.
Nothing shipped runs it.

## Quick Start

One command creates a VM end-to-end (download → patch → DFU restore → CFW install → first boot):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## Commands

`vphone-cli vm create` runs the whole pipeline; the individual steps below let you drive it manually or re-run one stage.

### Manage

```bash
vphone-cli vm list                         # list VMs (--json for scripting)
vphone-cli vm info myphone                  # show one VM
vphone-cli vm new myphone                   # create an empty bundle (cpu/mem/disk options)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # fast APFS clone, fresh device identity
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out may be a dir (auto-names <vm>.tzst/.txz); skips restore dir + staging files
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### Build a VM manually (what `vm create` automates)

```bash
vphone-cli vm new myphone                              # 1. empty bundle
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. download + merge IPSWs
vphone-cli fw patch myphone --variant jb                # 3. patch the boot chain

vphone-cli vm launch myphone --dfu &                    # 4. boot into DFU (background)
vphone-cli restore myphone --get-shsh                   #    fetch SHSH
vphone-cli restore myphone                              #    DFU restore
vphone-cli vm stop myphone                              #    stop the DFU boot

vphone-cli cfw install myphone --variant jb             # 5. install CFW (host-mount; asks for sudo)
vphone-cli vm launch myphone                            # 6. first boot
```

Update to a newer iOS by pointing `fw prepare` at an IPSW: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`.

Steps 4 and 5 run in `vphone-cli`'s own process. `restore` drives vendored
libirecovery and idevicerestore directly — no external restore tool, no setup
step before the first one works. Add `--offline` to restore from a `.shsh`
already saved beside the VM instead of asking Apple for a fresh one.

## Firmware Variants

Five patch variants with increasing security bypass — pass one to `--variant`:

| Variant      | Boot Chain  | CFW       | Notes                                                              |
| ------------ | ----------- | --------- | ----------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | Patchless — keeps iOS mitigations enabled                         |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM bypass                                           |
| `dev`        | 53 patches  | 12 phases | + TXM entitlement/debug bypass                                    |
| `jb`         | 113 patches | 14 phases | + full jailbreak (Sileo, TrollStore auto-install on first boot)   |
| `exp`        | 141 patches | 18 phases | JB superset + anti-VM-detection research patches                  |

See [`research/0_binary_patch_comparison.md`](./research/0_binary_patch_comparison.md) for the per-component breakdown.

## Running & Connecting

- **SSH (jailbreak):** `ssh -p 22222 mobile@<vm-ip>` (password `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## Locations

Everything vphone-cli creates lives under `~/.vphone/` — kept outside the repo and the `.app` so the signed bundle stays portable. Redirect the whole tree with `$VPHONE_ROOT`:

| Path              | Contents                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------- |
| `~/.vphone/`      | The per-user data root — override the entire location with `$VPHONE_ROOT`.                   |
| `~/.vphone/VMs/`  | VM bundles — one directory per VM. This is the library; override with `$VPHONE_LIBRARY_ROOT`. |
| `~/.vphone/ipsws/`| Downloaded iPhone + cloudOS IPSWs, cached and reused across VMs.                              |
| `~/.vphone/tools/`| Cached APFS seal-volume artifacts (`apfs_sealvolume_<version>`) fetched during `fw prepare`.  |
| `~/.vphone/debs/` | Cached `.deb` packages the `jb`/`exp` CFW install lays into the guest (Sileo, apt, …).        |

Precedence: the per-item override `$VPHONE_LIBRARY_ROOT` wins over `$VPHONE_ROOT`, which wins over the `~/.vphone` default. The `ipsws/`, `tools/`, and `debs/` caches always sit directly under whichever root is active.

## SIP/AMFI Relaxation

**Option A — fully disable SIP, then disable AMFI via boot-arg (most permissive).** 

In Recovery (long-press power → Terminal):

```bash
csrutil disable
csrutil allow-research-guests enable
```

Then reboot into macOS and set the AMFI boot-arg (needs SIP fully off to take effect):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # reboot after
```

This is still the simplest path, and the only one that needs nothing running
alongside the VM: with AMFI relaxed, `vphone-vm` launches on its own.

**Option B — keep SIP on (debug-only relaxed) and allowlist this build** (AMFI
stays enabled the rest of the time, and for every binary you did not allow).

In Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Then reboot into macOS and run:

```bash
make amfi_allow     # asks for root; run it again after every build
make amfi_status    # show the allowlist, and whether this host can carry one
make amfi_off       # remove it and restart amfid clean
```

That runs `vphone-amfi-allow`, which is built from this repository's own C and
ships inside the `.app`. It writes two things:

* the cdhashes of **both** copies of `vphone-vm` into
  `/Library/Preferences/com.apple.security.coderequirements.plist`, which AMFI
  already reads — this is a feature amfid ships, not a hole;
* one byte of amfid's **heap**, to flip the `_isRunningInternalBuild` flag that
  makes it consult that file in the first place.

Both, because `make boot` launches both: `boot_binary_check` runs
`.build/release/vphone-vm` and the boot itself runs the one inside the `.app`.
They sign under different identifiers and hash differently, so allowing one
covers exactly half the flow.

**Re-run it after every build.** It allowlists cdhashes, and those change with
every signature — including a bare `swift build`.

`vphone-vm` is the binary to allow. `vphone-cli` carries no entitlements and
always launches, so its cdhash is not the one you want.

> **Be clear about what this allows.** It is an allowlist keyed on cdhash:
> amfid keeps enforcing for every binary you did not name. `make amfi_off`
> removes the file and restarts amfid.
>
> The one byte is in amfid's heap, not its `__TEXT`, and that is the whole
> reason this works. Earlier attempts patched the code — `vphone-letmein`
> overwrote the `ldrb` in `-[AMFIPathValidator_macos validateWithError:]`, and
> LLDB-based tools plant a `BRK` for a breakpoint. Both leave a dirty unsigned
> executable page, and on a host where `sysctl vm.cs_system_enforcement` reads
> 1 — as it does on macOS 27.0 (26A428), arm64e, with exactly the `csrutil`
> settings above — the kernel validates that page on the next fault, kills
> amfid, and takes the guest down with it. The sysctl is read-only at runtime,
> so no amount of care makes "patch the code" survive it. A heap write is not
> code, so enforcement has nothing to object to.

## Tested Environments

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |

## FAQ

**`zsh: killed ./vphone-vm`** — AMFI/debug restrictions aren't bypassed; see [SIP/AMFI Relaxation](#sipamfi-relaxation) — either `amfi_get_out_of_my_way=1` (Option A), or `make amfi_allow` for this build (Option B). If you ran it before your last build, run it again: the allowlist is keyed on cdhash, and signing changes that. Note this cannot happen to `vphone-cli` itself: it carries no entitlements, so if *it* is being killed, something else is wrong.

**`Virtualization is not available on this hardware`** — your Mac is itself a VM; PV=3 guest boot can't nest. Use a non-nested macOS 15+ host.

**Stuck on "Press home to continue"** — connect via VNC and right-click (two-finger click) to simulate the home button.

**System apps won't install** — during iOS setup, don't pick Japan or the EU as your region (extra regulatory checks the VM can't satisfy); pick e.g. United States.

**App crashes on launch with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — re-patch with `vphone-cli fw patch <name> --variant <v> --force-exc-guard`, then re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Always on for iOS 18 bases.

**Install a `.ipa`/`.tipa`** — use the running VM's Install menu (drag-drop or file picker).

**Do I need Homebrew, or Xcode, to use this?** — No. `vphone-cli` runs on a clean macOS 15+: everything it shells out to is in `/usr/bin`, `/bin`, `/usr/sbin` or `/sbin`, and everything else is inside the `.app`. `make check-aux` is the gate that keeps it that way — it walks the bundle's dependency closure, checks the bundle holds exactly what it is supposed to, scans every shipped script for a `PATH` lookup, and smoke-tests the binaries with `env -i PATH=/usr/bin:/bin`. Building from source is the other story: that needs Xcode (for the iOS SDK the guest binaries are cross-compiled against) and `git-lfs` (to check out `scripts/resources`).

**`cfw install` hangs re-signing a system binary (e.g. `Campo`), memory climbing unbounded** — this was a bug in `ldid-procursus` up to `2.1.5-procursus7`: `bytes(uint64_t)` called `__builtin_clzll(0)` with no zero-guard, which is undefined behavior, and on that build resolved to a `0`-length that underflowed an unsigned loop counter, so `ldid` span writing one byte at a time into a growing buffer instead of terminating. Any entitlements plist with an integer value of exactly `0` triggered it, and some real Apple system binaries have one. It cannot happen any more: signing is `vphone-cli sign`, in-process, and `ldid` is not installed, invoked or shipped.

## Automation

`vphone-cli` exposes a host control socket (`<bundle>/vphone.sock`) for programmatic control — screenshots, touch, swipes, hardware keys, clipboard — each action returning an inline screenshot for AI-driven E2E testing. See [vphone-mcp](https://github.com/pluginslab/vphone-mcp) for an MCP server wrapping it.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)