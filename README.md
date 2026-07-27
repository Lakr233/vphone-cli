<div align="right"><strong><a href="./docs/README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./docs/README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./docs/README_zh.md">🇨🇳中文</a></strong> | <strong>🇬🇧English</strong></div>

# vphone-cli

Boot a virtual iPhone via Apple's Virtualization.framework using PCC research VM infrastructure.

Everything runs through the single `vphone-cli` binary — create, patch, restore, install, boot, and manage VMs. No `make` needed after building.

![poc](./docs/demo.jpeg)

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
| Mac16,6 25.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 25.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |

iOS ≤ 26.0.1 use the 26.1 PCC vphone600 stack plus the CFW-time `IOMobileFramebuffer` SwapEnd payload-size patch. iOS 27.0 uses the 26.4 PCC vphone600 stack plus the CFW-time force-kern `IOMobileFramebuffer` present-path patch and the dyld shared-cache `maxSlide` fit.

> **Note:** GPU/Metal acceleration does not work on iOS 18.x — the 18.x Metal/IOGPU framework has no paravirtualized GPU implementation, so Metal-rendered content (web pages, images, wallpaper) does not render. Touch, networking, and apps work normally.

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

## Prerequisites

**Host:** macOS 15+ (Sequoia), a non-nested Mac (Virtualization.framework can't nest). The private PV=3 entitlements + unsigned-binary workflow need SIP/AMFI relaxed. Pick **one** of these two paths — the SIP setting and the AMFI setting go together, don't mix them:

**Option A — fully disable SIP, then disable AMFI via boot-arg (most permissive).** In Recovery (long-press power → Terminal):

```bash
csrutil disable
csrutil allow-research-guests enable
```

Then reboot into macOS and set the AMFI boot-arg (needs SIP fully off to take effect):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # reboot after
```

**Option B — keep SIP on (debug-only relaxed), then allowlist the binary with amfidont** (leaves AMFI enabled system-wide). In Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Then reboot into macOS and allowlist the repo with [`amfidont`](https://github.com/zqxwce/amfidont) (or [`amfree`](https://github.com/retX0/amfree)):

```bash
sudo amfidont --path <repo>
```

> The `less` (patchless) variant needs Option A, or Option B with `amfidont -S` (`sudo amfidont -S --path <repo>`).

**Dependencies:**

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd
```

(A modern `python3` — 3.11+ — is required; the app builds its own Python environment from it, see [Python runtime](#python-runtime).)

## Build

Two one-time bootstrap scripts (a compiled binary can't build itself), then everything is `vphone-cli`:

```bash
./scripts/setup_tools.sh      # install deps, build toolchain submodules, create the Python venv
./scripts/build.sh            # build + sign vphone-cli, bundle the .app, cross-compile vphoned
```

Put the binary on your `PATH` so the examples below work verbatim:

```bash
cd .build/release
vphone-cli --help
```

## Quick Start

One command creates a VM end-to-end (download → patch → DFU restore → CFW install → first boot):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant
```

With no source flags it downloads a default tested iPhone + cloudOS pair. To choose specific firmware, pass **`-i`/`--iphone-source`** and **`-c`/`--cloudos-source`** — each takes either a **URL** or a **local `.ipsw` path** (see [Tested Environments](#tested-environments) for known-good pairs):

```bash
# from local IPSWs
vphone-cli vm create myphone -V jb \
  -i ~/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw \
  -c ~/ipsws/cloudOS_26.1-23B85.ipsw

# or from URLs — downloaded and cached under ~/.vphone/ipsws
vphone-cli vm create myphone -V jb \
  -i "https://updates.cdn-apple.com/.../iPhone17,3_26.1_23B85_Restore.ipsw" \
  -c "https://updates.cdn-apple.com/private-cloud-compute/<id>"
```

The CFW-install stage needs root (host disk mount) and will prompt for `sudo`; pass `-s <pw>` (`--sudo-password`) to run unattended. Add `-v` to watch the restore (pmd3 log, colorized), `-vv` for pmd3 debug detail, `-vvv` for vphone-cli's internal trace. Then boot it:

```bash
vphone-cli vm launch myphone
```

VMs live in a **library** at `~/.vphone/VMs/` (override any command with `--library-root <dir>`). Run any VM command with no name (e.g. `vphone-cli vm launch`) to pick from a menu of your VMs.

## Commands

`vphone-cli vm create` runs the whole pipeline; the individual steps below let you drive it manually or re-run one stage.

### Manage

```bash
vphone-cli vm list                         # list VMs (--json for scripting)
vphone-cli vm info myphone                  # show one VM
vphone-cli vm new myphone                   # create an empty bundle (cpu/mem/disk options)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # fast APFS clone, fresh device identity
vphone-cli vm export myphone --out myphone.tar.xz   # xz -9; skips restore dir + staging files
vphone-cli vm import --in myphone.tar.xz --name restored
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

## Running & Connecting

`vphone-cli vm launch <name>` opens the VM window; `vphone-cli vm stop <name>` shuts it down. The guest runs an SSH server (dropbear) on port `22222` and VNC on `5901`, reachable over the VM's NAT IP (find it with `arp -a` on `bridge100`):

- **SSH (jailbreak):** `ssh -p 22222 mobile@<vm-ip>` (password `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

For the `jb`/`exp` variants, Sileo and TrollStore are installed automatically on first boot (monitor `/var/log/vphone_jb_setup.log`).

## Python runtime

A few steps (DFU restore, IPSW handling) run through Python. On first use,
vphone-cli provisions a self-contained venv at `~/.vphone/venv` from a modern
host `python3` (3.11+) using the bundled `requirements.txt` — so the signed
`.app` is **portable**: copy it anywhere (e.g. `/Applications`) and it runs
without the repo. Provisioning is automatic; run `vphone-cli setup` to do it
up front. Point at a specific interpreter with `VPHONE_PYTHON=/path/to/python3`,
or relocate the venv with `VPHONE_VENV_DIR=/path`.

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/debug restrictions aren't bypassed; see [Prerequisites](#prerequisites) (`amfi_get_out_of_my_way=1` or `amfidont`).

**`Virtualization is not available on this hardware`** — your Mac is itself a VM; PV=3 guest boot can't nest. Use a non-nested macOS 15+ host.

**Stuck on "Press home to continue"** — connect via VNC and right-click (two-finger click) to simulate the home button.

**System apps won't install** — during iOS setup, don't pick Japan or the EU as your region (extra regulatory checks the VM can't satisfy); pick e.g. United States.

**App crashes on launch with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — re-patch with `vphone-cli fw patch <name> --variant <v> --force-exc-guard`, then re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Always on for iOS 18 bases.

**Install a `.ipa`/`.tipa`** — use the running VM's Install menu (drag-drop or file picker).

## Automation

`vphone-cli` exposes a host control socket (`<bundle>/vphone.sock`) for programmatic control — screenshots, touch, swipes, hardware keys, clipboard — each action returning an inline screenshot for AI-driven E2E testing. See [vphone-mcp](https://github.com/pluginslab/vphone-mcp) for an MCP server wrapping it.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
