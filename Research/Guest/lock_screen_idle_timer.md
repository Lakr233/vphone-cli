# Auto-Lock "Never" and the Lock Screen

A guest with Settings › Display & Brightness › Auto-Lock set to Never still
went dark by itself. vphoned's `GuestLockScreenIdle`
(`VPhoneDaemon/Daemon/GuestLockScreenIdle.swift`) and its `display.auto_lock`
method rest on the measurements below, taken on 2026-10-03 against
`nettest-01` (iOS 27.0, 24A435) and `locktest-ipad` (iPadOS 26.6.2, 23G90)
over `vphone.sock` with `settings.get/set/delete`, `system.respring`,
`device.snapshot` (`lock.locked`, `lock.screen_off`) and `logs.syslog`
filtered to SpringBoard's `IdleTimer` category.

## What goes dark

The setting was in effect. On `ipad-mini-01`, `ipad-pro-13` (iPadOS 26.6.2)
and `nettest-01`,
`/var/mobile/Library/UserConfigurationProfiles/EffectiveUserSettings.plist`
held `restrictedValue.maxInactivity.value = 2147483647`, and SpringBoard logged,
for the Home Screen and for a foreground app:

```
dsc … <mode: Auto; …> reason:MCFeatureAutoLockTime (2.14748e+09) is gt MAX (3600)
-> dsc … <mode: Disabled; …> reason:after setup, shouldWarn is NO and expireInterval is <never>
```

An unlocked guest left alone stayed lit: 21 minutes on `ipad-mini-01`, 9 on
`nettest-01`, with no backlight or lock line in SpringBoard or backboardd.

The Lock Screen is the part that does not follow the setting.
`SBDashBoardIdleTimerProvider` asks for `duration: Default`, and the same
factory answers six seconds whatever Auto-Lock says:

```
idleTimerDescriptorForBehavior: <SBIdleTimerBehavior: …; duration: Default; mode: Inherit; warnMode: Inherit>
dsc … reason:MCFeatureAutoLockTime (2.14748e+09) is gt MAX (3600)
dsc … <…; total: 6.0s> reason:duration is Default
applying updated idle timer descriptor: <SBIdleTimerDescriptor: …; mode: Inherit; …; total: 6.0s> reason:SBDashBoardScreenOff
```

Waking a guest to the Lock Screen and leaving it, `lock.screen_off` turned
true 8 seconds later on `nettest-01` and 7 on `locktest-ipad`. A guest lands
on the Lock Screen after every boot, every SpringBoard restart
(`system.respring`, `setup.skip`, a crash) and every press of the side button,
and nobody is holding it. So it boots, shows the Lock Screen and is black a
few seconds later, which reads as the device going to standby on its own.

Nothing on the host does this. `vphone-vm` sends the power key only from the
Device menu, the Controls panel and the automation socket's `key` request.

## `SBMinimumLockscreenIdleTime`

SpringBoard reads `SBMinimumLockscreenIdleTime` from `com.apple.springboard`
(user mobile) and, when it is set, uses it in place of the six seconds:

```
dsc … <…; total: 6.0s> reason:duration is Default
dsc … <…; total: 2147483647.0s> reason:totalInterval (6) is gte 0
applying updated idle timer descriptor: <…; mode: Inherit; …; total: 2147483647.0s> reason:SBDashBoardScreenOff
```

Each row sets the key, then wakes the guest to the Lock Screen and reads the
descriptor SpringBoard applies.

| Change | Lock Screen timeout |
| --- | --- |
| key absent | 6 s |
| 600, then SpringBoard restarted | 600 s; lit after 40 s |
| 7200, then SpringBoard restarted | 7200 s |
| 2147483647, then SpringBoard restarted | 2147483647 s |
| the same value written again, no restart | unchanged |
| set while absent, no restart (integer or float) | 6 s |
| a different value while set, no restart | 6 s, until SpringBoard restarts |
| removed, no restart | 6 s |

The table is `nettest-01`. On `locktest-ipad` the absent, 2147483647 and
removed rows gave the same results (6 s and off after 7; lit after 45 s; off
after 7).

SpringBoard takes the value when it starts. A later change is not picked up,
and a change of an existing value drops the override for the rest of that
SpringBoard's life. Writing the value it already has is harmless.

The unlocked timeout is not affected: with the key at 2147483647 and
Auto-Lock at 30 seconds, the Home Screen went dark after 32 seconds.

## What vphoned does

`GuestLockScreenIdle` mirrors Auto-Lock into that key:

- Auto-Lock is Never and the key is not 2147483647: write 2147483647.
- Auto-Lock is anything else and the key is 2147483647: remove it. Any other
  value is someone else's and stays.

