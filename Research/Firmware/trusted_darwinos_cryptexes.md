# Trusted darwinOS and runtime cryptexes on `minimal`

`minimal` restores a resealed system onto a stock boot chain, kernel and TXM, and
nothing may write the System volume afterwards: changing what the guest runs
meant building a new restore image and restoring again. cloudOS solves the same
problem with cryptexes, signed disk images that `cryptexd` mounts at runtime with
their own trust cache. They work only in the trusted darwinOS environment, which
a restore had never asked for. `filesystem-exp-trusted_darwinos` (the
`trusted-darwinos` feature, "Trusted darwinOS environment", a box under the preset
in New Machine's Patches page and in Patch Settings…) asks for it
and adds what installing a cryptex needs.

This ports Lakr233/vphone-cli#344 (June 2026), which got there by restoring through
MobileDevice instead of idevicerestore. The difference between the two restores
turned out to be one TSS tag, so the vendored restore stays.

## Why one environment both adds cryptexes and restricts

Trusted darwinOS is the production environment of PCC nodes, not a debugging
mode. It is built so that nothing runs that Apple did not sign for that node:

- A cryptex is not a way around code signing. It is a disk image with its own
  trust cache whose ticket Apple's signing server issues for one device
  (`personalize`), so it is the sanctioned way to add code to a sealed system
  without rebuilding it. iOS guests had no use for it because iOS updates the
  whole system instead.
- Restricted Execution Mode splits the node's life in two: before REM, setup
  (darwin-init on cloudOS) installs the cryptexes it needs; after it, only
  binaries whose trust cache entry allows "after" may run. An iOS guest never
  enters REM; it stays before it, which is why every entry gets both bits.
- Developer Mode in that environment is reserved to Apple's research build of
  AMFI (below), the one the PCC VRE ships.

What looks like loosening on a guest comes from elsewhere: Apple's signing
server personalizes a cryptex built with `cryptexctl.research` for the
vresearch101 board, as it does for a PCC VRE node (seen with #344 in June). The
cryptex is still signed, for this guest only; what the research tools add is who
may build one.

## The environment comes from the ticket

Every cloudOS research build identity carries `Ap,OSEnvironment = 0x06`. Apple's
restore host copies it into the AP TSS request; iBoot reads it back from the
ticket and applies the matching overlay under `/osenvironments` in the device
tree. For 6 that is `trusted-darwinos`, which sets
`/chosen/darwinos-security-environment = 6`; AMFI and TXM read that property.
libtatsu 1.0.5, which idevicerestore calls, builds the AP request from a fixed
list of `Ap,*` tags without this one, so no vphone ticket had an environment,
and iBoot booted every guest in the default one.

- `vphone_tss_add_os_environment` (`MobileRestoreCore/Core/idevicerestore.c`)
  adds the tag, string or integer, whenever the build identity has it, as
  Apple's host does. It is the second edit to upstream code in that target.
- `FirmwareManifest.buildEraseIdentity` drops `Ap,OSEnvironment` from the hybrid
  identity it deep-copies from the cloudOS one, so `standard` and a plain
  `minimal` keep the environment they have always had.
- With the patch on, `CryptexFilesystemPatcher.setUpdatedComponentsInManifest`
  writes `Ap,OSEnvironment = 0x06` back into the identity; with it off, it
  removes it. The restore then logs `Requesting Ap,OSEnvironment = 6`, and Apple's
  TSS signs it for the vresearch101 board.

The temporary cloudOS restore that recovers the GPU driver restores cloudOS's own
manifest, so it now asks for environment 6 too, as a PCC VRE restore does.

An environment is part of the ticket, so the box reaches a guest only through a
restore: `fw patch` then a restore, not `cfw install`.

## Restricted Execution Mode

In environment 6 AMFI enforces Restricted Execution Mode. A binary runs only if
its trust cache entry allows the REM phase the system is in. An iOS userland
restored as trusted darwinOS from Apple's stock trust cache (a `standard` guest,
2026-11-10) panics at once:

```
AMFI: com.apple.xpc.launchd not allowed for Restricted Execution Mode state (disabled)
panic: unexpected SIGKILL of init
```

Apple's iOS entries have flags `0x00`. The two REM bits, read off
`cryptexctl generate-trust-cache --restricted-exec-mode-default` with each value
(host cryptexctl, macOS 26.5):

| Option | Entry flags |
| --- | --- |
| `none` | `0x00` |
| `before` | `0x40` |
| `after` | `0x80` |
| `both` | `0xC0` |
| (no option) | `0xC0` — the help text says the default is `before` |

`minimal` rebuilds the static trust cache with cryptexctl, which gives every
binary its scan finds `0xC0`. But it copies each `--base-trust-cache` entry as it
is, and the base caches are Apple's (plus launchd.plist's detached signature): the
same CDHash is then listed twice, once allowed and once not. #344 dropped the base
caches for that reason. They are needed now for the detached signature, so with
the patch on, `TrustCache.allowingBothRestrictedExecutionPhases` keeps one entry
per CDHash and hash type and sets `0xC0` on it, after the constraint categories
are copied in (`addConstraintCategories`). The patch log says how many duplicates
it dropped.

