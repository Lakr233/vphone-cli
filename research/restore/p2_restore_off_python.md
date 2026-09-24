# P2 — taking restore off Python

> 2026-09-23, branch `vphone-intg-update`. Plan sections P2.0 → P2.4.
>
> `scripts/pymobiledevice3_bridge.py` was the last Python program in this
> repository. It is gone, and with it `requirements.txt`, `scripts/setup_venv.sh`,
> `scripts/setup_venv_linux.sh`, the `make setup_venv` target and the
> provisioning blocks in `setup_tools.sh` and `setup_machine.sh`. D1 — zero
> Python — is met.
>
> What replaced it: `sources/VPhoneRestore` (1,040 lines of Swift) over two
> vendored C targets, `MobileRecoveryCore` (libirecovery) and
> `MobileRestoreCore` (idevicerestore), with everything else arriving as
> prebuilt xcframeworks.

## The decision: a package, not a vendoring

The plan's §P2.1 reads as though the whole libimobiledevice stack had to be
carried in tree. Measured against the upstream tarballs, that is what it would
have cost:

| upstream | `.c` + `.h` lines |
| --- | ---: |
| libimobiledevice 1.4.0 | 48,484 |
| libplist 2.7.0 | 13,390 |
| libimobiledevice-glue 1.3.2 | 6,204 |
| libusbmuxd 2.1.1 | 3,045 |
| libtatsu 1.0.5 | 2,070 |
| **total** | **73,193** |

None of that is code this project would ever read or change. Carrying it would
have meant five more hand-written `config.h` files standing in for
`./configure`, OpenSSL on top, and every upstream security fix arriving as a
manual merge into a tree nobody here is qualified to review. Linking Homebrew's
copies instead was never available: `make check-aux` gate 1 fails on any
absolute path in the dependency closure, and `/opt/homebrew/lib/libimobiledevice-1.0.dylib`
is exactly that.

`Lakr233/AppleMobileDeviceLibrary` already ships all five of those, plus
OpenSSL, as prebuilt static xcframeworks, and it was already a dependency of
this package. A plain SwiftPM C target depending on the `AppleMobileDeviceLibrary`
product can `#include <plist/plist.h>`, `<libimobiledevice/libimobiledevice.h>`,
`<libimobiledevice/restore.h>`, `<libimobiledevice-glue/collection.h>`,
`<usbmuxd.h>`, `<libtatsu/tss.h>` and `<openssl/ssl.h>` and link them — so the
73,193 lines are a `.package(url:)` line and nothing else in the tree.

## What still had to be vendored, and why

Two things are not in that package, and both are load-bearing.

### `sources/MobileRecoveryCore` — libirecovery 1.3.1

4,629 lines. It talks to iBoot and iBSS over USB, which is the half of a restore
`idevicerestore` does not get from libimobiledevice. Upstream ships it as an
autotools project, so the only file here that is not upstream's own bytes is
`config.h`, which says what `./configure` concludes on macOS.

**The backend is IOKit, not libusb.** On a host whose SDK has
`IOKit/usb/IOUSBLib.h`, upstream's `configure.ac` picks IOKit and never looks
for libusb; that is deliberate here too, because a libusb backend would put a
Homebrew dylib in the link and gate 1 rejects it. It is also what
`research/restore/p2_dfu_spike.md` proved works — see below.

### `sources/MobileRestoreCore` — idevicerestore

20,918 lines, of which **1,399 are ours** and each of those files says so at the
top:

| file | lines | what it is |
| --- | ---: | --- |
| `vphone_restore_bridge.c` | 703 | the library entry point upstream's `main()` was |
| `vphone_zip_stub.c` | 260 | libzip's twenty-two entry points, each failing loudly |
| `include/vphone_restore_bridge.h` | 166 | the target's only public header |
| `zip.h` | 143 | libzip's signatures, so upstream's `.c` compiles unchanged |
| `config.h` | 127 | what `./configure` would have written |

Upstream is a program, not a library. It is compiled here with
`IDEVICERESTORE_NOMAIN`, so its `argv` parsing, usage text and signal handling
are excluded, and `vphone_restore_run()` builds the same client object from a
struct instead of from a command line. One restore per process:
idevicerestore keeps its mode, log level and quit flag in process globals, so a
second concurrent call is refused with `VPHONE_RESTORE_E_BUSY` rather than
allowed to fight the first over them.

**The libzip stub is the one real amputation.** libzip is the single
`PKG_CHECK_MODULES` dependency in `configure.ac` with no counterpart here, and
linking Homebrew's copy fails gate 1. Exactly two things are lost, and `zip.h`'s
header carries the full argument:

