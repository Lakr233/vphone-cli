# P2.0 — can libirecovery see the VM's virtual DFU endpoint?

> 2026-09-23, branch `vphone-intg-update`. **Answer: yes.**
>
> Plan section P2.0 marks this the largest unknown in P2 and says to stop and
> re-evaluate if it fails, rather than vendoring idevicerestore on an assumption.

## Why it was a real question

The restore path today goes through pymobiledevice3's `IRecv`, which is **pyusb**.
libirecovery on macOS goes through **IOKit USB**. Different transport, so whether
one works tells you nothing about the other, and the whole of P2.1/P2.2 is wasted
work if the IOKit path cannot see a Virtualization.framework virtual endpoint.

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
amfid, so it settled three queue items at once:

- `vphone-vm` **can start a VM holding the private entitlements alone**. This was
  the item everything in step 1 rested on, and it was unproven until now.
- `vphone-letmein exec --hold 10` is enough to cover the launch: the VM was running
  and healthy after `amfid restored`.
- `--detach` works — the patch is removed after the hold and the guest keeps
  running (`detached; pid 33232 keeps running`).

Also proven in passing: with amfid refusing, `vphone-cli --help` still runs and
`VPHONE_LETMEIN=never` produces the full explanatory error rather than a `Killed: 9`.
That is the entire point of moving the entitlements off the entry point.

## Reproducing it

The spike is ~60 lines of Swift against the system libirecovery. Note the link name
is **`-lirecovery-1.0`**, not `-lirecovery` — Homebrew ships
`libirecovery-1.0.dylib` with no unversioned symlink. That detail carries into P2.1.

```
swiftc -O -import-objc-header bridge.h main.swift \
  -Xcc -I/opt/homebrew/include -L/opt/homebrew/lib -lirecovery-1.0 -o dfu_spike
./dfu_spike <ecid-hex> <attempts>
```

Boot the VM first, leaving it running:

```
sudo .../vphone-letmein exec --hold 10 --detach -- \
  .../vphone-vm --config ~/.vphone/VMs/<name>/config.plist --dfu
```

With no VM up, the probe exits 1 with `Unable to connect to device (-3)` — so a
negative result is distinguishable from a broken harness.

## Still open, and deliberately not answered here

Plan section P2.2 asks that **FDR equivalence** be confirmed as part of this spike.
It was not, and cannot be from device enumeration alone: pymobiledevice3 runs
`Restore(..., ignore_fdr=False)`, and idevicerestore's FDR handling is internal.
Whether the two behave the same only shows up during an actual restore. That stays
an open risk on P2.2 and must not be assumed away — it is called out here so the
next person does not read "P2.0 passed" as covering it.
