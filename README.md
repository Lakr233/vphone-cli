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

## Ramdisk and CFW

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

Once connected, install CFW:

```bash
# terminal 2
iproxy 2222 22
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
```

Connect via:
- **SSH:** `ssh -p 22222 root@127.0.0.1` (password: `alpine`)
- **VNC:** `vnc://127.0.0.1:5901`

## All Make Targets

Run `make help` for the full list. Key targets:

| Target | Description |
|--------|-------------|
| `build` | Build + sign vphone-cli |
| `vm_new` | Create VM directory |
| `fw_prepare` | Download/merge IPSWs |
| `fw_patch` | Patch boot chain |
| `boot` / `boot_dfu` | Boot VM (GUI / DFU headless) |
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
