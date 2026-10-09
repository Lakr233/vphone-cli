# Trimming system services

vphoned's `trimmed` service profile turns off about 140 launchd jobs a
research VM has no use for: Siri and the intelligence daemons, Find My,
Wallet/NFC/Secure Element, Watch, Home, health coaching, Maps background
work, iCloud and iMessage sync, ads and recommendations, telemetry, accessory
firmware updates and OTA. On an iOS 27.0 guest that cuts process memory by
29%, idle host CPU by 26% and idle host writes by 60%; on iOS 26.6.2, with
the same list less what 26 does not load, by 30%, 39% and 94%. No vphone
feature was lost on either. The profile is applied once, in the setup boot
of a machine template, and every clone of the template inherits it.

`services.profile` and `services.profile.apply` are described in
[`vphoned_http_api.md`](../vphoned_http_api.md); the lists are in
`VPhoneDaemon/Daemon/GuestServiceProfile.swift`.

## How it works

The profile uses the override `launchctl disable` writes, which lives in
launchd's database on the data volume
(`/private/var/db/com.apple.xpc.launchd/disabled.plist`). launchd does not
load a disabled job at the next boot. It is the same mechanism
`services.disable` and the [OTA block](ota_software_update_block.md) use.

- **It takes a reboot.** `services.stop` and `services.unload` answer with
  launchd status 144 on the guest, so a running job keeps running until the
  guest restarts.
- **It is not a firmware patch.** The system volume and `launchd.plist` are
  untouched, nothing goes into a patch set, and the Services panel still lists
  every job, disabled ones marked as such.
- **It reverts cleanly.** vphoned records the labels it disabled in
  `/var/db/vphoned/service-profile.plist`. `profile: "none"` turns back on
  those labels and no others. A job that was already disabled when the profile
  ran, such as the OTA trio, is never recorded and stays disabled.
- **The host has to ask.** The host cannot write the data volume of a guest:
  it is encrypted with the guest's keys. So the profile is applied by vphoned
  from inside the guest.

## What `trimmed` disables

| Group | Default | Labels | Why they can go |
| --- | --- | --- | --- |
| `base` | on | 137 | Appendix A of the measurement below. Nothing in vphone, IcliKit or the guest hooks talks to them |
| `app_store` | on | `com.apple.appstored`, `com.apple.itunesstored` | Off with the App Store and iTunes Store apps a template removes. `appstorecomponentsd` is already in `base` |
| `signin_followup` | on | `com.apple.followupd`, `com.apple.appleidsetupd` | The sign-in follow-up and Apple Account setup prompts. They complement `libsigninfix`'s pane suppression. A guest that went through `setup.skip` has no follow-up items, so no orphaned badge is left |
| `accounts` | off, `groups: ["accounts"]` | `com.apple.akd`, `com.apple.amsaccountsd`, `com.apple.appleaccountd` | Only for guests that never sign in: with these off, the guest cannot sign in to an Apple Account |

The `base` group, by area:

| Area | Examples | Kind |
| --- | --- | --- |
| Siri and intelligence | assistantd, siriinferenced, intelligenceflowd, siriactionsd, modelmanagerd, corespeechd | Not used. siriactionsd also serves Shortcuts and App Intents, and corespeechd and modelmanagerd serve dictation |
| Photos and media analysis | mediaanalysisd, photoanalysisd, photosface | mediaanalysisd alone wrote 79 MiB in a 15-minute idle window |
| Ads, content and recommendations | amsengagementd, promotedcontentd, tipsd, weatherd, gamed | amsengagementd was the top idle CPU and write consumer |
| Find My | findmydeviced, searchpartyd, findmylocated, fmflocatord | No Apple Account |
| Wallet, NFC, Secure Element | passd, nfcd, seld, seserviced, coreidvd | No NFC or SE hardware |
| Watch | nanotimekitcompaniond, nanoprefsyncd, nanobackupd | No paired watch. nanoregistryd stays (see below) |
| Home and health | homed, homeeventsd, fitnesscoachingd, ThreadCommissionerService | HomeKit apps under test need `homed` |
| Maps background | routined, navd, destinationd, mapspushd, mapssyncd | Not the location simulation path |
| iCloud, iMessage, mail sync | identityservicesd, imagent, maild, remindd, replicatord, syncdefaultsd | No account. Mail, Reminders and iMessage under test need theirs |
| Telemetry | analyticsd, triald, cloudtelemetryd, hangtelemetryd and other reporting daemons | Upload only. ReportCrash and osanalyticshelper stay, for `logs.crashes` |
| Accessory firmware | accessoryupdaterd, uarpd and helpers | No accessories. accessoryupdaterd used 18 s of CPU at boot |
| OTA | softwareupdateservicesd, mobile.softwareupdated, OTATaskingAgent, OTACrashCopier | Same as the [OTA block](ota_software_update_block.md) |
| Cellular extras and prediction | WirelessRadioManager, carkitd, vmd, PowerUIAgent, duetexpertd, ospredictiond | CommCenter itself stays |

