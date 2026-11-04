# Virtual 3D gyroscope

## Core boundary (2026-10-08)

The core adds raw three-axis angular velocity, in **radians per second**. It
does not represent Euler angles or synthesize accelerometer, compass, attitude,
or fused `CMDeviceMotion`.

`vphoned` exposes `motion.gyroscope.set {x,y,z,enabled?}`, `motion.gyroscope.get`, and
`motion.gyroscope.clear` over the existing VSOCK 1339 RPC transport. Set requires
all three finite JSON numbers in [-1000,1000]; strings, Booleans, missing axes,
and out-of-range values are refused before any state is changed. Clear disables
the configured rotation and writes zero on every axis. Set's optional `enabled`
must be a JSON Boolean and defaults to true, preserving existing clients. False
keeps the configured axes but makes the provider emit stationary samples.

One dictionary, `VPhoneGyroscopeConfiguration`, is written through cfprefsd to
the mobile user's `com.apple.backboardd` domain and then
`com.vphone.motion.gyroscope.changed` is posted. This avoids a separate port or
new daemon sandbox file permissions. A running provider reads the whole
dictionary on its serial queue; malformed stored state becomes stationary.
Configuration persists across guest restarts until changed or cleared.

As with the camera daemon hook, SystemHook loads a guest dylib without ElleKit
or a bootstrap. `/usr/lib/libvphonegyro.dylib` is loaded only into
`/usr/libexec/backboardd`, the HID server, after its constructors return. The
library publishes a `HIDVirtualEventService` with Apple vendor usage page
`0xff00`, usage `9`, and `IMULocationID = 0`. It creates each event through
`+[HIDEvent gyroEvent:x:y:z:options:]`, with `mach_absolute_time()` and an
incrementing gyro sequence. No system instruction is overwritten, no app's
`CMMotionManager` methods are swizzled, and there are no kernel/DSC edits.

HID report/batch interval requests are handled on that same queue. The provider
advertises aggregate sensor control so one client stopping does not cancel
other clients. A zero report interval stops the timer; nonzero requests are
bounded to 5,000–1,000,000 microseconds (1–200 Hz). There is no FIFO batching.
Clear leaves the service and subscriptions alive and emits stationary samples.
After a HID reset, the old service is cancelled and released only from its
cancel handler, then a new service is registered after five seconds.

`VPhoneGyroscopeStatus` is updated at configuration and service transitions,
and every two seconds while samples are dispatched (a client has set a report
interval). The RPC result includes `provider` and `provider_running`; the
latter requires an enumerated service and a running process with the status's
PID, and while samples are dispatched also a status younger than ten seconds.
Until 2026-10-09 the provider republished every two seconds regardless, so an
idle guest's backboardd rewrote the preferences domain through cfprefsd 450
times in 15 minutes. The status includes service ID, PID, report interval, dispatched event
count, dispatch failures, last error, and the configuration consumed by the
provider. **Enumeration and dispatch do not prove CoreMotion acceptance.**

## Host panel

The VM display app's **Features → Motion Sensors → 3D Gyroscope** menu opens a native
SwiftUI panel (Chinese: **功能 → 运动传感器 → 3D 陀螺仪**). Each axis has a text field
and a 0.1 rad/s stepper. Valid edits are sent immediately; partial, non-finite
and out-of-range text stays in the field with a validation message and is not
sent. The checkbox enables/disables simulation without discarding axis values.
**Reset** zeros all fields and sends the zero configuration, preserving the
checkbox. Reset also repairs partially typed/invalid fields.

The panel uses capability `motion_gyroscope_toggle`, so an older daemon which
would ignore `enabled` cannot silently apply the wrong checkbox state. It reads
the stored configuration on opening/reconnect, and keeps accepted local edits
when reconnecting after a failed send. A single in-flight RPC and one pending
full configuration coalesce rapid edits; disable and reset replace that pending
state, and stale acknowledgements never replace newer field text. Failed writes
remain unsynced with a retry action. Closing the panel does not drop a write
already accepted by the UI. The existing window controller retains the model
and uses `isReleasedWhenClosed = false`.

The shared `VPhoneMotionModel` / `VPhoneMotionView` also powers the independent
degree-based attitude editor; see `virtual_attitude.md`. Gyro configuration
remains raw rad/s and does not drive the attitude simulation.

The model test harness (`zsh VPhoneExecutable/VPhoneVirtualization/Tests/run-gyroscope-tests.sh`)
exercises delayed acknowledgements, coalescing, reset/disable while a write is
pending, invalid text, retry, reconnect, stale reads and decimal-comma input.
On 2026-10-08 these tests, the disabled-state property-list round trip and HID
event factory tests passed; the full `VPhone` bundle build also passed with the
Chinese menu/panel strings compiled into its resources. Native UI interaction
was not run after the local preview compilation request was declined.

## Patch selection and installation

`system-backboardd-cfw-gyroscope` is declared in the Guest System patch set and
selected by both shipped presets on iOS 18 and newer. The dylib is built for
arm64e with an iOS 18 deployment target. Missing runtime APIs produce a provider
error and leave backboardd running. A legacy install with no patch plan does
not enable this new provider; resolve an explicit selection first.

