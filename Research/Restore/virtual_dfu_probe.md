# P2.0 — can libirecovery see the VM's virtual DFU endpoint?

> 2026-09-23, branch `vphone-intg-update`. **Answer: yes.**
>
> Plan section P2.0 marks this the largest unknown in P2 and says to stop and
> re-evaluate if it fails, rather than vendoring idevicerestore on an assumption.

> **Since answered and acted on.** The migration this spike unblocked is done:
> the restore path is `Sources/VPhoneRestore` over vendored libirecovery and
> idevicerestore, and `scripts/pymobiledevice3_bridge.py` no longer exists.
> Everything below is written as of the day of the spike, when it still did.
> `Research/Restore/native_restore_architecture.md` has what P2 went on to do.

## Why it was a real question

The restore path at the time went through pymobiledevice3's `IRecv`, which is
**pyusb**. libirecovery on macOS goes through **IOKit USB**. Different transport,
so whether one works tells you nothing about the other, and the whole of
P2.1/P2.2 is wasted work if the IOKit path cannot see a Virtualization.framework
virtual endpoint.

## Result

VM booted with `--dfu` from a bare bundle — `vphone-cli vm new` output only, no
restore, no firmware, no CFW:

```
libirecovery DFU probe
  target ecid : 206C763772858301
  attempts    : 10
  RESULT      : FOUND
    ecid      : 206C763772858301
    cpid      : 0xfe01
    bdid      : 0x90
    cprv/cpfm : 0x0 / 0x3
    srtg      : mBoot-20457.1.29
    serial    : SDOM:01 CPID:FE01 CPRV:00 CPFM:03 SCEP:01 BDID:90
                ECID:206C763772858301 IBFL:3C SRTG:[mBoot-20457.1.29]
    ap nonce  : 32 bytes
    sep nonce : 20 bytes
```

`irecv_open_with_ecid_and_attempts` succeeds and `irecv_get_device_info` returns a
fully populated struct. **The ECID matches exactly** what `vphone-vm` derived from
`machineIdentifier` (`VPhoneVirtualMachine.swift:296-309`), which also confirms that
derivation independently — two different code paths agreeing on
`206C763772858301`.

AP and SEP nonces are present and correctly sized, so personalisation has what it
needs.

## What this also established

Getting here required the entitlement split to work end to end under a hostile
amfid, so it settled two queue items at once:

- `vphone-vm` **can start a VM holding the private entitlements alone**. This was
  the item everything in step 1 rested on, and it was unproven until now. This
  one is about the entitlements, not the bypass, and it still stands.
- A bypass that covers only the exec is enough: the VM was running and healthy
  after the window closed, and `--detach` left the guest running after the patch
  was removed (`detached; pid 33232 keeps running`).

Also proven in passing: with amfid refusing, `vphone-cli --help` still runs and
prints the full explanatory error rather than a bare `Killed: 9`. That is the
entire point of moving the entitlements off the entry point.

> **The bypass used for this run is gone.** The two window measurements above
> were taken with `vphone-letmein exec --hold 10 [--detach]`, which opened its
> window by writing amfid's `__TEXT`. That is fatal on a host where
> `vm.cs_system_enforcement` reads 1 — the kernel kills amfid for the dirty page
> — so the tool was removed the same day. The spike's own findings do not depend
> on it: what was shown is that a bypass lasting one exec suffices, not that any
> particular tool provides it. `Research/Host/host_binary_split.md` has the
> measurement. The replacement is `amfidont`, below.

## Reproducing it

The spike is ~60 lines of Swift against the system libirecovery. Note the link name
is **`-lirecovery-1.0`**, not `-lirecovery` — Homebrew ships
`libirecovery-1.0.dylib` with no unversioned symlink. That detail carries into P2.1.

```
swiftc -O -import-objc-header bridge.h main.swift \
  -Xcc -I/opt/homebrew/include -L/opt/homebrew/lib -lirecovery-1.0 -o dfu_spike
./dfu_spike <ecid-hex> <attempts>
```

Boot the VM first, leaving it running. On a host with AMFI relaxed at boot,
that is just:

```
.../vphone-vm --config ~/.vphone/machines/<name>/config.plist --dfu
```

Where amfid still refuses it, allow that one binary first — in another terminal,
and leave it running:

```
sudo amfidont daemon \
  --cdhash "$(codesign -dv --verbose=4 .../vphone-vm 2>&1 | sed -n 's/^CDHash=//p' | head -1)" \
  --spoof-apple --verbose
```

With no VM up, the probe exits 1 with `Unable to connect to device (-3)` — so a
negative result is distinguishable from a broken harness.

## Still open, and deliberately not answered here

Plan section P2.2 asks that **FDR equivalence** be confirmed as part of this spike.
It was not, and cannot be from device enumeration alone: pymobiledevice3 ran
`Restore(..., ignore_fdr=False)`, and idevicerestore's FDR handling is internal.
Whether the two behave the same only shows up during an actual restore. That stays
an open risk on P2.2 and must not be assumed away — it is called out here so the
next person does not read "P2.0 passed" as covering it. It is still open;
`Research/Restore/native_restore_architecture.md` carries it forward.