## Developer Mode

AMFI's start routine (`com.apple.driver.AppleMobileFileIntegrity`) reads
`/chosen/darwinos-security-environment` and remembers whether it is 6. Later,
deciding Developer Mode, it asks a one-instruction function whether it is the
research variant:

```
if research_variant() && trusted_darwinos:  "developer mode is enabled in the trusted darwinos research variant"  -> on
elif !<config byte>:                        "developer mode is force enabled"                                    -> on
elif trusted_darwinos:                      "Developer Mode can not be enabled on trusted darwinOS."             -> off
else:                                       "trying to get developer mode status from ACM"
```

`research_variant()` is `mov w8, #1` in a research kernelcache and `mov w8, #0`
in a release one (`ipsw kernel extract` of AMFI, then `ipsw macho disass`):

| Kernelcache | `research_variant()` |
| --- | --- |
| PCC VRE `kernelcache.research.vresearch101` | 1 |
| cloudOS 26.5 (23F75) `kernelcache.research.vresearch101` | 1 |
| iOS 26.5 (23F77) `kernelcache.research.iphone17` | 1 |
| cloudOS 26.5 `kernelcache.release.vresearch101`, iOS 26.5 `kernelcache.release.iphone17` | 0 |
| the research-board mix `fw patch` built for iPhone17,3 26.5 (osenv6) | 0 |

A cloudOS without vphone600 components (26.5 to 26.7) gets the research-board
kernel mix (`kernel-boot-vresearch101_kext_mix`), whose base is the release
`kernelcache.release.vresearch101` (`kernelcache_recipes/bases/26.5_23F77`), and
the mix takes AMFI from its base. So on such a guest trusted darwinOS means no
Developer Mode, which the osenv6 boot logged: no Xcode, Developer disk image or
`userspace-debugging`. A cloudOS with vphone600 components restores its research
`KernelCache`, whose AMFI should take the first branch; not yet tried. Taking
AMFI from a research donor in the mix, or a kernel patch of `research_variant()`,
would give it back on the research board; neither is done here.

## NRDUpdated panics TXM

A trusted darwinOS guest panicked minutes into its first boot with network, as
the MobileDevice-restored guests of #344 did in June ("from time to time ...
within the first 10 minutes"; they were in environment 6 too, since MobileDevice
sends the tag):

```
AppleMobileFileIntegrityUserClient::loadTrustCache(...): PID 611 is requesting a trust cache load
panic(cpu 7 caller ...): TXM [Panic]: [code: 0x000000F3 | 4]
Panicked task ...: pid 611: NRDUpdated
```