1. Reading an IPSW straight out of the `.ipsw` zip. `src/ipsw.c` chooses once in
   `ipsw_open()` between a stdio path for a directory and a libzip path for a
   file. This project always hands idevicerestore an already-extracted
   `iPhone*_Restore` directory, and `vphone_restore_run()` refuses anything else
   before idevicerestore sees it — so the zip arm is unreachable by
   construction. `RestoreRunnerTests.aFileIsNotARestoreDirectory` pins that: a
   `.ipsw` is rejected by name rather than failing four layers down.
2. Baseband firmware signing. `restore_sign_bbfw()` stitches signature blobs
   into a `.bbfw`'s members. A virtual iPhone has no baseband, so the restore
   never reaches it. On real hardware with one it would, and it would fail
   loudly instead of flashing something unsigned — which is the right failure.

Both end at `zip_open()` returning NULL after logging what happened and why,
which upstream already handles as an ordinary error. Nothing in the stub returns
a plausible-looking success.

### What the two targets link

`IOKit` and `CoreFoundation` for libirecovery; `/usr/lib/libcurl.4.dylib` for
the TSS request and the firmware download, and `/usr/lib/libz.1.dylib` for the
gzipped `.shsh` and the compressed BuildManifest members. All four are on
`check_aux.sh`'s system whitelist, which is why gate 1 stays green with the
restore backend in the bundle.

## The Swift layer

`sources/VPhoneRestore` is what actually replaces the bridge script. The Python
had four commands; three are ported with the same arguments, the same errors and
the same two lines of output that scripts and people have been grepping for
(`[+] SHSH saved: …`, `[+] Using cached SHSH: …`).

| Python command | now | note |
| --- | --- | --- |
| `recovery-probe` | `VPhoneRecoveryProbe.probe` | `irecv_open_with_ecid_and_attempts` + timeout polling |
| `restore-get-shsh` | `VPhoneRestoreService.fetchSHSH` | erase ticket, as Python's did |
| `restore-update` | `VPhoneRestoreService.restore` | `erase` defaults true; `ticketPath` for `--offline` |
| `usbmux-list` | **not ported** | no call site anywhere in this repository |

Two things the Swift has to undo, because idevicerestore and the Python bridge
did not agree on either:

- **`-t/--shsh` writes a gzipped binary plist**; the `.shsh` this project has
  always written beside a VM is a plain one. `VPhoneRestoreTicket` reads all
  three shapes that now exist in the wild — idevicerestore's gzipped binary
  plist, the plain XML the Python wrote, and a bare binary plist — and writes
  the bytes out as-is rather than re-serializing, so an XML file stays XML.
- **`-t/--shsh` names the file after the device's decimal ECID** and skips the
  write entirely when a file of that name is already present
  (`"SHSH '%s' already present."`). `fetchSHSH` therefore points it at a fresh
  temporary cache directory per call, so "the `.shsh` idevicerestore just wrote"
  is unambiguous and a stale blob from a previous firmware can never be the one
  copied out.

## The P2.3 behaviour table

The plan's seven rows, each with what it is checked by today. **`unit`** means
`tests/VPhoneRestoreTests` covers it with no device attached; **`device`** means
it is not checked and needs a phone or VM in DFU.

