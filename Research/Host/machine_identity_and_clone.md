# Machine identity and `vm clone --new-identity`

Where a machine's device identity lives, what `vm clone --new-identity`
changes, and why it changes nothing else. The implementation is
`VPhoneBundleOperations.clone` and `resetIdentity` in
`VPhoneKit/VPhoneCoreKit/Bundle/VPhoneBundleOperations.swift`; user-facing
behaviour is in `Documents/Guides/create-and-run.md`.

Tested on 2026-10-06 from one stopped source machine (iPhone17,3 guest, iOS
27.0 24A435 with cloudOS 26.4 23E5207q, bundle 2.6.0, standard preset), cloned
five times with `clonefile` and edited by hand before the command existed.
The source was never started; its files kept their modification times.

## Summary

The identity is the ECID, and only the ECID. Clearing `machineIdentifier`
(and `networkConfig.macAddress`) in the copy's `config.plist` makes
`vphone-vm` create new ones on the next start. The guest then boots with a new
`UniqueDeviceID` and `UniqueChipID`, its data unlocked, vphoned answering and
lockdown reporting `ActivationState: Activated`. It survives a second boot and
runs beside another clone of the same source.

`nvram.bin`, `SEPStorage` and the disk image must stay exactly as copied. They
come from one restore and cannot be regenerated separately.

## Where identity lives

### In the machine folder

| File | What it binds | `--new-identity` |
| --- | --- | --- |
| `config.plist` `machineIdentifier` | The ECID: a binary plist `{ECID = <u64>}`, the data representation of `VZMacMachineIdentifier`. `VPhoneVirtualMachine.init` creates and saves one when it is empty or invalid. | Cleared |
| `config.plist` `networkConfig.macAddress` | The NIC's MAC, and with it the NAT DHCP lease. Generated and saved on first start when empty. | Cleared |
| `config.plist` `ipv4`, `portForwards`, `localHostName` | A fixed address, host ports and a `.local` name. Two running machines cannot share any of them. | Cleared; a `.local` name derived from the old machine name is re-derived from the new one |
| `udid-prediction.txt` | Output derived from the ECID, rewritten on every start. | Deleted |
| `nvram.bin` (`VZMacAuxiliaryStorage`, 33 MB) | The NOR boot images restore wrote (LLB, iBoot, with their IM4M, whose `ECID` property holds the old ECID) and the NVRAM variables. An empty one has no boot firmware. | Kept |
| `SEPStorage` (512 KB) | The virtual SEP's persistent store: a 32-byte per-machine secret at 0x20, A/B records at 0x1000 and 0x8000 holding the ECID and boot-manifest hash, anti-replay records from 0x2000. | Kept |
| Patch receipts, `restore-info.json`, `FirmwareOriginals/`, ROMs, `launchpad.json` | Nothing identity related. | Kept |
| `vphone.sock`, `Snapshots/` | The source's control socket and its snapshot history. | Deleted by every clone |

### Inside the disk image

Attached read-only, a restored disk has System, Data (FileVault, locked),
xART, Hardware, Preboot, Update and User (FileVault, locked) volumes.

- **Preboot** `/<boot-manifest-hash>/` holds `apticket.der`, the SEP firmware,
  device tree, root hash, kernelcache and FUD images. Every IM4M names the old
  ECID. They still boot under a new one (next section).
- **Hardware** holds a copy of the ticket and `mobileactivationd.uuid`, a UUID
  not derived from the ECID. Every clone shares it.
- **xART** holds the gigalocker `AA.gl`. CFW fixes its name
  (`renameGigalocker` in `VPhoneCustomFirmwareInstaller.swift`) instead of
  letting it follow the device UUID. It is bound to the SEP secret in
  `SEPStorage`.
- **Data and User** volume keys are wrapped by the SEP (`nx_keybag_lookup_vek:
  successfully loaded volume class keys` at boot). Lockdown state under
  `/private/var/root/Library/Lockdown/` has no activation record, since the
  guest is hacktivated, and `data_ark.plist` holds no UDID or ECID. The
  MobileGestalt cache holds neither in any byte order.

The guest computes `UniqueDeviceID`, `UniqueChipID`, its Wi-Fi, Bluetooth and
Ethernet MACs and the USB serial from the ECID Virtualization presents, so all
of them change with it. Only libignition's `ecid :` log line still shows the
old value, because it reads the ticket.

## No re-personalization is needed

The boot chain already ignores the ECID in its tickets
([iBoot patches](../Firmware/iboot_patches.md),
[firmware manifest and origins](../Firmware/firmware_manifest_and_origins.md)):

- AVPBooter's DGST bypass loads LLB from `nvram.bin`.
- iBSS, iBEC and LLB force `image4_validate_property_callback` to return 0.
  That callback checks `ECID`, `BNCH`, `BORD`, `CHIP` and the rest, so a
  mismatched ECID passes with them. LLB and iBoot load the kernel, device tree,
  TXM and SPTM from Preboot through the same callback.
