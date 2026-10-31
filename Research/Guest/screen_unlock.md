# Turning the screen on and unlocking

vphoned's `screen.unlock` (`VPhoneDaemon/Daemon/GuestScreenUnlock.swift`,
`VPhoneDaemon/Native/vphoned_unlock.m`) and `vphone-launchpad-cli guest unlock`.
Measured on 2026-10-04 against `unlocktest-iphone` (iPhone17,3, iOS 27.0
24A435, no passcode), with the 26.6.2 dyld shared cache for the static read.

## Why a method

A guest is at the Lock Screen after every boot, every SpringBoard restart and
every press of the side button, and it is dark a few seconds later
(`lock_screen_idle_timer.md`). A locked or dark screen swallows taps, and
`apps.launch` answers `device_locked`.

The hardware keys only toggle. `power` wakes a dark guest and darkens a lit
one; `home` wakes, and on a lit Lock Screen without a passcode it dismisses to
the Home Screen. A script has to read `device.screen` first and choose. The
method does that reading and does only what each state needs.

## What SpringBoard's own unlock request does, and why it is not used

SpringBoardServices has `-[SBSLockScreenService
requestPasscodeUnlockUIWithOptions:withCompletion:]` (`0x191f505c8` in the
26.6.2 cache), the request an app makes when it needs an unlocked device.
Served to a caller with `com.apple.springboard.requestDeviceUnlock` (the
authenticator in `-[SBLockScreenService init]` is built with that entitlement
string, at `0x224be0ae4`).

Granting vphoned that entitlement and calling the request was tried first. The
guest log shows why it does not unlock a passcode-free device:

```
unlockUIFromSource:ExternalRequest options:({SBUIUnlockOptionsTurnOnScreenFirstKey: 1}) screenWasOff:YES
Bailing from UIUnlock because: turnOnScreenFirst = 1; autoUnlock = 0; shouldTurnOnScreen = 1
```

Asked while the screen is off, SpringBoard treats the request as *turn the
screen on first*: it lights the backlight and bails out of the unlock
(`autoUnlock = 0`), leaving the Lock Screen up. A second request, with the
screen now on, did not dismiss it either. The request is the wrong tool for a
passcode-free guest, and it needs a private entitlement. Both were dropped.

## What `screen.unlock` does