- `/usr/libexec/NRDUpdated` keeps the recoveryOS (NeRD) up to date. Its one
  trust cache type is `com.apple.private.pmap.load-trust-cache =
  ["global.ota-update-brain"]`: the `.TrustCache` of the
  `com.apple.MobileAsset.RecoveryOSUpdateBrain` asset it downloads. None ships in
  the 23F77 system. Its job (`com.apple.mobile.NRDUpdated`) is not run at load;
  it starts on its MachService or two XPC activities that need a network, and
  relaunches a downloaded brain when it starts.
- TXM (25.5, UUID 9157CCA7) sets platform identity 7 when
  `/chosen/darwinos-security-environment` is 6, 1 for an iPhone and 2 for an iPad
  otherwise. Of its policy tables only identity 7's has Restricted Execution Mode
  support, and only with it does the trust cache load handler check the cache
  against a digest record on the TXM–SEP shared page (magic `0x5c02`). A mismatch
  is `0xF3 | 4`: 4 is the digest mismatch, and TXM panics rather than refusing.
  The digest the SEP pins presumably matches personalized caches, which is why
  cryptexd's loads pass; not confirmed, the page was not read.
- Environment-0 guests log the same NRDUpdated load without a panic (26.5 console
  logs of earlier machines): no REM support, no check.

With the patch on, the merge leaves `com.apple.mobile.NRDUpdated` out of
`launchd.plist` before re-signing it (`dropNRDUpdated`). A VM has no recoveryOS
to update; lookups of the service fail and are logged. Another loader of a
trust cache that is not personalized would hit the same check; the 23F77 system
has not been scanned for `load-trust-cache` entitlements yet. The removal runs
in the vphoned step, which `minimal` always has.

## Persisted cryptexes panic TXM at boot

`cryptexctl install --persist` has cryptexd install a cryptex again at each
boot. Tested on cryptex9 (iOS 26.5 23F77, cloudOS 26.5, 2026-11-11):

- One persisted cryptex (a shell script) came back after `system.reboot`,
  mounted at its path and readable; cryptexes installed without `--persist`
  were gone.
- With two persisted cryptexes (that one and a cryptex whose launch daemon
  answers on a TCP port), 3 of 12 boots panicked, the guest left halted:

  ```
  AppleMobileFileIntegrityUserClient::loadTrustCache(...): PID 189 is requesting a trust cache load
  panic(cpu 3 caller ...): TXM [Panic]: [code: 0x000000F3 | 4]
  Panicked task ...: pid 189: cryptexd
  ```

  The boots that came up (9, warm and cold) had the launch daemon running from
  the persisted cryptex.

