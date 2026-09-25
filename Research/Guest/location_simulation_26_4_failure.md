# iOS 26.4 VM location simulation failure

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
