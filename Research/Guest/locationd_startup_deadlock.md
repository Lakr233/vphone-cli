# locationd startup deadlock (iOS 27.0)

On an iOS 27.0 guest, locationd can deadlock about a second after it starts.
Every CoreLocation client then blocks on `com.apple.locationd.synchronous` for
good: vphoned's `location.current` and `location.set` time out after 120 s
("The machine closed the connection without answering"), and Maps, navd,
nearbyd, PerfPowerServices, usernotificationsd and the rest sit on the same
port. vphoned now restarts such a locationd (`GuestLocationdWatchdog`).

Measured on 2026-10-07 on a new `standard` VM: iPhone17,3, iOS 27.0 (24A435),
cloudOS 26.4 (23E5207q) kernel, 8 vCPUs, 8 GiB, Location Services off, no
location RPC sent, Sync Host Location off.

## It is not a headless problem

It was first seen on headless starts (`vphone-launchpad-cli vm start <vm>
--headless`) while windowed starts of the same VM worked. Boots of the
unmodified guest (upstream vphoned, no watchdog) show that both kinds hang:

| Start | Boots | locationd hung |
| --- | --- | --- |
| headless | 15 | 6 |
| windowed | 5 | 1 |

A boot counts as hung when `location.current` did not answer within 15 s at
about 60 s of uptime (a healthy locationd answers at once, here with
`location_services_off`). locationd's own CPU time tells the two apart as
well: about 0.15–0.22 s for a hung instance, 0.4–1.1 s for a healthy one. One
headless boot that streamed locationd's log from the moment vphoned answered
did not hang, possibly because logging slows locationd down.

Nothing in `VPhoneVirtualMachineAppDelegate`'s headless branch reaches
locationd: the headless `onConnect` sends the same `time.timezone` and
`audio.host_latency` calls as the windowed one and only skips the menu's
battery and Low Power Mode sync. The deadlock also forms before most of
those calls arrive.

## The wait cycle

From a guest spindump (`/usr/sbin/spindump -notarget 3 10`, run as a launchd
job through vphoned; see the guest-profiling procedure). locationd is not in
the shared cache: pull `/usr/libexec/locationd` out of the IPSW
(`ipsw extract --files --pattern 'usr/libexec/locationd$'`), take
`0x100000000 + <offset>` and read the ObjC name with
`ipsw macho disass <locationd> --vaddr <function start> --count 1`
(`ipsw macho a2s` returns only `func_…`). Shared cache frames resolve with
`ipsw dyld a2s` (slide 0 on this boot).

| Thread (queue) | Doing | Waits on |
| --- | --- | --- |
| main | CFRunLoop source `CLLocationController::sendTechStatusNotification` → `[silo sync:]` | `CLLocationControllerSilo` (turnstile on its thread) |
| `CLLocationControllerSilo` | `-[CLLocationControllerAdapter beginService]` → `dispatch_once` → the controller's constructor (`sub_1007428b8`) → `+[CLSimulatedLocationProviderAdapter performSyncOnSilo:invoker:]` | thread event: the main-queue hierarchy |
| `CLClientManagerSilo` | `beginService` → `dispatch_once` → LocationAuthorizationFramework `iterateAllAnchorKeyPathsWithBlock:` → `+[CLCapabilityMonitor performSyncOnSilo:invoker:]` | "queue in a transient state" |
| `CLNetworkLocationProviderSilo`, `CLWifiTilesManagerSilo` | `beginService` → `+[CLDataProtectionManagerAdapter performSyncOnSilo:invoker:]` | transient / thread event |
| `CLCountryTrackerSilo`, `CLGeoIPCountryTrackerSilo` | `beginService` → `initInUniverse:` → `performSyncOnSilo:invoker:` | thread event / transient |
| `CLInternalServiceSilo` | XPC `getAuthorizationStatusForBundleID:orBundlePath:replyBlock:` → `+[CLClientManagerAdapter performSyncOnSilo:invoker:]` | `CLClientManagerSilo` |