The mounted `cfw install` and `cfw update-environment` steps install this library
when selected and remove it when blocked. The general environment redeploy
does not own this file. A live hash sync may replace an already installed copy
but cannot add an absent copy, so it cannot undo a user's patch selection.
Updating the gyro library or its loading SystemHook asks for a reboot; it does
not restart backboardd, which would interrupt the guest UI.

To test a local build, install it with `vphone-launchpad-cli bundle install-local`
and bind the stopped test machine using `vm set-bundle <name> <version>
--update-environment`, as described in `Documents/en/launchpad/launchpad-cli.md`.
The mounted update adds this newly selected patch to an older machine too.
Reboot before testing. To turn it off, use the patch editor to block
`system-backboardd-cfw-gyroscope`, update the stopped machine's environment,
and boot again.

## Reveal evidence

Apple's primary interface sources:

- [HIDVirtualEventService](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/PrivateHeaders/HIDVirtualEventService.h): requires the HID event-dispatch entitlement; enumerated/terminated notifications and explicit cancel lifecycle.
- [HIDEventAccessors](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/Headers/HIDEventAccessors.h) and [implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/HIDEventAccessors.m): typed gyro factory and sequence accessor, signed 16.16 axis representation.
- [IOHIDEventServiceTypes](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEventServiceTypes.h): sensor control aggregation, decimation, and dispatch gating.

The user-opened CoreMotion cache image in Hopper was inspected read-only. Its
cache/build identity was not supplied, so the addresses below are **reveal
evidence only**, not a claim that every iOS base has been verified and never
runtime offsets:

1. `-[CMMotionManager isGyroAvailable]` at `0x1af9a662c` checks the CoreMotion
   initialization gate and its shared object before calling a query outside
   the imported image. That external query was not resolved.
2. The string `Setting Gyro matching properties with IMULocationID %d` reveals
   `CLGyro::openHidDevice` at `0x1af9ff8b0`. Its lookup key at `0x1afc68e38`
   contains `00 ff 00 00 09 00 00 00`: page `0xff00`, usage `9`. The adjacent
   accelerometer key uses page `0xff00`, usage `3`.
3. The gyro event callback beginning at `0x1af9ffb58` checks type `0x14`, reads
   X/Y/Z fields `0x140000`, `0x140001`, `0x140002`, timestamp and subtype.
4. `CLIoHidInterface` construction was traced through `0x1af9a9fec`,
   `0x1af9b5218`, `0x1af9b52b4`, and `0x1afad5780`; its callback registration
   goes through `0x1afad5ac0` on the motion thread.
5. `openHidDevice` also checks bit 1 of the platform capability mask returned
   by `0x1af977bb4`. That mask comes from a platform-indexed table. The virtual
   board's result has **not** been measured, nor has its optional IMU matching
   constraint. Publishing a HID service does not bypass this gate. If a guest
   still reports unavailable, capture that guest's CoreMotion image/platform
   result before adding any capability repair.

The demo edition allowed inspection but refused assembly export. No Hopper
scripting, interpreter, or generated instruction bytes were added to the repo.

## Verification and manual acceptance

Host transport test: `make -C VPhoneGuestComponents test-gyroscope`. It checks a
binary property-list round trip, invalid types/non-finite values, incomplete
axis dictionaries, clear state, and subscriber interval bounds. The full
`VPhone` scheme validates the packaged signed dylib and vphoned.
The host test also calls the real HID event factory without publishing a host
service, verifying its selector ABI, timestamp, sequence, signed axes and
16.16 quantization. The seven patch model/catalogue suites passed (55 tests),
including default selection, explicit blocking, iOS 18+ and unknown/older-base
gates. These checks do not substitute for the guest acceptance below.

Guest runtime acceptance is delegated to the user; it has **not yet run**:

```sh
vphone-launchpad-cli guest rpc <name> motion.gyroscope.get
vphone-launchpad-cli guest rpc <name> motion.gyroscope.set '{"x":1.25,"y":-2.5,"z":0.125}'
vphone-launchpad-cli guest rpc <name> motion.gyroscope.get
vphone-launchpad-cli guest rpc <name> motion.gyroscope.clear
```

1. Verify `vphone-systemhook.log` records `gyroscope-hook=... result=loaded` for
   backboardd, then `provider_running = true` and a nonzero service ID.
2. Open a foreground app that uses `CMMotionManager`. Confirm `isGyroAvailable`
   and test **both** `startGyroUpdatesToQueue:withHandler:` and polling
   `gyroData` after `startGyroUpdates`. Record rotationRate and timestamps.
3. Set one axis at a time (including negatives), then all three. Compare the
   readings with configured rad/s within 1/65536 quantization; timestamps must
   advance. `provider.configuration` must match the latest RPC and the event
   counter must increase while a client subscribes.
4. Keep two clients subscribed; stop one and verify the other keeps receiving
   samples. Stop both and verify no report timer remains active. Clear while
   subscribed and verify zero rates, then set again without restarting the app.
5. Test app restart, guest restart, and provider recovery after a HID reset.
   Check backboardd crash reports and dispatch failures. Block the patch,
   update the stopped machine, boot, and confirm the dylib stays absent after
   the host's automatic environment sync.

If step 1 passes but step 2 does not, core acceptance remains incomplete. The
HID provider status must not be presented as proof that an app receives gyro
data. Possible next reveal points are the platform mask, IMU match, and service
interval requests in that guest's CoreMotion build.