It runs first thing when vphoned starts, before the rest of startup, and again
on `com.apple.managedconfiguration.effectivesettingschanged`, the Darwin
notification profiled posts after rewriting `EffectiveUserSettings.plist`.

Settings does not commit Auto-Lock when a row is tapped. The file kept the old
value for 75 seconds with the new row checked, and changed within two seconds
of leaving Settings; vphoned's log line followed in the same two seconds.

Because SpringBoard reads the key once:

- A guest whose key is already in place boots to a Lock Screen that stays lit.
- Turning Never on in Settings writes the key once Settings commits, and it
  holds from the next SpringBoard start (reboot or `system.respring`).
- Turning Never off removes the key, and the Lock Screen is back to six
  seconds immediately.

Measured with the vphoned of this change, on both guests:

| Step | Result |
| --- | --- |
| Auto-Lock Never, key absent, guest started; the host replaces vphoned over HTTP about six seconds after boot | key written at startup; the Lock Screen of that same boot uses 2147483647 s and is lit after 40 s |
| Auto-Lock to 2 minutes (`locktest-ipad`) | key removed; Lock Screen off after 7 s |
| Auto-Lock back to Never, then `system.respring` (`locktest-ipad`) | key written; Lock Screen lit after 60 s |

Setter, measured on a throwaway guest (`display.auto_lock.set`, then `display.auto_lock`):

| Step | Result |
| --- | --- |
| `seconds` 60, 180, 7 | `auto_lock_seconds` 60, 180, 7; `lock_screen_minimum_seconds` null |
| `seconds` 0 | 2147483647, `never` true, `lock_screen_minimum_seconds` 2147483647 |
| `system.respring` after 0 | still 2147483647 and `never` true |
| `seconds` 120, then `system.respring` | 120 before and after; `lock_screen_minimum_seconds` null |
| `seconds` -1 | error "Auto-Lock seconds must be between 0 and Int32.max"; value stays 120 |
| vphoned signed without the entitlement, `seconds` 0 from 120 | error "profiled did not apply the Auto-Lock change"; value stays 120, minimum null |

The first row of the table above means vphoned's write beats SpringBoard's read on a normal boot
even when vphoned is first replaced by the host. That is an observation on
these two guests, not a guarantee.

`display.auto_lock` reports `{auto_lock_seconds, never,
lock_screen_minimum_seconds}`; capability `display_auto_lock`.

The side button still turns the screen off; that is a request, not a timeout.

## Setting Auto-Lock from vphoned

`display.auto_lock.set` once wrote `restrictedValue.maxInactivity` into
`UserSettings.plist` through cfprefsd. It returned success while
`display.auto_lock` kept the old value, also after `system.respring`: profiled
regenerates `EffectiveUserSettings.plist` from its own state and ignores that
file, and a stored `0` was not Never either.

Only profiled changes the effective value, through
`-[MCProfileConnection setParametersForSettingsByType:toSystem:user:passcode:]`.
profiled drops that call without an error unless the caller holds
`com.apple.managedconfiguration.profiled.set` (an array containing
`UserSettings`) or the boolean
`com.apple.managedconfiguration.feature-setting.maxInactivity`. vphoned is
signed with the second one.

The setter calls it with `toSystem:NO user:YES`, because the user file
overrides the system file in the effective merge, and with
`{"restrictedValue":{"maxInactivity":{"value":N,"rangeMinimum":0}}}`;
`rangeMinimum` 0 lets values below the stored minimum apply. `seconds` 0 is
sent as 2147483647 (Never). The variant with a completion block and
`waitUntilCompleted` crashed vphoned, so it is not used. Success is reported
only after `EffectiveUserSettings.plist` shows the requested value, within
three seconds; otherwise the call fails with "profiled did not apply the
Auto-Lock change". A vphoned signed without the entitlement therefore returns
that error instead of a silent success.

## Reproducing

```sh
vphone-launchpad-cli guest rpc <vm> display.auto_lock
vphone-launchpad-cli guest send <vm> '{"t":"key","name":"power","screen":false}'   # screen off
vphone-launchpad-cli guest send <vm> '{"t":"key","name":"power","screen":false}'   # Lock Screen
# after 10 s and again after a minute:
vphone-launchpad-cli guest rpc <vm> device.snapshot      # lock.screen_off
vphone-launchpad-cli guest rpc <vm> logs.syslog '{"seconds":6,"process":"SpringBoard","max_lines":5000}'
```

The `IdleTimer` line `applying updated idle timer descriptor` carries the
`total` SpringBoard uses.