LocationSupport groups silos into cohorts, layers of the sync graph read from
`CoreLocation.framework/Support/syncget_graph_iOS.plist` (logged as
`#Cohorting CohortId assignment for silo`). A silo may `sync:` only into a
lower layer. Everything above waits on cohort 0
(`CLSimulatedLocationProviderSilo`, `CLCapabilityMonitorSilo`,
`CLDataProtectionManagerSilo`, `CLDaemonStatusSilo`, …), the waits into it are
thread-event waits (the main queue's hierarchy has no workloop), and no thread
is draining it. The main thread itself sits at the top, inside a run-loop
callback that synced into cohort 6.

The tech-status source is created by the controller's constructor itself
(`CFRunLoopSourceCreate` with `sendTechStatusNotification` as `perform`, added
to the main run loop in common modes, next to a second source for
`checkActiveProviders`). `CLLocationController::signalTechStatusChanged`
(`sub_10006f794`) signals both sources and wakes the main run loop. Its callers
include `CLLocationController::startLocation` and the GPS, Wi-Fi and indoor
"active state" notifications. When it fires while the constructor is still
running, and the main thread is idle, the main thread enters the callback,
blocks on the controller's silo, and the constructor's next `sync:` into
cohort 0 can never run. In a healthy start `#techstatus,posting notification`
comes after `#Manufacturing service complete … CLLocationController`.

## A patch was tried and is not enough

Both callbacks only capture the controller pointer, and nothing after the
`sync:` uses the block's result, so delivering them with `async:` is safe. A
prototype retargeted the two `bl objc_msgSend$sync:` (24A435:
`0x100074d68`, `0x100077e98`) to the existing `objc_msgSend$async:` stub
(`0x101b23800`) and re-hashed the two code pages. With it the first boot hung
again, through a third path: the main thread was draining the main queue in a
silo timer (`shouldFire`, `sub_1004217ac`) that syncs into
`+[CLDaemonStatusAdapter performSyncOnSilo:invoker:]` while
`CLClientManagerSilo` waits on the same silo. Each main-thread entry point
would need its own patch, and the set is not known, so no patch was added.

The prototype went in through a host mount of the stopped VM's system volume
as the invoking user (`hdiutil attach -nomount`, `mount_apfs -o
rw,nosuid,nodev,nobrowse,noowners`, overwrite in place) and was reverted the
same way; the original binary was restored byte for byte.

## Restarts and a second race

A locationd that launchd starts again does not always come up either. Killed
every ~40 s on a running guest with `processes.kill … "signal":"TERM"`, five
of seven new instances hung. (`processes.kill` takes a signal *name*; a
numeric `"signal":9` falls back to TERM.) The same guest also logged
locationd crash reports with `EXC_ARM_PAC_FAIL` 0.13 s after launch, the
faulting thread draining a `Cohort:8` queue and calling a block whose invoke
pointer was garbage: a second startup race, in the unmodified binary.

Why the guest hits these so often is open. The guest runs an iOS 27 userland
on the cloudOS 26.4 kernel (xnu 25.4), and both failures sit in libdispatch
workloop and `dispatch_sync` paths. Nothing here tests that; it is the
difference from a real iPhone most likely to matter.

## Workaround: vphoned restarts it

`VPhoneDaemon/Daemon/GuestLocationdWatchdog.swift`, started from `main.swift`:

- calls `CLLocationManager.locationServicesEnabled()`, the cheapest
  synchronous request locationd serves, every 15 s for the first five minutes
  and every 60 s after;
- when no answer comes within 10 s, sends SIGKILL to `/usr/libexec/locationd`
  (a deadlocked one never finishes its SIGTERM handler), waits for the stuck
  request to return, and asks again after one second, which has launchd start
  a new locationd;
- stops after 20 restarts in one vphoned lifetime and logs every action as
  `vphoned: locationd watchdog: …`.

Requests that were waiting on the dead locationd fail instead of blocking.

A locationd stuck in its baseband client instead (seen once on an iOS 27.2
iPhone Duo) still answers that request, so the watchdog does not see it; see
`iphone_duo_bringup.md`, "iOS 27.2, and WebDriverAgent's hinge GET after
boot".

### Verification

Same VM, alternating between a bundle with the watchdog and one without
(upstream 2.7.0), each bound with `vm set-bundle --update-environment`. A boot
is probed with `location.current` at 65–75 s of uptime; a relaunch is a
`processes.kill … "signal":"KILL"` of the running locationd, probed 10 s after
launchd starts the next one.

| vphoned | Boots with a working locationd | Relaunches with a working locationd |
| --- | --- | --- |
| without the watchdog | 3 of 5 | 3 of 6 |
| with the watchdog | 14 of 14 | 6 of 6 |

The watchdog's lines are in `/var/log/vphoned.log`, vphoned's stdout and
stderr; `logs.syslog` does not return them. Over those runs it killed a hung
locationd six times, once twice in a row because the first new instance hung
as well. launchd's count of locationd launches (`services.print
com.apple.locationd`, `runs =`) stayed at 3–4 on boots it did not act on.

