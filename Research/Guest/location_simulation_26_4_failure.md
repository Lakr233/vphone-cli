# iOS 26.4 VM location simulation failure

> **Superseded (2026-09-28): the app hook is gone.** `libvlocation.dylib` and
> its SystemHook load were removed, and `location.set` / `location.clear` /
> `location.current` are IcliKit's `simulateLocation` / `clearSimulatedLocation`
> / `currentLocation` again, which prove a request by reading the fix back (see
> `Research/vphoned_http_api.md`). The 2.0.4 bundle used below was the first
> with the former EXP patches in the JB flow (228326d), including the
> `hv_vmm_present` concealment. With it on, bluetoothd crash-loops and locationd
> blocks on the throttled Bluetooth service (issue #438), which fits the
> `invalid location` / `invalid latest selected hypothesis` fusion failure
> recorded here. `standard` now leaves the concealment and the iPhone17,3
> identity rewrites off; only the camera patches remain from EXP. Re-run the
> reproduction below on a VM restored with `standard` to confirm.

## Host location never reached the guest (2026-10-07)

Every VM log that recorded Sync Host Location had the host working and the
guest refusing: VPhoneLocation.app was authorized and wrote fixes, vphone-vm
forwarded them, and every `location.set` failed with `Location Services are
turned off` (issue596-ip18, unlocktest-iphone, nettest-01, discard-a/b). vphone-vm
only printed the error and the menu checkmark stayed on. Three separate causes
turned up on new `standard` iPhone17,3 iOS 27.0 (24A435) VMs.

**The guest's Location Services switch is off.** Setup Assistant's Location
Services pane turns it on, so a guest whose Setup Assistant was skipped, or not
yet finished, has it off and locationd gives no client a location, a simulated
one included. `location.set` and `location.current` fail with the code `location_services_off`, the VM
window says so once, and vphone-vm offers the last Mac fix again every 10 s.
Turning the switch on in the guest's Settings brought the Mac's coordinate in
6 s later with the Mac standing still (`fresh` and `simulated` true), and Maps
drew its blue dot there. vphoned turns the switch on too, through `location.services {enabled:true}`
(`+[CLLocationManager setLocationServicesEnabled:]` with
`com.apple.locationd.authorizeapplications`, verified on 2026-10-07; the call
does nothing without the entitlement). On a cloned iOS 27.0 guest (2026-11-07)
`location.services` read `{"enabled":true}`; `{enabled:false}` returned
`{"enabled":false}` and `location.set` and `location.current` then failed with
`location_services_off`; `{enabled:true}` (twice) returned `{"enabled":true}`
and `location.set` answered `simulating: true`, `simulated: true`. A
non-Boolean `enabled` is ignored and the call reads, as for
`power.low_power_mode`.

**The Mac's locationd turned the helper away.** It keys VPhoneLocation.app by
bundle identifier and stores the code requirement the first client registered
with; an ad hoc signature's implicit requirement is its cdhash. While a helper
with the stored requirement runs, a helper from another build is refused
silently (`#registration stored requirement is not equal to this new
requirement`, then `#registration can't continue`) and never gets an
authorization status, so it sends nothing. Two machines on different bundles
could not both sync, and a helper of a new build was refused as long as an old
one ran. StageBundle.sh now signs the helper with `designated => identifier
"com.vphone.bundle.location"`; locationd accepted that requirement once no
cdhash-signed helper was running, and the helper went from `NotDetermined` to
`AuthorizedAlways` without a prompt.

**locationd can deadlock as it starts.** It was first seen on headless starts,
where the VM's locationd hung within a second on every boot tried; more boots
showed windowed starts hang too, less often. Every CoreLocation client then
waits on `com.apple.locationd.synchronous` and location RPCs time out after
120 s. vphoned now restarts such a locationd; see
`Research/Guest/locationd_startup_deadlock.md`.

Sync Host Location is now a machine setting, `syncsHostLocation` in
`config.plist`, off when absent, in a window and headless alike (headless used
to start it unconditionally).

## Reproduction (2026-09-25)

The running `26.4` VM uses the `jb` firmware variant and iOS 26.4.0. Its
guest agent is the 2.0.4 bundle's `vphoned`. Location Services are enabled,
and Maps has While Using permission. The VM has no working Wi-Fi switch.

1. Open Maps and request the current position. The button spins without a blue
   dot.
2. Send `PUT /v1/location` with latitude `35.681236` and longitude
   `139.767125`. Most requests fail after five seconds with `no location
   within 5 s`; a single earlier request returned a fresh simulated reading,
   but Maps still did not obtain a position.
3. Set the same coordinate through Xcode's independent path:
   `xcrun devicectl device simulate location coordinate --device <VM UDID>
   --latitude 35.681236 --longitude 139.767125`. This command reports
   success, while `GET /v1/location` still times out and Maps still spins.
4. Clear the Xcode simulation with `xcrun devicectl device simulate location
   clear --device <VM UDID>`.

`locationd` logs `received daemon-side request to start location simulation`
and emits `@ClxSimulated, Fix` every second. At the same time it repeatedly
logs `LCOutputBuffer,getLatestDaemonLocation,invalid location` and
`#fusion,getLatestPredictedFusedLocation,invalid latest selected hypothesis`.
The TimeZone system-service reader is authorized. The guest agent's
`com.apple.locationd.simulation` entitlement is present. Developer Mode is
enabled. These observations put the failure after simulation request delivery
and before a usable CoreLocation result reaches clients.

## Probes already ruled out

- Removing IcliKit's clear-on-readback-failure kept the simulation active, but
  did not produce a location for Maps or the authorized reader.
- Appending two identical points with timestamps one second apart did not
  produce a location.
- The guest's `CLSimulationManager` responds to
  `setSimulatedWifiPower:` and `startWifiSimulation`. Calling both before
  starting location simulation did not produce a location.
- A `locationd` process exit seen during testing coincided with restoring a
  temporary guest agent. The restarted original agent reproduced the failure;
  the exit is not evidence of the root cause.

These observations predate the application hook below. No Apple binary patch
was needed for the workaround.

## Separate host-sync issue

The host `CLLocationManager` returned `kCLErrorDomain` code 1 while its
authorization status was Not Determined. The menu's Sync Host Location
checkmark only records the requested mode; it does not establish that macOS
has supplied a coordinate or that the guest accepted one. This does not
explain preset failure, which also reproduces through the HTTP API and
`devicectl`.

**Cause and fix (2026-09-30).** locationd never answers a client whose
executable sits in a generic bundle. From `VPhone.bundle/Contents/MacOS`,
`requestWhenInUseAuthorization` neither prompts nor changes the status, and the
usage descriptions in the bundle's Info.plist are never read. A probe showed the
same for every `.bundle` layout (BNDL, APPL, with or without
`CFBundleExecutable`, with an embedded `__info_plist`); only an executable
inside an `.app`, or a bare one outside any bundle, was prompted. vphone-vm now
starts `Contents/Helpers/VPhoneLocation.app` (`vphone-location`, an
`LSUIElement` app) when Sync Host Location is on. The helper asks for
permission with its own localized InfoPlist.strings and writes one JSON line
per authorization change or fix; it exits when vphone-vm closes its stdin.

## Application-level workaround (2026-09-25)

`libvlocation.dylib` is loaded by SystemHook into newly launched apps. It
overrides `CLLocationManager` updates for authorized clients while vphoned's
location state file exists. The HTTP `location.set` endpoint publishes that
file atomically and returns promptly; the locationd simulation request is
best effort. Clearing removes the override. This route intentionally bypasses
the iOS 26.4 locationd fusion problem described above.

Live verification on the 26.4 VM moved Maps' blue dot from Tokyo Station to
Apple Park. A subsequent Maps launch without a test environment variable
loaded `/usr/lib/libvlocation.dylib` through SystemHook and showed the blue dot
near Apple Park. This confirms delivery to Maps, beyond an API success reply.
