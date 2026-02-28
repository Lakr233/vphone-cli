# vphone-cli

Boot a virtual iPhone (iOS 26) via Apple's Virtualization.framework using PCC research VM infrastructure.

![poc](./demo.png)

## Tested Environments

| Host | iPhone | CloudOS |
|------|--------|---------|
| Mac16,12 26.3 | `17,3_26.1_23B85` | `26.1-23B85` |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.1-23B85` |
| Mac16,12 26.3 | `17,3_26.3_23D127` | `26.3-23D128` |

## Prerequisites

**Disable SIP and AMFI** — required for private Virtualization.framework entitlements.

Boot into Recovery (long press power button), open Terminal:

```bash
csrutil disable
csrutil allow-research-guests enable
```

After restarting into macOS:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

Restart once more.

**Install dependencies:**

```bash
make setup_libimobiledevice   # build libimobiledevice toolchain
make setup_venv               # create Python venv
source .venv/bin/activate
```

## Quick Start

```bash
make build                    # build + sign vphone-cli
make vm_new                   # create vm/ directory (ROMs, disk, SEP storage)
make fw_prepare               # download IPSWs, extract, merge, generate manifest
make fw_patch                 # patch boot chain (6 components, 41+ modifications)
make boot_dfu                 # boot VM in DFU mode
make restore_get_shsh         # fetch SHSH blob
make restore                  # flash firmware via idevicerestore
```

## Ramdisk and CFW

After restoring, boot into DFU again and load the SSH ramdisk:

```bash
make boot_dfu                 # terminal 1
make ramdisk_build            # build signed SSH ramdisk
make ramdisk_send             # terminal 2 — send to device
```

Install CFW (Cryptexes, patched binaries, jailbreak tools, LaunchDaemons):

```bash
iproxy 2222 22
make cfw_install
```

## Boot

```bash
make boot
```

On first boot, initialize the shell environment:

```bash
# binaries are looking for each others via PATH so do not ignore this one
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

# call with fullpath
/iosbinpack64/bin/mkdir -p /var/dropbear
/iosbinpack64/bin/cp /iosbinpack64/etc/profile /var/profile
/iosbinpack64/bin/cp /iosbinpack64/etc/motd /var/motd
shutdown -h now
```

After subsequent boots, connect via:

```bash
iproxy 22222 22222   # SSH
iproxy 5901 5901     # VNC
```

## All Make Targets

Run `make help` for the full list. Key targets:

| Target | Description |
|--------|-------------|
| `build` | Build + sign vphone-cli |
| `vm_new` | Create VM directory |
| `fw_prepare` | Download/merge IPSWs |
| `fw_patch` | Patch boot chain |
| `boot` / `boot_dfu` | Boot VM (normal / DFU) |
| `restore_get_shsh` | Fetch SHSH blob |
| `restore` | Flash firmware |
| `ramdisk_build` | Build SSH ramdisk |
| `ramdisk_send` | Send ramdisk to device |
| `cfw_install` | Install CFW mods |
| `clean` | Remove build artifacts |

## FAQ

> **Before anything else — run `git pull` to make sure you have the latest version.**

**Q: I get `zsh: killed ./vphone-cli` when trying to run it.**

AMFI is not disabled. Set the boot-arg and restart:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
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