Some of these are only optional: Shortcuts, dictation, HomeKit, Maps,
Mail, Reminders, iMessage and Safari bookmark sync. A research target that
uses one of those frameworks needs its daemon back. Pass that label in `allow`
and apply again; the profile turns back on a recorded label it no longer
selects.

iOS 26 and 27 have a list, both measured on iPhone guests (see
[iOS 26](#ios-26) for how the 26 list differs). vphoned picks the list by
the major version alone, so an iPadOS guest of those versions gets the iPhone
list, which nobody has measured there. Any other version gets "No trimmed
service list".

## Never disabled

`GuestServiceProfile.neverDisable` lists what the profile refuses to disable,
whatever list or group names it. Four kinds of job were measured to make the
guest **worse** when off, and are kept out of the lists for that reason:

| Job | What happens without it | Evidence |
| --- | --- | --- |
| `com.apple.sleepd` | SpringBoard's and mobiletimerd's HealthKit sleep clients (`HKSPXPCConnectionProvider`) reconnect to `com.apple.sleepd.sleepserver` with no back-off | 5000 log lines in 3 s, host at about 400% CPU, launchd used 115 s of CPU and wrote 385 MiB in the first two minutes |
| `com.apple.CommCenter`, `CommCenterMobileHelper`, `CommCenterRootHelper` | SpringBoard's `SBTelephonyManager` reconnects to `com.apple.commcenter.xpc` every second and resets the idle timer each time (`updateIdleTimerForReason:"TelephonyManager:UpdateSB"`), so **the screen never turns off** | A 1 Hz loop in the log; backboardd grew from 99 to 160 MB; SpringBoard took 4418 wakeups in two minutes |
| `com.apple.cloudd` | transparencyd (`Retrying CK account state fetch`) and ScreenTimeSettingsAgent keep retrying CloudKit | Each wrote 50–60 MiB per 15 idle minutes, against nothing on the untrimmed guest. Idle writes rose above the untrimmed guest's, to 337 MiB per 15 minutes |
| `com.apple.nanoregistryd`, `nanoregistrylaunchd` | locationd waits synchronously on NanoRegistry's management queue | A spindump of a hung locationd showed `com.apple.nanoregistry.registry.managementqueue` in `dispatch_sync`. 27.0's locationd also hangs and crashes on its own, so this is kept out of caution |

The rest of the list is what vphone's own features and the tools it drives
rely on. Each one was traced to vphoned, IcliKit, the guest hooks or a
research note: SpringBoard, backboardd, runningboardd, lsd,
containermanagerd, installd, misagent, lockdownd, remoted, cryptexd,
remotepairingdeviced, avconferenced, diskimagesiod, locationd, bluetoothd
(locationd calls it synchronously), pasted, powerd, amfid
(`com.apple.MobileFileIntegrity`), profiled, keybagd, cfprefsd, notifyd,
mDNSResponder, configd, timed, tzlinkd, securityd, logd, diagnosticd,
ReportCrash, osanalyticshelper, audiomxd, mediaplaybackd, mediaremoted,
cameracaptured, mobileactivationd, mobileassetd and storekitd (which the OTA
and App Store notes require), and vphoned itself. dtremotedisplayd and
dtdeviceinfod are not launchd.plist jobs on 27.0 and are out of reach anyway.

Two jobs looked like candidates and cannot be disabled this way.
`com.apple.siri.context.service` and `com.apple.siri.acousticsignature` are
XPC services, not LaunchDaemons, so the override is written and they run
anyway.

## Measurements

These numbers come from `svctest-a`, a `--new-identity` clone of an iPhone
27.0 (24A435) guest with cloudOS 26.4, 8 GB and 8 cores, started `--headless`
after `setup.skip` (2026-10-07). Both runs used the same machine and disk. The
baseline is its third untrimmed boot. Host figures are `proc_pid_rusage` of
the VM process every 10 s. Guest figures come from `processes.list`,
`memory.jetsam` and `/usr/bin/taskinfo`, run through a one-shot launchd job.

| After 17 minutes idle | Untrimmed | Trimmed (137 + store) | Change |
| --- | --- | --- | --- |
| Guest process footprint, summed | 1658 MB | 1177 MB | −29% |
| Processes | 394 | 263 | −33% |
| `memorystatus_level` (free memory) | 62% | 73% | |
| Host VM process CPU, idle window | 6.5% of a core | 4.8% | −26% |
| Host writes, 15 idle minutes | 220 MiB | 89 MiB | −60% |
| Host writes, first 100 s of boot | 572–604 MiB | 363–423 MiB | about −35% |
| Host VM process footprint | 8.67 GB | 7.26 GB | |

Boot CPU varied more between runs (72–208 s in the first 100 s untrimmed,
44–138 s trimmed) than trimming changed it, so only the drop in boot writes is
dependable. vphoned answered 5–14 s after start either way, because launchd
starts it early. The host keeps most of the memory the guest frees, since the
VM has no balloon device. The gain is headroom inside the guest.

A template set up with the profile (P0, 2026-10-07) showed the same effect on
its clones. A clone's first 100 s wrote 372–375 MiB, against 1040 MiB for a
clone of an unprepared template.

### Function checks

These checks gave the same result trimmed and untrimmed: unlock, screenshot,
`apps.list` (258), installing a small app with `apps.install` and launching it,
Settings, clipboard, `audio.state`, starting the Camera app, uninstalling.
SpringBoard kept the same pid through every run, and no new crash type
appeared.

Not checked:

- installd's own install path (`ideviceinstaller`).
- Xcode and DeviceHub screen viewing. The jobs they need are kept.
- Frida.
- A real microphone path.
- **Location.** 27.0's locationd hangs or crashes with `EXC_ARM_PAC_FAIL` on
  untrimmed guests too, and Location Services were off after `setup.skip`.
  On iOS 26.6.2, where locationd works, location simulation and Maps' blue
  dot work with the Maps background group and `nearbyd` off ([iOS 26](#ios-26)).
  On 27 it waits for locationd to be fixed.

Known side effect: with `weatherd` off, the default Home Screen's Weather
widget reads "Weather Unavailable". Pass `allow: ["com.apple.weatherd"]` to
keep it.

## iOS 26

The iOS 26 list is the iOS 27 one mapped onto iPhone17,3 26.6.2 (23G90),
measured on `t26-a` (cloudOS 26.4, 8 GB, 8 cores, `--headless`, 2026-10-09),
a clone of a template built `--service-profile none`.

How it was derived:

1. The LaunchDaemons and LaunchAngels of both IPSWs' `launchd.plist`, by
   `Label`: 685 on 26.6.2, 724 on 27.0.
2. Of the 137 labels of the 27 base list, 132 exist on 26 under the same
   name. `cloudtelemetryd`, `hybridsearchd`, `libsqlite3.dbtelemetryd`,
   `speechmaintenanced` and `visualintelligenced` do not exist on 26, under
   that name or another.
3. Of those 132, 131 load on the guest. `safetyalertsd` has a
   `LimitLoadToHardware` list of real devices on 26, so it never loads there
   and is left out, as the 27 list holds only jobs loaded at boot.
4. The store, sign-in follow-up and account groups have the same seven labels
   on 26.
5. Four jobs exist only on 26. `com.apple.factory.NFQRCoded` lives in
   `/Developer` and does not load; `deviceinterfaced` and `systemactions`
   load but did not run. `com.apple.timesync.audioclocksyncd` runs and was the
   guest's largest idle CPU user once trimmed (1.5 s and 14,000 context
   switches per 15 minutes, printing PTP clock statistics). With it disabled
   as well the host's idle CPU did not move (2.69% of a core either way), so
   it stays on.

So `trimmed` on 26 disables 131 + 2 + 2 = 135 labels (`GuestServiceProfile.base26`,
`notLoadedOn26`). The never-disabled set needed nothing new: no job of the
list made the guest worse when off, and the four traps of 27 are kept on 26 as
on 27 without being measured again.

| After 17 minutes idle | Untrimmed | Trimmed (131 + store + follow-up) | Change |
| --- | --- | --- | --- |
| Guest process footprint, summed | 1516 MB | 1061 MB | −30% |
| Processes | 373 | 230 | −38% |
| Running launchd jobs | 300 | 179 | |
| `memorystatus_level` (free memory) | 65% | 74% | |
| Host VM process CPU, 15 idle minutes | 4.43% of a core | 2.69% | −39% |
| Host writes, 15 idle minutes | 301 MiB | 18 MiB | −94% |
| Guest CPU, 15 idle minutes (taskinfo) | 19.1 s | 8.9 s | −53% |
| Host writes, first 100 s of boot | 480 MiB | 305–315 MiB | about −35% |
| Host VM process footprint | 8.20 GB | 6.92 GB | |

One untrimmed and one trimmed run of the same machine and disk, the windows
from 120 to 1020 s after start. Boot CPU was 72 s untrimmed and 48–75 s
trimmed in the first 100 s, within the spread 27 showed. Most of the
untrimmed idle writes came in one burst five minutes after boot. With the
profile on, the screen still turned off, the logs stayed at 50–80 lines per
10 s after two minutes, and locationd started once on every boot.

Function checks, trimmed and untrimmed alike: unlock, screenshot,
`apps.list` (236), installing a small app with `apps.install`, launching it,
Settings, clipboard, `audio.state`, playing a WAV in Safari (21 s, 247
writes, none starved, host 47999.7/s), starting the Camera app (26.6.2
publishes the synthetic camera: `libvcamcaptured` appends its source to
`_sSourceList`), `location.set` and `location.current` with Location
Services turned on, and Maps showing the blue dot at the simulated
coordinate, uninstalling. SpringBoard kept its pid throughout.

One difference showed in crash reports. On 2 of 16 trimmed boots, and none
of 7 untrimmed ones, three control and widget extensions (CalculatorWidget,
BarcodeScannerWidgetExtension, LauncherControlExtension) stopped in their
first seconds in WidgetKit's `ControlAction.init(_:)` with "Can't create
CHSIntentReference from" an App Intent. They are launched again on demand,
and nothing visible was affected; which disabled job the intent reference
needs was not found. `SiriSearchFeedback` crashed in both configurations.

## Applying it in a template

A template is changed once, in its setup boot, and frozen; every clone
inherits the overrides and the record. The order matters:

1. `setup.skip`.
2. `setup.settle`, until first-boot app expansion is done.
3. Remove the system apps.
4. `services.profile.apply {profile: "trimmed", force: true}`. The
   `signin_followup` group belongs after the first-boot work, which step 2
   already waited for. Every override waits for the reboot anyway, so one call
   covers both the services and the sign-in follow-up.
5. Reboot, and check that no job the profile owns is running
   (`services.profile` → `running` empty).
6. Shut down and freeze.

## Reverting

On a running guest:

```sh
vphone-launchpad-cli guest rpc <vm> services.profile.apply '{"profile":"none","force":true}'
vphone-launchpad-cli vm stop <vm> && vphone-launchpad-cli vm start <vm> --wait
```

That turns back on only what the profile disabled. To keep the profile but
bring back one job, apply `trimmed` again with that label in `allow`. To
bring back the Apple Account daemons on a guest that had `accounts`, apply
`trimmed` without that group.

## Idle cost of vphone's own components

With the profile applied, the largest idle cost left in a guest was vphone's
own plumbing: timers in the guest hooks that ran whether or not anything used
the feature behind them. Measured 2026-10-09 on two clones of one trimmed
iPhone 27.0 (24A435) template, `--headless`, 15 idle minutes (902 s) starting
three minutes after boot, screen off and locked, no camera, audio or API
client. Guest figures are `/usr/bin/taskinfo` differences (CPU time and
interrupt wakeups per process), run through a one-shot launchd job; host
figures are the CPU time of the VM's Virtualization service and of
`vphone-vm`.

| Per 15 idle minutes | Before (2 runs) | After (2 runs) | Source |
| --- | --- | --- | --- |
| cameracaptured wakeups / CPU | 27,212–27,960 / 2.1–3.1 s | 953–956 / 0.1 s | `libvcamcaptured`'s 30 Hz frame drive ran for the daemon's whole life; it now runs only while a viewfinder stream or video sink exists ([`virtual_camera_transport.md`](virtual_camera_transport.md#idle-cost-2026-10-09)) |
| audiomxd wakeups / CPU | 21,670–22,548 / 1.8–2.6 s | 944–952 / 0.1 s | The virtio sound speaker's 1/24 s flush timer kept firing after the boot sound stopped; it is now disarmed when the stream stops ([`virtio_sound.md`](virtio_sound.md)) |
| AccessibilityUIServer, InputUI wakeups | about 905 each | 0–7 | `libcamfix`'s 1 Hz preview-layer scan on the main queue of every app-path process with AVFoundation; it now starts with the first running vcam session |
| SpringBoard wakeups / CPU | 1,603–1,606 / 0.8–1.0 s | 714–717 / 0.3 s | The same scan, in SpringBoard |
| backboardd wakeups | 788–817 | 419–433 | `libvphonegyro` republished its status through cfprefsd every two seconds; now only while samples are dispatched ([`virtual_gyroscope.md`](virtual_gyroscope.md)) |
| vphoned wakeups | 315–328 | 38–40 | The 3 s `device.state` poll ran with no subscriber; it now runs only while an event socket is open |
| All guest processes, wakeups | 62,873–64,396 | 12,324–12,374 | −81% |
| All guest processes, CPU | 11.2–20.4 s | 7.7–7.8 s | |
| Host VM service CPU | 26.4–33.5 s (2.9–3.7% of a core) | 20.2 s (2.2%) | |
| Host `vphone-vm` CPU | 1.9–2.1 s | 0.3 s | The 3 s health probe read and hashed the 9 MB vphoned on the main thread each time; the hash is now kept until the file changes (`VPhoneFileDigestCache`) |

What is left at the top is Apple's own: mDNSResponder (about 1,900),
locationd (1,100), cameracaptured and audiomxd (about 950 each with nothing
of ours running in them), clipserviced, fseventsd and backboardd.

**remotepairingdeviced is quiet on a guest that was never paired**: 30
wakeups and under 0.01 s of CPU per 15 minutes, 0.12 s in its first 18
minutes, no log lines in a minute. No vphone code talks to it. The 3.5–8 s
measured earlier came from a clone of a DeviceHub test machine that had been
paired with this Mac's CoreDevice, so that cost follows pairing between Apple's
daemons on both sides. An unpaired guest that is unlocked gets a "Trust This
Computer?" alert from the Mac shortly after; answering it is what pairs it.

Checked after the change: playback through Safari (91 s, 1,073 writes, none
starved, host rate 48000.1/s) on a boot whose speaker had already started and
stopped once, so the timer was re-armed; audiomxd fell back to 1.6 wakeups a
second when it stopped. The gyroscope configuration still reaches the provider
and `provider_running` stays true while idle. `device.state` arrives about a
second after an event socket opens and again after an unlock; vphoned took 45
wakeups a minute with a socket open and 7 without. A guest with an older
vphoned was still updated by `vphone-vm` over HTTP. Not checked live: camera
frames, because the iPhone 27.0 guest publishes no synthetic camera
(`libvcamcaptured` logs `_sSourceList not located` on every boot, before and
after), so no client can reach the drive; and the microphone, whose code did
not change.

## Open items

- **iPadOS.** vphoned picks the list by major version only, so iPad guests on
  26 and 27 get the iPhone lists. No iPad guest has been measured with them.
- **WidgetKit control extensions on iOS 26.** The `ControlAction.init(_:)`
  crashes on 2 of 16 trimmed 26.6.2 boots ([iOS 26](#ios-26)) point at a
  disabled job an App Intent reference needs; which one was not found.
- **Location on iOS 27.** Location simulation under the profile is verified
  on 26.6.2 only; on 27.0 it waits for locationd itself to work
  ([locationd startup deadlock](locationd_startup_deadlock.md)).
- **Host memory.** The VM has no balloon device, so the guest's freed memory
  stays with the VM process (8.67 → 7.26 GB on 27.0). Returning it would take
  `VZVirtioTraditionalMemoryBalloonDevice` and a guest that drives it, which
  was not evaluated; giving trimmed machines less memory is the simple way to
  use the headroom.
- **Sample size.** Each configuration's idle figures come from one or two
  15-minute windows, and bursts of maintenance work that `dasd` schedules
  (mediaanalysisd, cloudd, searchd) dominated some of them. They show the
  direction, not a precise rate.