1. Reads `com.apple.springboard.lockstate` and
   `com.apple.springboard.hasBlankedScreen` (IcliKit's `lockState()`). Until
   `com.apple.springboard.finishedstartup` is non-zero these read
   "unlocked, lit" no matter what will show, so at startup it waits for that
   notification before trusting them.
2. Not locked, only dark: `SBSUndimScreen`, and done. This lights the display
   with no toggle and needs no entitlement (it is what icli's `wake` calls).
3. Locked: if dark, `SBSUndimScreen` first so the next step lands on a live
   Lock Screen. Then press Home.
   - No passcode: Home dismisses the Lock Screen. Repeated until unlocked or
     the deadline, in case the first press landed while the display was still
     coming up.
   - Passcode: Home raises the passcode pad; `passcode` is typed (digits as
     keyboard number keys `0x1E`–`0x27`, anything else as text), with Return
     if the pad has not submitted after a second.
4. Polls the two notify states every 100 ms until lit and (if it was locked)
   unlocked, or `timeout` (10 s by default, 1–60) runs out.

Result: `{locked, screen_off, was_locked, was_screen_off}`; capability
`screen_unlock`. No private entitlement.

## Live results (no-passcode guest)

All on `unlocktest-iphone`, each followed by `device.screen` and
`apps.foreground`:

| State before | `guest unlock` | After |
| --- | --- | --- |
| just booted, dark Lock Screen | ok, `was_screen_off:true was_locked:true` | Home Screen, lit |
| lit, unlocked | ok, all `false` | unchanged |
| `power` → dark + locked | ok | Home Screen, lit |
| same, repeated | ok | Home Screen, lit |
| lit Lock Screen (`was_screen_off:false`) | ok | unlocked; `apps.launch` Settings then `frontmost_verified:true` |
| after `system.respring` → Lock Screen | ok | Home Screen, lit |

So the device is actually usable afterwards, not merely reporting unlocked.

## Unlock at startup

A machine whose `config.plist` has `unlocksAtStartup` (`vm config <name>
--unlock-at-startup on`, Device > Unlock at Startup, or Launchpad's machine
Settings) has `vphone-vm` call `screen.unlock` with a 60 s timeout when a
vphoned that has just started connects. vphoned's `/v1/health` carries
`instance`, a UUID made when it starts; the host keeps the last one it saw
across disconnects, so a probe that drops and reconnects to the same vphoned
is not unlocked again. A guest still in Setup Assistant is skipped. A vphone guest cannot have a
passcode (see "Why a passcode cannot be set" below), so the setting never
meets one.

Measured on 2026-10-04 on `autounlock-iphone` (iPhone17,3, iOS 27.0 24A435,
no passcode, Auto-Lock 1 minute), bundle 2.6.0-local:

| Run | Setting | `device.screen` after boot |
| --- | --- | --- |
| VM start | off | locked at 5 s, dark from then on |
| VM start | on | locked at 4 s, unlocked and lit by 16 s; log `[unlock] dismissed the Lock Screen at startup` |
| `system.reboot {userspace: true}` in the running VM | on | new vphoned, unlocked and lit, then locked again by Auto-Lock after a minute |

The re-lock after a minute is the guest's own Auto-Lock acting on an unlocked
device, not a failed unlock. The very first reading after a boot can say
"unlocked, lit" before SpringBoard has started (see step 1 above), so a check
has to watch for a while, not trust one sample.

On a second guest (`unlockpr-iphone`, same build, 2026-10-05) one start with
the setting on stayed locked: the log read `[unlock] the guest was already
unlocked`. `com.apple.springboard.finishedstartup` was already set, yet the
two notify states still read unlocked, and the Lock Screen came up a few
seconds after `screen.unlock` had returned. So the host does not take
"already unlocked" at startup as final: it polls `device.screen` once a
second and calls `screen.unlock` again when the Lock Screen appears, for up to
90 s after the connect (`VPhoneGuestControl.unlockAtStartup`). With that:

| Guest | Setting | Lock state every 3 s after `vm start --wait` (L locked, u unlocked) |
| --- | --- | --- |
| `unlockpr-iphone`, iOS 27.0, three starts in a row | on | `Luuuuuuuuuuuuuuuuuuu` then L (Auto-Lock) each time |
| `unlockpr-ipad`, iPad16,1, iPadOS 26.6.2 23G90 | off | `LLLLLLLLLLLLLLLLLLLLLLLLL` |
| `unlockpr-ipad` | on | `Luuuuuuuuuuuuuuuuuuuuuuuu` |

Device › Unlock at Startup in the VM window checked itself, wrote
`unlocksAtStartup = true` to config.plist at once, left the running guest
locked, and the next start unlocked it.

Setting a passcode on `unlockpr-iphone` through Settings did not work. The
new-passcode pad there takes four digits (its field reads "0 of 4 values
entered"); a first try with six digits spilled two into the verify step and
ended in "Passcodes Did Not Match". With four digits, entered a digit every
1.5–2 s and checked after each, both entries matched, and Settings then
answered "Passcode Change Failed" (two different codes, same result). The
passcode path therefore stays unmeasured.

### Why a passcode cannot be set (2026-10-05)

The same failure is upstream issue #467 ("无法设置锁屏密码"), closed without
a cause. Logs captured per process with `logs.syslog {process}` during one
attempt show where the change stops:

1. Preferences → ManagedConfiguration: `Change passcode with context error …
   The passcode cannot be set (-1)`, `MCPasscodeErrorDomain` 5014.
2. profiled: `com.apple.Preferences is attempting to change the passcode`,
   then calls `com.apple.mobile.keybagd.xpc` and logs `Failed to set new
   passcode. Result: -1`.
3. keybagd: `KBChangeSystemSecret: handle: -3, se-support: 0, primary-user: 1
   …`, `KBisxARTBasedKeyBag: Result = 1`, `KBChangeSystemNonSeSecret:
   change-secret failed e00002ce`.
4. kernel: `"AppleSEPKeyStore":pid:56 … operation failed (sel: 15 ret:
   e00002ce)` (pid 56 is keybagd). `e00002ce` is `kIOReturnNotReadable`, and
   the kext returns it as the SEP's answer, so the SEP refuses the change.

What differs from a real iPhone, from the same boot's console log:

- `MKB_INIT: No system keybag found on filesystem` and `No system keybag
  loaded`. `/private/var/keybags` holds `usersession.kb` and `persona.kb`,
  no `systembag.kb`. Boot continues only because the vphone600 device tree
  sets MKB `dt = 1` (see `Research/Firmware/firmware_manifest_and_origins.md`).
- `no-effaceable-storage is ON`, and AppleSEPKeyStore logs `disabling use of
  effaceable storage, using fake key, 0xffffffff`. The switch is
  `/defaults/no-effaceable-storage` in `DeviceTree.vphone600ap`, which a
  phone's device tree does not have; the VM has no effaceable storage.
- The SEP firmware is `sep-firmware.vphone600.RELEASE` from the cloudOS
  (PCC) IPSW. PCC nodes have no user passcode.

So the refusal comes from the SEP keystore on a platform built without
effaceable storage or a system keybag, not from vphoned, the input, or the
UI. Nothing on the host or in the guest's userland changes that. Making it
work would mean changing how the guest's keystore is provisioned at restore
and boot, which this note does not attempt. Until then a passcode guest
cannot be made, and `screen.unlock`'s passcode path cannot be run.

## Tap to wake

A phone's touch controller reports a tap on a dark screen as a wake gesture,
and SpringBoard lights the Lock Screen for it. The VM's touchscreen has no
such gesture, so a click in the window on a dark guest did nothing.

vphoned (`vp_tap_to_wake_start` in `vphoned_unlock.m`,
`GuestScreenUnlock.startTapToWake`) watches
`com.apple.springboard.hasBlankedScreen`. While it is set, an
`IOHIDEventSystemClient` of the monitor type (vphoned has
`com.apple.private.hid.client.event-monitor`) sees every HID event, and a
digitizer event with `kIOHIDEventFieldDigitizerTouch` set (at most one every
half second) wakes the screen:

1. `SBSUndimScreen`.
2. If the screen is still dark 0.5 s later, one side-button press
   (consumer `0x30`), at most one every 1.5 s so two never make a Wallet
   double-click. On a dark screen the side button only wakes it.

Home is never pressed, so the guest stays on its Lock Screen. The client is
released when the notify state clears. It works for every touch source the
guest's HID system sees: the VM window, a Launchpad viewer, `input.tap`.
backboardd itself drops the waking touch (`ignoring touch event ((backlight
dim/off))`), so the tap never reaches what is under it.

On iOS 27.1 (24A94425, `waketest-iphone`, 2026-10-29) SpringBoard refuses
`SBSUndimScreen` from vphoned: `_SBXXDimScreen Authentication failed:
Process lacks credentials to access this resource.` So step 2 is what lights
the screen there, and on that build `screen.unlock` and icli's `wake` light
it only through their Home-press fallback. Which entitlement the MIG
handler checks has not been looked up.

The Controls panel's Wake button is different: it is icli's `wake`, which
presses Home after `SBSUndimScreen` until a passcode-free guest is unlocked.

## Not yet measured

- **Passcode guests.** vphone does not support a passcode (see "Why a
  passcode cannot be set" above), so the Home-raises-the-pad-then-type path
  cannot be run. It is written to the behavior of a real device.
- iOS 27.0.1 (its guests kernel-panic at first boot, separate
  issue).

## Reproducing

```sh
vphone-launchpad-cli guest send <vm> '{"t":"key","name":"power","screen":false}'   # dark + locked
vphone-launchpad-cli guest rpc  <vm> device.screen                                 # locked, screen_off
vphone-launchpad-cli guest unlock <vm>
vphone-launchpad-cli guest rpc  <vm> device.screen
vphone-launchpad-cli guest rpc  <vm> apps.foreground
```

The `Bailing from UIUnlock` evidence, if the request path is revisited:

```sh
vphone-launchpad-cli guest rpc <vm> logs.syslog '{"seconds":8,"process":"SpringBoard","max_lines":5000}'
```