- The SEP firmware is checked by the unpatched AVPSEPBooter, which still logs
  `AppleSEPBooter: SEP accepted IMG4` under a new ECID: the virtual SEP ROM
  does not enforce it.

A new-identity clone's serial log shows the new ECID in `USB_SERIAL_NUMBER`.
Its error and failure lines, normalized, are identical to those of a clone that
kept the old identity.

## Replacing `SEPStorage` panics the guest

| Clone | ECID | `SEPStorage` | xART | Result |
| --- | --- | --- | --- | --- |
| a | kept | kept | kept | Boots; old UDID; the host's pairing still works |
| b | **new** | kept | kept | **Boots**; SEP alive, Data and User mounted, vphoned answers; new UDID, so the host must be trusted again; second boot fine; runs beside a |
| c | new | deleted (Virtualization makes a new one) | kept | `SEP accepted IMG4`, gigalocker initialized, then `panic: SEP Panic: :AESS/AESS` after mount phase 2, before Data mounts |
| d | **kept** | deleted | kept | The same AESS panic: it comes from the new SEP secret, not the ECID |
| e | new | deleted | `AA.gl` deleted on the host | `init_data_protection: Gigalocker file … doesn't exist`, then `panic: seputil[6] exited … exit status 2` |

iOS never obliterates for a changed identity or SEP: Obliterator reports `No
obliteration needed` and the guest panics instead of hanging. `SEPStorage`, the
xART gigalocker and the Data and User volume keys are made together by one
restore. The host can write xART but cannot mount the encrypted Data volume,
so there is no offline way to reset Data alone; a fresh SEP needs restored's
data-protection setup, which is an erasing restore.

It follows that `SEPStorage` and the disk image must be taken at the same
moment. The gigalocker and the anti-replay records advance together, so a copy
of a running machine can pair a disk with SEP state from another moment.
`vm clone` refuses while the source runs (`VPhoneBundleActivity.requireStopped`
looks for a process holding the disk image, `SEPStorage` or `nvram.bin` open, or
a control socket that answers). A holder that runs no machine, such as
Launchpad's disk meter, is waited out for up to 2 s first; a VM holder refuses
at once (`Research/Host/machine_templates.md`, Disk use). Host-side writes to the disk image by `cfw
install` or `--update-environment` do not break the pairing: a source whose
disk image was modified hours after its `SEPStorage` cloned and booted fine.

## Disk cost

Measured with `F_LOG2PHYS_EXT`, comparing the physical blocks of the source's
and a clone's disk image:

| Comparison | Shared | Clone's own |
| --- | --- | --- |
| After clone, before boot | 20.32 GB | 0.00 GB |
| Same-identity clone, one boot | 20.04 GB | 0.34 GB |
| Same-identity clone, two boots | 19.98 GB | 0.36 GB |
| New-identity clone, two boots | 19.94 GB | 0.34 GB |
| Two clones against each other | 19.94 GB | about 0.4 GB each |
| Panicking clones c, d, e | 20.28 GB | 0.00 GB (guest TRIM punched holes, freeing about 0.03 GB) |

`nvram.bin` and `SEPStorage` are cloned too and diverge by a few blocks.
A clone therefore costs about 0.35 GB after its first boots and grows with
use, where a restore writes about 20 GB plus an 11 GB temporary restore tree.
`du` reports the full 20 GB for every clone (Launchpad's Exclusive column
compares extents instead), and deleting the source frees no shared blocks
while a clone remains. How this compares with the other ways of saving disk
space is in [disk space](disk_space.md).

## Shared state and caveats

- Every clone of one source shares its SEP root secret (in principle one clone
  could decrypt another's Data volume), `mobileactivationd.uuid`, and whatever
  the source's Data volume held: trusted hosts, Developer Mode, Setup
  Assistant state, device-bound keychain items. Research guests are
  hacktivated and show no functional effect. Signing a clone into Apple
  services, where servers could see several devices with one set of device
  keys, was not tested.
- The host trusts each guest by UDID, so lockdown tools need the guest's
  "Trust This Computer" prompt again after a new identity. Tapping Trust and
  then `idevicepair pair` worked. Copying the host's pair record
  (`/var/db/lockdown/<old UDID>.plist`) to the new UDID might skip the
  prompt; it needs root, so a Launchpad helper verb, and was not tried.
- A plain clone keeps the source's ECID and MAC, so it has the same UDID and
  competes for the same DHCP lease if both run: it is a backup, not a second
  machine.
- A clone that later runs `restore` is personalized for its new ECID, as
  usual. `cfw update-kernel` and `--update-environment` write through a host
  mount and do not involve the ECID.
- Deleting clones leaves their DHCP bindings to unused MACs;
  `vm leases --release-orphans` returns them (see
  [network notes](network_fixed_address.md)).
- Two machines restored separately share no disk blocks, although about 8.6 GB
  of their images is identical; `vm rebase` re-shares it without touching
  `SEPStorage`, `nvram.bin` or the identity (see [disk rebase](disk_rebase.md)).