cryptexd reinstalls persisted cryptexes in parallel. In each boot that came up,
the kernel log has one cryptex's image validated, mounted and its trust cache
loaded before the next image's validation (`Validating payload and manifest for
authenticated snapshot mount`). In each panic, the second image was validated
before the first trust cache load had completed: twice both images before any
load, once the second between the first load request and its result. A
runtime install (`cryptex.install`) personalizes and installs one cryptex at a
time and never showed it.

The code, `| 4`, is the digest mismatch of the Restricted Execution Mode check
described under NRDUpdated above. Presumably authenticating an image records
its digest on the TXM–SEP shared page, and the later validation replaces the
first cryptex's record before its trust cache is checked; the page was not
read, and the log does not name the trust cache being loaded. Whatever the
mechanism, TXM panics rather than refusing.

So vphoned never passes `--persist`. `cryptex.install` with `persist: true`
keeps the cryptex instead, under `/var/db/vphoned/cryptexes/<identifier>`: the
uploaded `.cxbd`, its personalized copy and the variant. When vphoned starts, it
installs each kept cryptex that `cryptexctl list` does not show, one after
another: with the kept ticket first, and if cryptexd refuses that, personalized
again (which needs the network; retried for a few minutes). Every cryptexctl run
in vphoned goes through one serial queue, so two clients installing at the same
time take turns as well. `cryptex.uninstall` forgets a kept cryptex.

The identifier comes from the `.cxbd` itself: `CFBundleIdentifier` in the
`ginf` of its one `Restore/Cryptex/<identifier>`. `install --print-info`
starts with the identifier on cryptexctl 26.5, but cryptexctl 18.6 prints no
identifier, and taking the identifier from that output left iOS 18 guests with
an installed cryptex that was not kept ("installed, but not kept: cryptexctl
named no identifier"; 2026-11-13).

Tested on cryptex10 (iOS 26.5 23F77, cloudOS 26.5, bundle 2.16.1-local.7023417e,
2026-11-11) with the same two cryptexes, both installed with `persist: true`:
18 reboots (`system.reboot`) and one cold start, no panic. After each, both
were mounted within 16–27 seconds of boot and the launch daemon answered from
its cryptex. The kept tickets were used: the personalized copies kept the time
of the original install, so no boot asked Apple's signing server. After
`cryptex.uninstall` of both, `persisted` was empty and a reboot brought neither
back. Whether a ticket stays valid across a nonce change (an erase, a restore)
is not known; the fallback personalizes again.

## cryptexctl in the guest

iOS has no cryptexctl. cloudOS's `/usr/bin/cryptexctl` is an iOS-platform
binary (minos matches the cloudOS release), Apple ad hoc signed
(`com.apple.security.cryptexctl`), with the entitlements its `personalize` and
`install` need (`com.apple.private.amfi.can-load-trust-cache`, the
`com.apple.private.img4.nonce.cryptex*` set, RemoteServiceDiscovery
device-admin). Its libraries (libcryptex, libauthinstall, libamsupport,
DiskImages2, StorageKit, RemoteXPC) are system libraries.

- `fw prepare` (`VPhonePCCCryptexctl.stage`) decrypts the cloudOS OS image
  (772 MB as AEA for 26.5 23F75; the key comes from Apple's WKMS as for the
  iPhone OS image), mounts it read-only, and keeps only
  `.pcc-cryptexctl/cryptexctl` in the restore tree. The binary is cached per
  cloudOS build beside its GPU driver
  (`~/.vphone/gpu-drivers/<version>_<build>/cryptexctl`), so a build needs the
  key once.
- WKMS refuses cloudOS keys at times: it served the 26.5 key in the morning of
  2026-11-10 and answered 403 for every cloudOS key tried (26.5, 26.4, 18.6)
  from that afternoon into 2026-11-11, `ipsw fw aea --key` included, while the
  iPhone 26.5 key kept working. A restore does not need that key: the restored
  device gets it itself, as in pccvre's VMs. So when the key fetch fails and the
  patch is on, `fw prepare` restores cloudOS in a temporary VM
  (`VPhonePCCGPURecovery`, the GPU driver's fallback) and copies cryptexctl off
  the restored System volume. That recovery takes cryptexctl whenever it runs,
  for the GPU driver too.
- Launchpad records the build's patch overrides with `fw set-patches` before
  `fw prepare`, so the box is in the plan there. Without it, `fw prepare` still
  tries the cache and the key for every iPhone or iPad restore image, so a box
  turned on later usually finds cryptexctl, and a failure is only a note.
- The merge copies it to `/usr/bin/cryptexctl` (`addCryptexctl`); the trust cache
  scan takes its cdhash like any other binary in the image. A tree prepared
  without it (by an older bundle) fails the merge with an instruction to prepare
  again.

## Installing a cryptex

The host builds the cryptex: a disk image of a folder, then
`/System/Library/SecurityResearch/usr/bin/cryptexctl.research create` for the
vresearch101 board (`--FCHP=0xff10 --TYPE=0x3 --STYP=0x1 --CLAS=0xf2 --NDOM=0x3
--BORD=0x90 --CHIP=0xfe01 --SDOM=0x1`, REM `both`), mounted at
`/private/var/DarwinDataCenterSupportImage/<identifier>`; the variant is the
identifier. The result is a `.cxbd` directory: `Restore/BuildManifest.plist` and
`Restore/Cryptex/<identifier>/{ginf,gdmg,gtcd,gtgv}`.

### Mount paths

The kernel decides where cryptexd may mount: the Sandbox kext's platform
profile, operation `file-mount`. cryptexd creates the mount directory (only the
last component) and then mounts; a path outside the profile's list fails the
mount with EPERM (`hdi_mount [1: Operation not permitted]`), and the empty
directory stays. Decoded from the iOS 18.6 (22G86) vresearch101 kernelcache's
profile (filter numbering from macOS 26.5's libsandbox, consistent with every
node decoded), cryptexd may mount, when the system attribute private-cloud-os
is set, at:

| Path | Subpaths |
| --- | --- |
| `/private/var/PrivateCloudSupportInternalAdditions` | yes |
| `/private/var/DarwinDataCenterSupportImage` | yes |
| `/private/var/PrivateCloudSupport` | no |
| `/private/var/MLModels/LLM` | yes (the directory does not exist in the guest) |

plus its default `/private/var/run/com.apple.security.cryptexd/mnt/…` (storage
entitlement), and further paths for darwin-os and for Apple-signed programs in
general. The 26.5 kernelcache's profile names `/private/var/CipherMLAssets` and
`/private/var/PCCApps` as well (strings only, not decoded). The first four are
the `RequiredMountPath`s of PCC's own cryptexes in a VRE instance (research
additions, Debug Shell, PrivateCloud Support, the language model); all of those
are Cryptex1 Type 3, SubType 1, nonce domain 3 like the ones built here, and a
VRE installs several at once.

Tested on Blackberry, iOS 18.6 (22G86) with cloudOS 18.6, 2026-11-11:

| Mount point | Result |
| --- | --- |
| `/private/var/PrivateCloudSupportInternalAdditions` | mounted |
| `/private/var/DarwinDataCenterSupportImage` | mounted, beside the first |
| `/private/var/PrivateCloudSupport` | mounted, beside both |
| `/private/var/DarwinDataCenterSupportImage/<id>`, twice | both mounted, nothing at the parent |
| the same, again after an uninstall (directory left behind) | mounted |
| `/private/var/MLModels/LLM/<id>` | `_mkdir [2: No such file or directory]` |
| `/private/var/com.example.multi-b` | `hdi_mount [1: Operation not permitted]`, also alone |
| a path holding another cryptex | `_mkdir [17: File exists]` |

Each was personalized by Apple's TSS separately: several cryptexes in one nonce
domain are no limit. The PCC directories under `/private/var` there were made
by cryptexd for the first three tests: a fresh guest has none of them.

On cryptex9, iOS 26.5 (23F77) with cloudOS 26.5 (23F75), fresh:
`/private/var/DarwinDataCenterSupportImage` did not exist; after `files.mkdir`
of it, two cryptexes at `…/DarwinDataCenterSupportImage/<id>` mounted at once
and read back. (cryptex6 and cryptex8 had mounted at
`/private/var/PrivateCloudSupportInternalAdditions`, which cryptexd created.)

A launch daemon runs from a cryptex: on cryptex9, the SRD barebones-cryptex
example's `build/com.example.barebones.root` (`usr/bin/server`, ad hoc signed, and
`Library/LaunchDaemons/server.plist`), installed with Install Cryptex…, started
and answered on port 7070.

Install Cryptex… creates `/private/var/DarwinDataCenterSupportImage` and mounts
each cryptex at `/private/var/DarwinDataCenterSupportImage/<identifier>`: no
limit on their number, and a path that names the cryptex.

The VM window (Apps › Install Cryptex…) builds it from a chosen folder, or takes
a `.cxbd`, uploads the tree to `/var/mobile/Documents/vphone-cryptexes/<uuid>/`
and calls vphoned's `cryptex.install`, which runs

```
cryptexctl personalize --variant <v> --replace --host-identity --output-directory <name>.personalized <bundle>
cryptexctl install --variant <v> --print-info <name>.personalized/<bundle>
```

Personalization asks Apple's signing server for this guest's ticket, so the guest
needs network. `cryptex.list` and `cryptex.uninstall` are `cryptexctl list` and
`uninstall`. The capability `cryptex` is the presence of `/usr/bin/cryptexctl`;
see `Research/vphoned_http_api.md`.

## Validation

iPhone17,3 26.5 (23F77) / cloudOS 26.5 (23F75), `minimal` with
`--allow filesystem-exp-trusted_darwinos`, Launchpad `vm create --no-template`
(2026-11-10):

| Step | Result |
| --- | --- |
| `fw prepare` | cryptexctl staged (the first try lost the WKMS key fetch; `VPhoneAEA` retries now; the 403 fallback is validated below) |
| `fw patch` | `/usr/bin/cryptexctl` added; `Restricted Execution Mode: all 3730 entries allowed in both phases (3548 duplicates dropped)` |
| restore | `Requesting Ap,OSEnvironment = 6`; TSS signed it; `restore completed (1), requesting reboot [SUCCESS]` |
| boot | `AMFI: Developer Mode can not be enabled on trusted darwinOS.` (AMFI prints it only for environment 6), no launchd kill; first boot and vphoned passed |
| `developer_mode.status` | `enabled: false`, as the release AMFI of the research-board mix predicts |
| `cryptex.list` | empty, exit 0 |
| `cryptex.install` of a `.cxbd` from `cryptexctl.research create` (one shell script) | personalized by Apple's TSS (`<name>.personalized/<name>.cxbd.signed`), installed: `device = /dev/disk4s1`, `mount point = /private/var/PrivateCloudSupportInternalAdditions` |
| `files.read` of the cryptex's `bin/hello` at the mount point | the script's bytes |

Not checked yet: running a Mach-O from a cryptex (vphoned's `processes.spawn`
runs only `ps`, `launchctl` and `log`), the VM
window's Install Cryptex…, and a cloudOS with vphone600 components (research
AMFI, so Developer Mode should be on).

With the WKMS key refused (`cryptex7`/`cryptex8`, 2026-11-11, bundle
2.16.0-local.29436a31):

| Step | Result |
| --- | --- |
| `fw prepare`, no cache | key 403, then `[*] Restoring cloudOS in a temporary vphone VM to take its cryptexctl...` and `[+] cryptexctl staged from cloudOS restored by vphone-cli`; SHA-256 identical to the binary `ipsw fw aea` extracts from the decrypted image |
| `fw prepare`, next machine | `[+] cryptexctl reused from cloudOS 26.5 (23F75) cache` |
| runtime | 13 minutes awake with network on one boot session, no NRDUpdated process, no `TXM [Panic]`; two cryptexes personalized, installed and uninstalled |
| `cryptex.uninstall` | cryptexctl exits 1 without output after an uninstall that worked; the RPC takes `cryptexctl list` as the result |


## iOS 27 does not boot (2026-11-12)

iPhone17,3 iOS 27.0.1 (24A446) with cloudOS 26.4 (23E5207q), `minimal` with
the box on, bundle 2.16.1-local.f9155a25: the restore succeeded
(`Requesting Ap,OSEnvironment = 6`, cryptexctl staged through the temporary
cloudOS restore), and the first boot panicked before launchd ran:

```
libignition: 1:   os environment      : trusted-darwinos
libignition: 1: cryptex1 sniff: ignition failed: 8
dyld[1]: result from check_np(): -1, errno 12
dyld[1]: dyld cache '(null)' not loaded: syscall to map cache into shared region failed
panic(…):  initproc failed to start -- exit reason namespace 6 subcode 0x1 description: Library not loaded: /usr/lib/libSystem.B.dylib
```

The same build with iOS 26.5 (23F77) / cloudOS 26.5 (23F75) restored, booted
and answered `cryptex.list` (no panic in about 25 minutes). So iOS 27's dyld
cannot mount the OS cryptex in environment 6. Until that is understood,
`FirmwareRestoreImagePatchSet.trustedDarwinOSRefusal` refuses the patch for
iOS 27 and later: `fw prepare` stops right after resolving the IPSWs, and
the patcher stops before adding cryptexctl if the box was turned on after
`fw prepare`.