| # | scenario | before | after | criterion | state |
| --: | --- | --- | --- | --- | --- |
| 1 | `restore` (online, default) | `pmd3 restore-update` | `erase=true, ticket_path=NULL` | VM boots | **device**, but both halves are now proven separately: the online TSS fetch by row 2 and the erase-and-flash by row 3. What has not been run is the two in one invocation. Options mapping is `unit`: `RestoreOptionsTests.defaultsAreAnOnlineEraseRestore` |
| 2 | `restore --get-shsh` | `pmd3 restore-get-shsh` | `shsh_only=true` | `.shsh` semantically equal to the Python's, same filename | ✅ **DONE 2026-09-23.** Real TSS round trip against a DFU-booted `dfu-spike`: ApNonce and SepNonce read from the device, `Received SHSH blobs`, saved as `206C763772858301.shsh` — the `%016X` name `VPhoneRestoreLayout.shshOutput` promises. The blob is a TSS response (`@ServerVersion 2.1.0`, 5,803-byte `ApImg4Ticket`), binary plist where the Python wrote XML — a serialization difference, not a semantic one |
| 3 | `restore --offline` | AEA decrypt in place → `--tss <first .shsh>` | AEA decrypt in place → `ticket_path=<same file>` | ① `noSHSH` with no blob ② `noRestoreDir` with no tree ③ multiple `.shsh` → sorted first ④ VM boots | ✅ **DONE 2026-09-23.** ①②③ `unit` and also run through the CLI (see below); ④ a full flash of `dfu-spike` from the 26.1/23B85 tree with the cached ticket: four `.dmg.aea` decrypted in place, filesystem sent, system volume sealed, `Status: Restore Finished`, exit 0, and the device left DFU |
| 4 | `restore --no-erase` | `Behavior.Update` | `erase=false` | user data survives | **device.** The flag did not exist until 2026-09-23 — see below. Mapping is `unit`: `RestoreOptionsTests.updateInPlaceClearsErase` |
| 5 | metadata on success | writes `restore-info.json` | same | contents identical | ✅ **DONE 2026-09-23.** Written only after the restore returned: `{"ios":{"version":"26.1","build":"23B85"},"cloudOS":{"version":"26.1","build":"23B85"}}` |
| 6 | failure | no `restore-info.json`, exit code passed through | same | exit codes match | **device.** The bridge's own rejections are `unit` (`RestoreRunnerTests`); a failure from inside idevicerestore is not |
| 7 | verbosity | `-v` → one, `-vv`/`-vvv` → two `-v` | `debug_level` | logs comparably detailed | **device.** The level enum matches upstream's one for one and that is `unit` (`RestoreEventTests.levelsMatchIdevicerestoresEnum`) |

### What the first pass over this table actually turned up

The unit suite had **not been executed during the documentation pass** that wrote
this file, and the note here asked whoever landed P2 to run it rather than
inherit the claim. Run on 2026-09-23:
`swift test --filter VPhoneRestoreTests` → **67 tests in 6 suites, all passing.**

Reading the table against the shipped CLI, rather than against the library,
found three things the unit tests could not have caught — every one of them a
gap between `VPhoneRestore` and `vphone-cli`, not inside either:

- **Row 4 was not "needs a device", it was unreachable.** The Python had
  `--erase/--no-erase`; the port kept `VPhoneRestoreOptions.erase` and
  `RestoreOptionsTests.updateInPlaceClearsErase`, but no flag was ever added to
  `VPhoneRestoreCommand`, which passed a literal `erase: true`. The flag exists
  now, so the row is a device check like the rest.
- **Row 3's `--offline` path bypassed its own guard, destructively.** The CLI
  globbed `iPhone*_Restore` itself, sorted, and took the first — Python's rule,
  the one "Deliberate divergences" below says was replaced — then decrypted that
  tree's AEA images **in place** before `VPhoneRestoreService` got a chance to
  refuse two trees. With two firmware trees in a bundle it irreversibly
  decrypted one nobody chose and *then* aborted. It now calls
  `VPhoneRestoreLayout.findRestoreDirectory` like every other caller, so the
  refusal comes first. Verified end to end: two trees → exit 1, zero bytes
  written into either.
- **`VPhoneRestoreError` printed case names.** A missing blob said
  `Error: noSHSH` beside sibling failures from `VPhoneRestoreBackendError` that
  have read as sentences all along. It conforms to `LocalizedError` now.
  `noRestoreDir` went with it: the `--offline` glob was its only thrower.

Criteria ① and ② of row 3 were then exercised through the built binary against a
synthetic bundle, not only through the library.

### And then the device rows were run — after one more thing had to be fixed

`make amfi_allow` made `vphone-vm` launchable on the dev host for the first time,
so `dfu-spike` could be booted `--dfu` and the device rows actually attempted.
`vphone-cli recovery-probe` found it immediately — ECID `0x206C763772858301`,
matching what `vphone-vm` derived from `machineIdentifier`, two independent code
paths agreeing. A wrong `--ecid` times out rather than matching the attached
device, so `irecv_open_with_ecid_and_attempts` is filtering and not just taking
whatever answers.

Then `--get-shsh` stopped at **`Unable to discover device type`**.

That is `get_irecv_device` returning NULL, from `irecv_devices_get_device_by_client`
failing to match `{cpid 0xFE01, bdid 0x90}` — the PCC research environment — in
libirecovery's `irecv_devices[]`. The table is `static`, so nothing outside the
file can extend it, and **vendoring release 1.3.1 was the mistake**: upstream
`master` already carries

```c
/* Private Cloud Compute Research Environment */
{ "iPhone99,11", "vresearch101ap", 0x90, 0xFE01, "iPhone 99,11" },
```

