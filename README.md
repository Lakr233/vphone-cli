# pcc-vmapple

Long story short, Apple's Private Cloud Compute provides a series of virtual machines for security research, which includes VM configurations capable of booting an iOS/iPhone environment.

The VM system used for recovery is a dedicated pcc image, responsible for LLM inference and providing services. After modifying the boot firmware and LLB/iBSS/Kernel, it can be used to load an iOS 26 virtual machine.

![poc](./demo.png)

## Prepare Development Environment

> **Note:** Disabling SIP is not for modifying the system. We can use a custom boot ROM via private APIs, but `Virtualization.framework` checks our binary's entitlements before allowing the launch of a specially configured VM. Therefore, we need to disable SIP to modify boot arguments and disable AMFI checks.

### In recovery mode

On Apple slicon devices, you can boot into recovery mode by long pressing the power button, press until the screen showing "Loading boot options". Then in recovery mode, select Tools on menu bar, which will have an option to select Terminal. Inside terminal, type in the two commands;

`csrutil disable`

`csrutil allow-research-guests enable`

After runnning these two commands, you can restart into normal macOS.

### Set up boot args

After restart into macOS, launch a terminal and run the command:

`sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"`

Once done, restart the system again.

### Compile libimobiledevice suite

> Shoutout to [nikias](https://github.com/nikias) for his original all in one script!

The libimobiledevice suite is required to make the whole installation to function. You can run the pre-set up script at `compile_all_libimobiledevice_deps.sh`, which helps you compile all libimobiledevice libraries with vphone support.

## Prepare Resource Files

### Enable Research Environment VM Resource Control

- `sudo /System/Library/SecurityResearch/usr/bin/pccvre`
- `cd /System/Library/SecurityResearch/usr/bin/`
- `./pccvre release list`
- `./pccvre release download --release 35622`
- `./pccvre instance create -N pcc-research -R 35622 --variant research`

### Obtain Resource Files

Please prepare the pcc vm environment. We will need to use this virtual machine as a template, overwrite the boot firmware (removing signature checks) to load the customized LLB/iBoot for recovery.

- `~/Library/Application\ Support/com.apple.security-research.vrevm/VM-Library/pcc-research.vm`

### Download Firmware

We will prepare the hybrid firmware and modify it later.

- [https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw](https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipswhttps://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349)
- [https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349](https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipswhttps://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349)

Please put the downloaded .ipsw files into the Scripts folder.

Or, you can run the `prepare_firmware.sh` script alone which we will handle for you. 

## First Boot of the Virtual Machine

### Build the Binaries Required to Boot the VM

We can use the `vrevm` binary to boot the pcc virtual machine prepared by Apple, but since we need to boot customized firmware, we need to replicate the relevant configuration builder of `vrevm` and boot it manually.

```bash
➜  vphone-cli ./build_and_sign.sh
=== Building vphone-cli ===
[2/2] Compiling plugin GenerateDoccReference
Building for production...
[2/5] Write swift-version--3CB7CFEC50E0D141.txt
[3/4] Linking vphone-cli
Build complete! (1.66s)

=== Signing with entitlements ===
  entitlements: /Users/qaq/Desktop/vphone-cli/vphone.entitlements
/Users/qaq/Desktop/vphone-cli/.build/release/vphone-cli: replacing existing signature
  signed OK

=== Entitlement verification ===
[Dict]
	[Key] com.apple.private.virtualization
	[Value]
		[Bool] true
	[Key] com.apple.private.virtualization.security-research
	[Value]
		[Bool] true
	[Key] com.apple.security.get-task-allow
	[Value]
		[Bool] true
	[Key] com.apple.security.virtualization
	[Value]
		[Bool] true
	[Key] com.apple.vm.networking
	[Value]
		[Bool] true

=== Binary ===
-rwxr-xr-x  1 qaq  staff   1.6M Feb 26 15:54 /Users/qaq/Desktop/vphone-cli/.build/release/vphone-cli

Done. Run with:
  /Users/qaq/Desktop/vphone-cli/.build/release/vphone-cli --rom <rom> --disk <disk> --serial
➜  vphone-cli
```

```bash
➜  vphone-cli ./vphone-cli --help
OVERVIEW: Boot a virtual iPhone (PV=3) in DFU mode

Creates a Virtualization.framework VM with platform version 3 (vphone)
and boots it into DFU mode for firmware loading via irecovery.

Requires:
  - macOS 15+ (Sequoia or later)
  - SIP/AMFI disabled
  - Signed with vphone entitlements (done automatically by wrapper script)

Example:
  vphone-cli --rom firmware/rom.bin --disk firmware/disk.img --serial

USAGE: vphone-cli [<options>] --rom <rom> --disk <disk>

OPTIONS:
  --rom <rom>             Path to the AVPBooter / ROM binary
  --disk <disk>           Path to the disk image
  --nvram <nvram>         Path to NVRAM storage (created/overwritten) (default: nvram.bin)
  --cpu <cpu>             Number of CPU cores (default: 4)
  --memory <memory>       Memory size in MB (default: 4096)
  --serial                Allocate a PTY for serial console
  --serial-path <serial-path>
                          Path to an existing serial device
  --gdb-port <gdb-port>   GDB debug stub port (default: 8000)
  --stop-on-panic         Stop VM on guest panic
  --stop-on-fatal-error   Stop VM on fatal error
  --skip-sep              Skip SEP coprocessor setup
  --sep-storage <sep-storage>
                          Path to SEP storage file (created if missing)
  --sep-rom <sep-rom>     Path to SEP ROM binary
  --no-graphics           Run without GUI (headless)
  -h, --help              Show help information.
```

### Prepare VM Boot Firmware

Create a folder to store these files.

```bash
➜  vphone-cli tree VM

├── AVPBooter.vresearch1.bin
├── AVPSEPBooter.vresearch1.bin

├── AuxiliaryStorage
├── Disk.img
├── SEPStorage
└── config.plist

1 directory, 6 files
```

- AVPBooter.vresearch1.bin
  - /System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin
- AVPSEPBooter.vresearch1.bin
  - /System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPSEPBooter.vresearch1.bin
- Please copy the remaining files from `pcc-research.vm`

### Boot the VM into Recovery Mode

```bash
➜  vphone-cli ./boot_dfu.sh
=== vphone-cli ===
ROM   : ./VM/AVPBooter.vresearch1.bin
Disk  : ./VM/Disk.img
NVRAM : ./VM/nvram.bin
CPU   : 4
Memory: 4096 MB
GDB   : localhost:8000
SEP   : enabled
  storage: ./VM/SEPStorage
  rom    : ./VM/AVPSEPBooter.vresearch1.bin

[vphone] PV=3 hardware model: isSupported = true
[vphone] PTY: /dev/ttys001
2026-02-26 16:03:06.271 vphone-cli[85197:1074455] [vphone] SEP coprocessor configured (storage: /Users/qaq/Desktop/vphone-cli/VM/SEPStorage)
[vphone] SEP coprocessor enabled (storage: /Users/qaq/Desktop/vphone-cli/VM/SEPStorage)
[vphone] Configuration validated
[vphone] Starting DFU...
[vphone] VM
```

Please confirm the Chip ID in the System Information.

```bash
Apple Mobile Device (DFU Mode)：

  位置ID：	0x80100000
  连接类型：	Removable
  生产企业：	Apple Inc.
  序列号：	SDOM:01 CPID:FE01 CPRV:00 CPFM:00 SCEP:01 BDID:90 ECID:55E4D88BB1F30E6E IBFL:24 SRTG:[iBoot-13822.81.10]
  链接速度：	480 Mb/s
  USB供应商ID：	0x05ac
  USB产品ID：	0x1227
  USB产品版本：	0x0000
```

If `CPFM` does not match, it can probably be ignored. The smaller the value, the greater the modification permissions of the system. (Unverified)

- 00 should be an engineering sample
- 03 should be an end product

---

### Obtain Restore Firmware Signature


**It may be re-obtained later; this step is only to ensure your environment is working properly.** You need to add device adaptation information to `irecovery` for it to work correctly.

> This part could be ignored if you already follow the steps in compile libimobiledevice suite.

`{ "iPhone99,11", "vresearch101ap", 0x90, 0xFE01, "iPhone 99,11" }, `

```bash
git clone --recursive https://github.com/wh1te4ever/libirecovery
cd libirecovery
./autogen.sh
make -j8

# Must be installed to the system, idevicerestore used later depends on this framework
sudo make install
```

If anything goes well, you can query the virtual machine for device hardware information.

```bash
➜  CFW git:(main) ✗ irecovery -q
CPID: 0xfe01
CPRV: 0x00
BDID: 0x90
ECID: 0x02dea93bbf44524c
CPFM: 0x00
SCEP: 0x01
IBFL: 0x24
SRTG: iBoot-13822.81.10
SRNM: N/A
IMEI: N/A
NONC: e3a3267a539aa88454ec66edc7f8d1f3fade17ad44bb1e962a15f816203bb9b2
SNON: efbeaddeefbeaddeefbeaddeefbeaddeefbeadde
MODE: DFU
PRODUCT: iPhone99,11
MODEL: vresearch101ap
NAME: iPhone 99,11
```

Now, request the firmware signature. If the following error occurs, it might be because `autogen.sh` found a `libirecovery` in the system. The fastest way is to replace it directly. 🤣

```bash
➜  CFW git:(main) ✗ idevicerestore -e -y ./iPhone17,3_26.1_23B85_Restore -t
idevicerestore 1.0.0-270-g405fcd1 (libirecovery 1.3.1, libtatsu 1.0.5)
Found device in DFU mode
Unable to discover device type
```

```bash
# Replace /opt/homebrew/opt/libirecovery/lib/libirecovery-1.0.5.dylib with the following file
./src/.libs/libirecovery-1.0.dylib
./src/.libs/libirecovery-1.0.5.dylib
```

Make sure you see shsh in the output.

```bash
➜  CFW git:(main) ✗ idevicerestore -e -y ./iPhone17,3_26.1_23B85_Restore -t
idevicerestore 1.0.0-270-g405fcd1 (libirecovery 1.3.1, libtatsu 1.0.5)
Found device in DFU mode
ECID: 206788706982711884
Identified device as vresearch101ap, iPhone99,11
Device Product Version: N/A
Device Product Build: N/A
Extracting BuildManifest from IPSW
IPSW Product Version: 26.1
IPSW Product Build: 23B85 Major: 23
Device supports Image4: true
Variant: Darwin Cloud Customer Erase Install (IPSW)
This restore will erase all device data.
Checking IPSW for required components...
All required components found in IPSW
Getting ApNonce in DFU mode... e3 a3 26 7a 53 9a a8 84 54 ec 66 ed c7 f8 d1 f3 fa de 17 ad 44 bb 1e 96 2a 15 f8 16 20 3b b9 b2
Trying to fetch new SHSH blob
Getting SepNonce in dfu mode... ef be ad de ef be ad de ef be ad de ef be ad de ef be ad de
Received SHSH blobs
SHSH saved to 'shsh/206788706982711884-iPhone99,11-26.1.shsh'
➜  CFW git:(main) ✗
```

> **Note:** If fetching SHSH keeps failing here, you can skip this step and proceed. This might be caused by a mismatched BuildManifest or similar issues. The firmware preparation scripts in the subsequent steps will build the correct manifest. If you don't encounter any issues later, this error can be safely ignored.

## Unlock VM Firmware and build CFW

This part is very tedious, be prepared with patience. 

In order to make the research firmware accepting modded firmware, we need to patch `AVPBooter.vresearch1.bin`.  

### Obtain Firmware Content

Run it and confirm that the folder `iPhone17,3_26.1_23B85_Restore` **exists** on the Scripts folder. If it doesn't exist, please run `prepare_firmware.sh` first, which will download, extract and patch the ipsw for you.


### Patch Firmware

The patch system of the entire repository involves **41+ modifications**, covering 7 major categories of components.


```bash
  1. AVPBooter — DGST validation bypass via text-search + epilogue walk
  2. iBSS — serial labels + image4 callback bypass
  3. iBEC — serial labels + image4 callback + boot-args relocation
  4. LLB — serial labels + image4 callback + boot-args + 6 fixed patches (rootfs/panic)
  5. TXM — trustcache bypass
  6. kernelcache — 25 fixed patches (APFS, MAC hooks, debugger, launch constraints)
```

First you need to install some components

```bash
pip3 install keystone-engine capstone pyimg4
```

Then run the `patch_firmware.py` on Scripts folder.

```bash
➜  vphone git:(main) ✗   python3 patch_scripts/patch_firmware.py ~/Desktop/vphone-cli/VM

[*] VM directory:      /Users/qaq/Desktop/vphone-cli/VM
[*] Restore directory: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore
[*] Patching 6 boot-chain components ...

============================================================
  AVPBooter: /Users/qaq/Desktop/vphone-cli/VM/AVPBooter.vresearch1.bin
============================================================
  format: raw, 251856 bytes
  0x2C20: mov x0, #0 -> mov x0, #0
  [+] saved (raw)

============================================================
  iBSS: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore/Firmware/dfu/iBSS.d47.RELEASE.im4p
============================================================
  format: IM4P, fourcc=ibss, 3755424 bytes
  serial labels -> "Loaded iBSS"
  0x1F7BE0: b.ne -> nop, mov x0,x22 -> mov x0,#0
  [+] saved (IM4P)

============================================================
  iBEC: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore/Firmware/dfu/iBEC.d47.RELEASE.im4p
============================================================
  format: IM4P, fourcc=ibec, 3755424 bytes
  serial labels -> "Loaded iBEC"
  0x1F7BE0: b.ne -> nop, mov x0,x22 -> mov x0,#0
  boot-args -> "serial=3 -v debug=0x2014e %s" at 0x1B2970
  [+] saved (IM4P)

============================================================
  LLB: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore/Firmware/all_flash/LLB.d47.RELEASE.im4p
============================================================
  format: IM4P, fourcc=illb, 3755424 bytes
  serial labels -> "Loaded LLB"
  0x1F7BE0: b.ne -> nop, mov x0,x22 -> mov x0,#0
  boot-args -> "serial=3 -v debug=0x2014e %s" at 0x1B2970
  0x0002AFE8: b +0x2c: skip sig check
  0x0002ACA0: NOP sig verify
  0x0002B03C: b -0x258
  0x0002ECEC: NOP verify
  0x0002EEE8: b +0x24
  0x0001A64C: NOP: bypass panic
  [+] saved (IM4P)

============================================================
  TXM: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore/Firmware/txm.iphoneos.release.im4p
============================================================
  format: IM4P, fourcc=trxm, 458784 bytes
  0x0002C1F8: trustcache bypass
  [+] saved (IM4P)

============================================================
  kernelcache: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore/kernelcache.release.iphone17
============================================================
  format: IM4P, fourcc=krnl, 74104832 bytes
  0x02476964: _apfs_vfsop_mount (root snapshot)
  0x023CFDE4: _authapfs_seal_is_broken
  0x00F6D960: _bsd_init (rootvp auth)
  0x0163863C: _proc_check_launch_constraints
  0x01638640:   ret
  0x012C8138: _PE_i_can_has_debugger
  0x012C813C:   ret
  0x00FFAB98: post-validation NOP
  0x016405AC: postValidation (cmp w0, w0)
  0x016410BC: _check_dyld_policy_internal
  0x016410C8: _check_dyld_policy_internal
  0x0242011C: _apfs_graft
  0x02475044: _apfs_vfsop_mount (cmp x0, x0)
  0x02476C00: _apfs_mount_upgrade_checks
  0x0248C800: _handle_fsioc_graft
  0x023AC528: _hook_file_check_mmap
  0x023AC52C:   ret
  0x023AAB58: _hook_mount_check_mount
  0x023AAB5C:   ret
  0x023AA9A0: _hook_mount_check_remount
  0x023AA9A4:   ret
  0x023AA80C: _hook_mount_check_umount
  0x023AA810:   ret
  0x023A5514: _hook_vnode_check_rename
  0x023A5518:   ret
  [+] saved (IM4P)

============================================================
  All 6 components patched successfully!
============================================================
➜  vphone git:(main) ✗
```

### Verify patch status

Just execute `./boot_dfu.sh` above once again, it should be boot as expected.

## Fix Boot

After flashing the firmware, a series of modifications are still required to boot vphone.

### Boot to Ramdisk

Copy the following files from the software repository into the VM.

- build_ramdisk.py
- ramdisk_send.sh
- ramdisk_input.tar.zst

Boot into dfu mode, use `idevicerestore` to fetch `shsh`.

```bash
idevicerestore -e -y ./iPhone17,3_26.1_23B85_Restore -t

# Generate and save the shsh compressed as gz to ./shsh
➜  VM file shsh/18302609918026364278-iPhone99,11-26.1.shsh
gzip compressed data, original size modulo 2^32 5897
```
> If you encounter error stating reject for unknwon board model, this is due to the Build.plist it is referencing does not match with the device in DFU mode. Please make sure you have run the `prepare_firmware.sh` script which will patch it.

Build Ramdisk

```bash
➜  VM python3 ./build_ramdisk.py
[*] Setting up ramdisk_input/...
[*] VM directory:      /Users/qaq/Desktop/vphone-cli/VM
[*] Restore directory: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore
[*] SHSH blob:         /Users/qaq/Desktop/vphone-cli/VM/shsh/18302609918026364278-iPhone99,11-26.1.shsh

[*] Extracting IM4M from SHSH...

============================================================
  1. iBSS (already patched — extract & sign)
============================================================
  [+] iBSS.vresearch101.RELEASE.img4

============================================================
  2. iBEC (patch boot-args for ramdisk)
============================================================
  boot-args -> "serial=3 rd=md0 debug=0x2014e -v wdt=-1 %s" at 0x24070
  [+] iBEC.vresearch101.RELEASE.img4

============================================================
  3. SPTM (sign only)
============================================================
  [+] sptm.vresearch1.release.img4

============================================================
  4. DeviceTree (sign only)
============================================================
  [+] DeviceTree.vphone600ap.img4

============================================================
  5. SEP (sign only)
============================================================
  [+] sep-firmware.vresearch101.RELEASE.img4

============================================================
  6. TXM (patch release variant)
============================================================
  0x0002C1F8: trustcache bypass
  [+] preserved PAYP (264 bytes)
  [+] txm.img4

============================================================
  7. Kernelcache (already patched — repack as rkrn)
============================================================
  format: IM4P, 43991040 bytes
  [+] preserved PAYP (315 bytes)
  [+] krnl.img4

============================================================
  8. Ramdisk + Trustcache
============================================================
  Extracting base ramdisk...
  Mounting base ramdisk...
/dev/disk22
/dev/disk23         	EF57347C-0000-11AA-AA11-0030654
/dev/disk23s1       	41504653-0000-11AA-AA11-0030654	/Users/qaq/Desktop/vphone-cli/VM/SSHRD
  Creating expanded ramdisk (254 MB)...
............................................................................................................
created: /Users/qaq/Desktop/vphone-cli/VM/ramdisk_builder_temp/ramdisk1.dmg
"disk22" ejected.
  Mounting expanded ramdisk...
/dev/disk22
/dev/disk23         	EF57347C-0000-11AA-AA11-0030654
/dev/disk23s1       	41504653-0000-11AA-AA11-0030654	/Users/qaq/Desktop/vphone-cli/VM/SSHRD
  Injecting SSH tools...
  Re-signing Mach-O binaries...
  Building trustcache...
  [+] trustcache.img4
  Signing ramdisk...
  [+] ramdisk.img4

[*] Cleaning up ramdisk_builder_temp/...

============================================================
  Ramdisk build complete!
  Output: /Users/qaq/Desktop/vphone-cli/VM/Ramdisk/
============================================================
    DeviceTree.vphone600ap.img4                       13,808 bytes
    iBEC.vresearch101.RELEASE.img4                   611,171 bytes
    iBSS.vresearch101.RELEASE.img4                   611,171 bytes
    krnl.img4                                     14,373,497 bytes
    ramdisk.img4                                  266,344,150 bytes
    sep-firmware.vresearch101.RELEASE.img4         3,315,465 bytes
    sptm.vresearch1.release.img4                     108,385 bytes
    trustcache.img4                                   16,776 bytes
    txm.img4                                         166,876 bytes
```

Send Ramdisk and Boot

```bash
➜  VM ./ramdisk_send.sh
[*] Sending ramdisk from Ramdisk ...
  [1/8] Loading iBSS...
[==================================================] 100.0%
  [2/8] Loading iBEC...
[==================================================] 100.0%
  [3/8] Loading SPTM...
[==================================================] 100.0%
  [4/8] Loading TXM...
[==================================================] 100.0%
  [5/8] Loading trustcache...
[==================================================] 100.0%
  [6/8] Loading ramdisk...
[==================================================] 100.0%
  [7/8] Loading device tree...
[==================================================] 100.0%
  [8/8] Loading SEP...
[==================================================] 100.0%
  [*] Booting kernel...
[==================================================] 100.0%
[+] Boot sequence complete. Device should be booting into ramdisk.
```

Check `vphone-cli` output

```bash
private>
2026-02-26 12:26:55.359221+0000 Error driverkitd[4:14b][com.apple.km:DriverBinManager] contentsOfFile failed to read plist: <private>
IOReturn AppleUSBDeviceMux::setPropertiesGated(OSObject *) setting debug level to 7
USB init done
llllllllllllllllllllllllllllllllllllllllllllllllll
llllllllllllllllllllllllllllllllllllllllllllllllll
lllllc:;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;:clllll
lllll,.                                    .,lllll
lllll,                                      ,lllll
lllll,                                      ,lllll
lllll,      '::::,             .,::::.      ,lllll
lllll,      ,llll;             .:llll'      ,lllll
lllll,      ,llll;             .:llll'      ,lllll
lllll,      ,llll;             .:llll'      ,lllll
lllll,      ,llll;             .:llll'      ,lllll
lllll,      ,cccc,             .;cccc'      ,lllll
lllll,       ....               .....       ,lllll
lllll,                                      ,lllll
lllll,                                      ,lllll
lllll,            .''''''''''''.            ,lllll
lllll,            ,llllllllllll,            ,lllll
lllll,            ,llllllllllll,            ,lllll
lllll,            ..............            ,lllll
lllll,                                      ,lllll
lllll,                                      ,lllll
lllll:'....................................':lllll
llllllllllllllllllllllllllllllllllllllllllllllllll
llllllllllllllllllllllllllllllllllllllllllllllllll
llllllllllllllllllllllllllllllllllllllllllllllllll
SSHRD_Script by Nathan (verygenericname)
Running server
```

Connect to ssh service

```bash
➜  VM iproxy 2222 22

Creating listening port 2222 for device port 22
waiting for connection

# Map port 22 of the machine across the usb to 2222 of the current computer
```

```bash
➜  VM ssh root@127.0.0.1 -p2222

root@127.0.0.1's password: # Password is alpine
localhost:~ root# uname -a
Darwin localhost 25.1.0 Darwin Kernel Version 25.1.0: Thu Oct 23 11:11:48 PDT 2025; root:xnu-12377.42.6~55/RELEASE_ARM64_VRESEARCH1 iPhone99,11
localhost:~ root#
```

### Patch Boot Disk

First, you need to mount the disk

```bash
ocalhost:~ root# mount_apfs -o rw /dev/disk1s1 /mnt1
localhost:~ root# snaputil -l /mnt1
com.apple.os.update-8AAB8DBA5C8F1F756928411675F4A892087B04559CFB084B9E400E661ABAD119
localhost:~ root# snaputil -n $(snaputil -l /mnt1) orig-fs /mnt1
localhost:~ root# umount /mnt1

--
localhost:~ root# snaputil --help
Usage:
	snaputil -l <vol>                   (List all snapshots)
	snaputil -c <snap> <vol>            (Create snapshot)
	snaputil -n <snap> <newname> <vol>  (Rename snapshot)
	snaputil -d <snap> <vol>            (Delete snapshot)
	snaputil -r <snap> <vol>            (Revert to snapshot)
	snaputil -s <snap> <vol> <mntpnt>   (Mount snapshot)
	snaputil -o                         (Print original snapshot name)
# This is a routine operation for older jailbreaks ()
```

Then some binary updates are required

```bash
➜  VM ./install_cfw.sh
[*] install_cfw.sh — Installing CFW on vphone...
[+] Restore directory: /Users/qaq/Desktop/vphone-cli/VM/iPhone17,3_26.1_23B85_Restore
[+] Input resources: /Users/qaq/Desktop/vphone-cli/VM/cfw_input

[*] Parsing BuildManifest for Cryptex paths...
  SystemOS: 043-54303-126.dmg.aea
  AppOS:    043-54062-129.dmg

[1/7] Installing Cryptex (SystemOS + AppOS)...
  Using cached SystemOS DMG
  Using cached AppOS DMG
  Mounting SystemOS...
/dev/disk22
/dev/disk23         	EF57347C-0000-11AA-AA11-0030654
/dev/disk23s1       	41504653-0000-11AA-AA11-0030654	/Users/qaq/Desktop/vphone-cli/VM/.cfw_temp/mnt_sysos
  Mounting AppOS...
/dev/disk24
/dev/disk25         	EF57347C-0000-11AA-AA11-0030654
/dev/disk25s1       	41504653-0000-11AA-AA11-0030654	/Users/qaq/Desktop/vphone-cli/VM/.cfw_temp/mnt_appos
  Mounting device rootfs rw...
  Copying Cryptexes to device (this takes ~3 minutes)...
  Creating dyld symlinks...
  Unmounting Cryptex DMGs...
"disk22" ejected.
"disk24" ejected.
  [+] Cryptex installed

[2/7] Patching seputil...
  Found format string at 0x1B3F0: b'/%s.gl\x00'
  [+] Patched at 0x1B3F1: %s -> AA
      /%s.gl -> /AA.gl
  Renaming gigalocker...
  [+] seputil patched

[3/7] Installing AppleParavirtGPUMetalIOGPUFamily...
  [+] GPU driver installed

[4/7] Installing iosbinpack64...
/usr/bin/tar: Ignoring unknown extended header keyword `SCHILY.xattr.com.apple.quarantine'
/usr/bin/tar: Ignoring unknown extended header keyword `LIBARCHIVE.xattr.com.apple.quarantine'
/usr/bin/tar: Ignoring unknown extended header keyword `SCHILY.xattr.com.apple.quarantine'
  [+] iosbinpack64 installed

[5/7] Patching launchd_cache_loader...
  Found anchor 'unsecure_cache' inside "launchd_unsecure_cache="
    String start: va:0x10000238E  (match at va:0x100002396)
  Found string ref at 0xB48
  Patching: cbz x0, #0xbfc -> nop
  [+] NOPped at 0xB58
  [+] launchd_cache_loader patched

[6/7] Patching mobileactivationd...
  Found via symtab: va:0x1002F5F84 -> foff:0x2F5F84
  Original: ldrb w0, [x0, #0x14]
  [+] Patched at 0x2F5F84: mov x0, #1; ret
  [+] mobileactivationd patched

[7/7] Installing LaunchDaemons...
  Patching launchd.plist...
  [+] Injected bash
  [+] Injected dropbear
  [+] Injected trollvnc
  [+] LaunchDaemons installed

[*] Unmounting device filesystems...
[*] Cleaning up temp binaries...

[+] CFW installation complete!
    Reboot the device for changes to take effect.
    After boot, SSH will be available on port 22222 (password: alpine)
➜  VM
```

Then ssh into it and enter `halt`

```bash
launchd quiesce complete
AppleSEPManager: Received Paging off notification
AppleUSBDeviceMux::message - kMessageInterfaceWasDeActivated
AppleUSBDeviceMux::reportStats: USB mux statistics:
USB mux: 4117556 reads / 0 errors, 2628065 writes / 0 errors
USB mux: 0 short packets, 0 dups
asyncReadComplete:1829 USB read status = 0xe00002eb
asyncReadComplete:1829 USB read status = 0xe00002eb
apfs_log_op_with_proc:3297: md0s1 unmounting volume ramdisk, requested by: launchd (pid 1); parent: kernel_task (pid 0)
apfs_vfsop_unmount:3209: md0s1 apfs_fx_defrag_stop_defrag failed w/22
apfs_vfsop_unmount:3583: md0 nx_num_vols_mounted is 0
is_system_shutting_down:961: System is shutting down - stop any apfs bg work.
apfs: total mem allocated: 720 (0 mb);
apfs_vfsop_unmount:3596: all done.  going home.  (numMountedAPFSVolumes 0)
virtual void AppleSEPManager::systemWillShutdown(IOOptionBits): Received system will shut down notification

ApplePSCI - system off
[vphone] Guest stopped
```

## First Boot

Congratulations, things are done.

```bash
➜  vphone-cli ./boot.sh
=== Building vphone-cli ===
[2/2] Compiling plugin GenerateDoccReference

<Omitted>

Using default cache paths
Code: /System/Library/xpc/launchd.plist Sig: /System/Library/xpc/launchd.plist.sig
Using unsecure cache: /System/Library/xpc/launchd.plist
Trying to send bytes to launchd: 2563 16384
Sending validated cache to launchd
Cache sent to launchd successfully
com.apple.xpc.launchd|2026-02-26 05:34:50.946410 (finish-restore) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:50.948556 (finish-demo-restore) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:50.951290 (sysstatuscheck) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:50.953692 (prng_seedctl) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:50.956821 (launchd_cache_loader) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:50.968980 (workload-properties-init) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:50.968988 (init-exclavekit) <Notice>: Doing boot task
com.apple.xpc.launchd|2026-02-26 05:34:51.015964 (boot) <Notice>: Early boot complete. Continuing system boot.
com.apple.xpc.launchd|2026-02-26 05:34:51.048686 <Notice>: Got first unlock unregistering for AKS events
bash-4.4#
```

After entering bash, you need to initialize the shell environment.

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

/iosbinpack64/bin/mkdir -p /var/dropbear
/iosbinpack64/bin/cp /iosbinpack64/etc/profile /var/profile
/iosbinpack64/bin/cp /iosbinpack64/etc/motd /var/motd

shutdown -h now

<...>
"AppleSEPKeyStore":pid:0,:4007: Ready for System Shutdown
virtual void AppleSEPManager::systemWillShutdown(IOOptionBits): Received system will shut down notification

ApplePSCI - system off
[vphone] Guest stopped
<...>
```

To connect to the virtual machine, please use `iproxy` to forward 22222 and 5901.

```bash
iproxy 5901 5901
iproxy 22222 22222
```

## Appendix

### Boot pcc vm

```bash
pccvre release download --release 35622
pccvre instance create -N pcc-research -R 35622 --variant research
```

- <https://appledb.dev/firmware/cloudOS/23B85.html>
- <https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349>

```bash
vrevm restore -d -f --name pcc-research \
    -K ~/Desktop/kernelcache.research.vresearch101 \
    -S ~/Desktop/Firmware/sptm.vresearch1.release.im4p \
    -M ~/Desktop/Firmware/txm.iphoneos.research.im4p \
    --variant-name "Research Darwin Cloud Customer Erase Install (IPSW)" \
    ~/Desktop/PCC-CloudOS-26.1-23B85.ipsw
```

```bash
vrevm run --name pcc-research --debug
```

```bash
Starting VM: pcc-research (ecid: 8737a35e085fc3a7)
GDB stub available at localhost:50693
SEP GDB stub available at localhost:50694
Console log available at: /Users/qaq/Library/Application Support/com.apple.security-research.vrevm/VM-Library/pcc-research.vm/logs/console.2026-02-26T15:51:26/device
Started VM: pcc-research
======== Start of iBoot serial output. ========
89994699affdef:138
503b7933ad51055:716
image <<PTR>>: bdev <<PTR>> type illb offset 0x20000 len 0x4cbe4
78faf5021313e82:74
78faf5021313e82:85
ae71af5ee32b84:129


=======================================
::
:: ������� Supervisor iBoot for vresearch101, Copyright 2007-2025, Apple Inc.
::
::	Local boot, Board 0x90 (vresearch101ap)/Rev 0x0
::
::	BUILD_TAG: iBoot-13822.42.2
::
::	UUID: AD1D9BE7-3400-3E52-856C-D32D1A03C0A7
::
::	BUILD_STYLE: RESEARCH_RELEASE
::
::	USB_SERIAL_NUMBER: SDOM:01 CPID:FE01 CPRV:00 CPFM:03 SCEP:01 BDID:90 ECID:8737A35E085FC3A7 IBFL:3D
::
=======================================

a3fae6c53b7baa2:107
3974bfd3d441da3:1609
3974bfd3d441da3:1685
503b7933ad51055:716
503b7933ad51055:716
3b9107561aef41e:187
3b9107561aef41e:254
2dc92642a4f3ce5:39
2dc92642a4f3ce5:39
a60aa294185a059:983
a60aa294185a059:986
3bdace14b1a9a68:3646
3bdace14b1a9a68:3975
7ab90c923dae682:1384
======== End of iBoot serial output. ========
```

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
