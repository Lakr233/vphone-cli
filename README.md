<div align="right"><strong><a href="./docs/README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./docs/README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./docs/README_zh.md">🇨🇳中文</a></strong> | <strong>🇬🇧English</strong></div>

# vphone-cli

Boot a virtual iPhone (iOS 26) via Apple's Virtualization.framework using PCC research VM infrastructure.

![poc](./docs/demo.png)

## Tested Environments

| Host          | iPhone             | CloudOS       |
| ------------- | ------------------ | ------------- |
| Mac16,12 26.3 | `17,3_26.1_23B85`  | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.3-23D128` |

## Firmware Variants

Three patch variants are available with increasing levels of security bypass:

| Variant             |   Boot Chain    |    CFW    | Make Targets                       |
| ------------------- | :-------------: | :-------: | ---------------------------------- |
| **Regular**         |   41 patches    | 10 phases | `fw_patch` + `cfw_install`         |
| **Development**     |   52 patches    | 12 phases | `fw_patch_dev` + `cfw_install_dev` |
| **Jailbreak (WIP)** | 66 / 78 patches | 14 phases | `fw_patch_jb` + `cfw_install_jb`   |

`66` = default JB kernel method plan; `78` = default + optional kernel methods (`VPHONE_JB_ENABLE_OPTIONAL=1`).

See [research/00_patch_comparison_all_variants.md](./research/00_patch_comparison_all_variants.md) for the detailed per-component breakdown.

## Prerequisites

**Host OS:** macOS 15+ (Sequoia) is required for PV=3 virtualization.

**Configure SIP/AMFI** — required for private Virtualization.framework entitlements and unsigned binary workflows.

Boot into Recovery (long press power button), open Terminal, then choose one setup path:

- **Option 1: Fully disable SIP + AMFI boot-arg (most permissive)**

  In Recovery:

  ```bash
  csrutil disable
  csrutil allow-research-guests enable
  ```

  After restarting into macOS:

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

  Restart once more.

- **Option 2: Keep SIP mostly enabled, disable only debug restrictions, use [`amfidont`](https://github.com/zqxwce/amfidont)**

  In Recovery:

  ```bash
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  After restarting into macOS:

  ```bash
  xcrun python3 -m pip install amfidont
  sudo amfidont --path [PATH_TO_VPHONE_DIR]
  ```

**Install dependencies:**

```bash
brew install ideviceinstaller wget gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool
```

**Submodules** — this repo uses a git submodule for resource archives. Clone with:

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## Quick Start

```bash
make setup_machine            # full automation through "First Boot" (includes restore/ramdisk/CFW)
# options: NONE_INTERACTIVE=1 SUDO_PASSWORD=... PATCH=patch_xxx
```

## Manual Setup

```bash
make setup_tools              # install brew deps, build trustcache + libimobiledevice, create Python venv
make build                    # build + sign vphone-cli
make vm_new                   # create vm/ directory (ROMs, disk, SEP storage)
make fw_prepare               # download IPSWs, extract, merge, generate manifest
make fw_patch                 # patch boot chain (regular variant)
# or: make fw_patch_dev       # dev variant (+ TXM entitlement/debug bypasses)
# or: make fw_patch_jb        # jailbreak variant (+ full security bypass) (WIP)
# or: make fw_patch_test PATCH=patch_xxx  # one JB kernel method on top of dev patch
# or: make jb_patch_autotest             # test all JB methods (single-thread, full setup flow)
```

## Restore

You'll need **two terminals** for the restore process. Keep terminal 1 running while using terminal 2.

```bash
# terminal 1
make boot_dfu                 # boot VM in DFU mode (keep running)
```

```bash
# terminal 2
make restore_get_shsh         # fetch SHSH blob
make restore                  # flash firmware via idevicerestore
```

## Install Custom Firmware

Stop the DFU boot in terminal 1 (Ctrl+C), then boot into DFU again for the ramdisk:

```bash
# terminal 1
make boot_dfu                 # keep running
```

```bash
# terminal 2
make ramdisk_build            # build signed SSH ramdisk
make ramdisk_send             # send to device
```

Once the ramdisk is running (you should see `Running server` in the output), open a **third terminal** for the iproxy tunnel, then install CFW from terminal 2:

```bash
# terminal 3 — keep running
iproxy 2222 22
```

```bash
# terminal 2
make cfw_install
```

## First Boot

Stop the DFU boot in terminal 1 (Ctrl+C), then:

```bash
make boot
```

This gives you a **direct console** on the VM. When you see `bash-4.4#`, press Enter and run these commands to initialize the shell environment and generate SSH host keys:

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# generate SSH host keys (required for SSH to work)
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key

shutdown -h now
```

> **Note:** Without the host key generation step, dropbear (SSH server) will accept connections but immediately close them because it has no keys to perform the SSH handshake.

## Subsequent Boots

```bash
make boot
```

In a separate terminal, start iproxy tunnels:

```bash
iproxy 22222 22222   # SSH
iproxy 5901 5901     # VNC
iproxy 5910 5910     # RPC
```

Connect via:

- **SSH:** `ssh -p 22222 root@127.0.0.1` (password: `alpine`)
- **VNC:** `vnc://127.0.0.1:5901`
- [**RPC:**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## FAQ

> **Before anything else — run `git pull` to make sure you have the latest version.**

**Q: I get `zsh: killed ./vphone-cli` when trying to run it.**

AMFI/debug restrictions are not bypassed correctly. Choose one setup path:

- **Option 1 (full AMFI disable):**

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

- **Option 2 (debug restrictions only):**
  use Recovery mode `csrutil enable --without debug` (no full SIP disable), then install/load [`amfidont`](https://github.com/zqxwce/amfidont) while keeping AMFI otherwise enabled.

**Q: System apps (App Store, Messages, etc.) won't download or install.**

During iOS setup, do **not** select **Japan** or **European Union** as your region. These regions enforce additional regulatory checks (e.g., sideloading disclosures, camera shutter requirements) that the virtual machine cannot satisfy, which prevents system apps from being downloaded and installed. Choose any other region (e.g., United States) to avoid this issue.

**Q: I'm stuck on the "Press home to continue" screen.**

Connect via VNC (`vnc://127.0.0.1:5901`) and right-click anywhere on the screen (two-finger click on a Mac trackpad). This simulates the home button press.

**Q: SSH connects but immediately closes (`Connection closed by 127.0.0.1`).**

Dropbear host keys were not generated during first boot. Connect via VNC or the `make boot` console and run:

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'
mkdir -p /var/dropbear
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key
killall dropbear
dropbear -R -p 22222
```

**Q: Can I update to a newer iOS version?**

Yes. Override `fw_prepare` with the IPSW URL for the version you want:

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```

Our patches are applied via binary analysis, not static offsets, so newer versions should work. If something breaks, ask AI for help.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