This is the deeper half of P2's Python-to-idevicerestore swap, and worth stating
plainly: pymobiledevice3 never needed a device table. It matched the connected
device's CPID/BDID against the BuildManifest's own `BuildIdentities`, so a
device Apple had not shipped was not a special case. idevicerestore selects the
build identity through `client->device->product_type`, so an unlisted device is
not merely unidentified — it is unrestorable. Vendoring `master` rather than the
newest tag is therefore load-bearing here, not housekeeping; `config.h`'s header
says so at the vendoring site.

With that in, the same probe reports `iPhone99,11 in DFU`, idevicerestore
reports `Identified device as vresearch101ap, iPhone99,11`, and rows 2, 3 and 5
pass as recorded above.

The rows still open are **1** (only as a single invocation — see its cell),
**4** (the flag is new), **6** and the tail of **7**. **Run them on a disposable
VM** — a failed restore leaves the guest sitting in recovery.

### `research/restore/p2_dfu_spike.md` already settled the riskiest question

P2.0 asked whether libirecovery's IOKit path can see a Virtualization.framework
virtual DFU endpoint at all — pymobiledevice3 reached it through pyusb, so one
working said nothing about the other, and the plan says to stop and re-evaluate
rather than vendor idevicerestore on an assumption. The answer is yes:
`irecv_open_with_ecid_and_attempts` succeeded against a VM booted `--dfu` from a
bare bundle, `irecv_get_device_info` returned a fully populated struct, and the
ECID matched what `vphone-vm` derived from `machineIdentifier` — two independent
code paths agreeing on `206C763772858301`. AP and SEP nonces were present and
correctly sized, so personalization has what it needs.

## Deliberate divergences from the Python

Recorded because a behaviour comparison that only lists matches is not a
comparison.

- **Two restore trees in one bundle is now an error.** Python's
  `find_restore_dir` globbed `iPhone*_Restore` and took whichever sorted first;
  `VPhoneRestoreLayout.findRestoreDirectory` throws
  `multipleRestoreDirectories` naming both. Restoring from whichever build
  happened to sort first flashes a build nobody chose. The single-tree and
  no-tree cases are unchanged, including that a symlink to a directory still
  counts (`fileExists(atPath:isDirectory:)`, matching Python's `p.is_dir()`;
  `URLResourceValues.isDirectory` would answer for the link and was wrong).
- **`ticket_path` is not upstream's `-T/--ticket`.** The plan's P2.2 says to map
  it there. `-T` takes a bare `ApImg4Ticket`; this takes the **whole TSS
  response**, which is what `shsh_only` writes and what pymobiledevice3's
  `fetch_tss_record()` dumped. A full response carries a signature per
  component and a bare ticket does not, so personalizing with a bare one
  produces components the device rejects.
- **A `.ipsw` handed to `restore_dir` is rejected by name.** Upstream would have
  opened it through libzip; this build has no libzip, so the check moved to the
  front where the error is legible.

## Still open

**FDR equivalence.** The Python ran `Restore(..., ignore_fdr=False)`;
idevicerestore's FDR handling is internal. `research/restore/p2_dfu_spike.md` says
explicitly that this could not be settled from device enumeration and was not,
and it stays an open risk on P2.2. It shows up only during an actual restore.
Do not read "P2.0 passed" as covering it.

## The dependency graph P2 left behind

Moving the restore backend into the package is what finally emptied `vendor/`.

- **`vendor/` is gone.** Every one of the seven dependencies resolves by URL;
  `Package.resolved` pins fourteen once transitives are counted.
- **Submodules went from 9 to 3**: `scripts/resources`,
  `scripts/repos/trustcache`, `scripts/repos/insert_dylib`. The other six were
  SwiftPM checkouts this repository pinned by commit, which meant a
  `git submodule update` before any build and a tree that could sit at an
  unreleased commit — MachOKit was four commits past 0.46.1, Dynamic two past
  1.2.0.
- **MachOKit 0.46.1+4 → 0.52.2** and **swift-argument-parser 1.7.0+6 → 1.8.2**
  came with that move, with **zero source changes needed**.
- **`libcapstone-spm` is pinned `branch: "main"`, not `from:`** — a known wart.
  Its `CoreCapstone` target carries `.unsafeFlags(["-Wno-shorten-64-to-32"])`,
  and SwiftPM refuses unsafe flags in a dependency resolved by version while
  allowing them in one resolved by branch. A branch pin means `swift build`
  can pick up an upstream commit nobody here reviewed; `Package.resolved`
  records what was actually built, which limits the damage but does not remove
  it. **The fix is upstream**: drop the flag from `CoreCapstone` — the warning
  it suppresses is Capstone's own and can be silenced in the source or simply
  tolerated — cut a release, and change this line to `from:` like the other
  six.
