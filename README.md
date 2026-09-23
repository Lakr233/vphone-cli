<div align="right"><strong><a href="./docs/README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./docs/README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./docs/README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./docs/README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="./docs/README_pt.md">🇧🇷Português</a></strong> | <strong>🇬🇧English</strong></div>

# vphone-cli

Boot a virtual iPhone via Apple's Virtualization.framework using PCC research VM infrastructure.

![poc](./docs/demo.jpeg)

## Prerequisites

**Host:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (cross-compiles the guest daemon)
- [SIP/AMFI relaxation to allow private PV=3 entitlements with unsigned-binary](#sipamfi-relaxation)

**Dependencies:**

```bash
brew install aria2 wget gnu-tar openssl@3 ldid-procursus sshpass libusb ipsw zstd
```

No interpreter and no package environment: everything vphone-cli itself runs is
Swift or C, built by `make build`.

## Install

```bash
brew install zqxwce/tap/vphone-cli
```

## Build

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # install brew deps, build the toolchain submodules
./scripts/build.sh            # build + sign vphone-cli, bundle the .app, cross-compile vphoned

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

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

**Option B — keep SIP on (debug-only relaxed) and run `amfidont` yourself while you launch** (AMFI stays enabled the rest of the time, and for every binary you did not allow).

In Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Then reboot into macOS.

[`amfidont`](https://github.com/zqxwce/amfidont) is a separate tool that you
install and run. **This project does not ship it, install it, launch it or
supervise it**, and nothing here depends on it — `vphone-cli` only notices that
`vphone-vm` was killed and tells you what to run. It adds no Python dependency
to this repo.

Install it with Apple's Python. Homebrew's refuses with PEP 668, and the tool
re-execs Xcode's `python3`, so Xcode has to be installed:

```bash
xcrun python3 -m pip install --user amfidont
# lands in ~/Library/Python/3.9/bin — add it to $PATH
```

Then let it print the command line for the binaries this build actually
produced:

```bash
make amfi_command      # prints only — installs nothing, runs nothing, no sudo
```

It emits one `sudo amfidont daemon …` line covering **both** copies of
`vphone-vm`, with the paths already resolved through symlinks:

```bash
sudo amfidont daemon \
    --path '<repo>/.build/out/Products/Release' \
    --path '<repo>/.build/vphone-cli.app/Contents/MacOS' \
    --cdhash <release cdhash> \
    --cdhash <bundle cdhash> \
    --spoof-apple --verbose
```

Both, because `make boot` runs both: `boot_binary_check` launches
`.build/release/vphone-vm` and the boot itself launches the one inside the
`.app`. They sign under different identifiers and hash differently, so an
allowlist given one covers exactly half the flow — and `make boot_dfu` uses
only the first. (`.build/release` is a symlink into `.build/out/Products`;
amfid matches on the resolved path, which is why the printed one is resolved.)

`vphone-vm` is the binary to allow. `vphone-cli` carries no entitlements and
always launches, so its cdhash is not the one you want.

Run that line in its own terminal and leave it there, then launch normally from
another — `vphone-cli vm launch myphone`. If you skip all of this, the launch
fails with the same command printed for you, cdhash filled in.

`--path` / `-p` and `--cdhash` / `-c` both repeat, and both merge with the
allowlists stored in `~/.amfidont/paths` and `~/.amfidont/cdhashes`. Write the
entries there once with `amfidont add-path <dir>` and `amfidont add-cdhash
<hash>` (`remove-path` / `remove-cdhash` undo it), and `sudo amfidont daemon
--spoof-apple` is the whole command from then on. A rebuild changes the cdhash,
so a cdhash-only allowlist goes stale every time you run `make build`; a
`--path` allowlist does not.

> **Be clear about what this allows.** It is an allowlist keyed on path prefix
> and cdhash: amfid keeps enforcing for everything you did not name.
> `--spoof-apple` makes the allowed binaries report as Apple-signed, which is
> what the private PV=3 entitlements need. The exception is `--allow-all` —
> pass that and *every* signature amfid checks is reported valid, for as long
> as the daemon runs. Either way it is memory-only: stop the daemon, or reboot,
> and amfid is back to normal.
>
> `amfidont` replaced `vphone-letmein`, which opened its window by writing into
> amfid's `__TEXT`. On a host where `sysctl vm.cs_system_enforcement` reads 1 —
> measured on macOS 27.0 (26A428), arm64e, with exactly the `csrutil` settings
> above — the kernel kills amfid for that dirty page and takes the guest down
> with it, and the sysctl is read-only. `amfidont` drives amfid through LLDB
> instead, so its breakpoints live in the CPU's debug registers and the page is
> never written; that is why it works under enforcement where patching cannot.

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

**`zsh: killed ./vphone-vm`** — AMFI/debug restrictions aren't bypassed; see [SIP/AMFI Relaxation](#sipamfi-relaxation) — either `amfi_get_out_of_my_way=1` (Option A), or `amfidont` running with `vphone-vm` on its allowlist (Option B). Note this cannot happen to `vphone-cli` itself: it carries no entitlements, so if *it* is being killed, something else is wrong.

**`Virtualization is not available on this hardware`** — your Mac is itself a VM; PV=3 guest boot can't nest. Use a non-nested macOS 15+ host.

**Stuck on "Press home to continue"** — connect via VNC and right-click (two-finger click) to simulate the home button.

**System apps won't install** — during iOS setup, don't pick Japan or the EU as your region (extra regulatory checks the VM can't satisfy); pick e.g. United States.

**App crashes on launch with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — re-patch with `vphone-cli fw patch <name> --variant <v> --force-exc-guard`, then re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Always on for iOS 18 bases.

**Install a `.ipa`/`.tipa`** — use the running VM's Install menu (drag-drop or file picker).

**`cfw install` hangs re-signing a system binary (e.g. `Campo`), memory climbing unbounded** — known bug in `ldid-procursus` up to `2.1.5-procursus7` (the current Homebrew `stable`): `bytes(uint64_t)` calls `__builtin_clzll(0)` with no zero-guard, which is undefined behavior, and on this build resolves to a `0`-length that underflows an unsigned loop counter — `ldid` spins writing one byte at a time into a growing buffer instead of terminating. Triggered by *any* entitlements plist containing an integer value of exactly `0` (some real Apple system binaries have these). Fixed upstream but not yet in a tagged release; rebuild from source: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`. Kill the hung `ldid` process first (`sudo kill -9 <pid>`) if you already hit it.

## Automation

`vphone-cli` exposes a host control socket (`<bundle>/vphone.sock`) for programmatic control — screenshots, touch, swipes, hardware keys, clipboard — each action returning an inline screenshot for AI-driven E2E testing. See [vphone-mcp](https://github.com/pluginslab/vphone-mcp) for an MCP server wrapping it.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)