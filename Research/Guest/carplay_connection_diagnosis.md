# CarPlay connection investigation — 2026-10-29

## Reproducing the Siri/CarPlay service repair

Restoring CarKit and Siri is an important part of the working configuration,
separate from the external-digitizer coordinate fix. The observed sequence was:
restore carkitd, fully restart the Mac clients, then restore Siri jobs to obtain
working CarPlay UI. A discoverable iPhone alone did not establish a functioning
session. This does not establish working Siri AI, online account attestation or
the smallest possible service dependency set.

`carplay-service-allow.json` records carkitd and the ten Siri jobs enabled during
the successful investigation. Keep it separate from the 21 services restored
for the later Apple Intelligence experiment. It is a tested configuration set,
not a proposed unconditional global trimming policy or a proven minimal list.

To prepare an opt-in repair for an existing service profile, from the repository
root (replace the machine name):

```sh
machine='YOUR_MACHINE'
vphone-launchpad-cli guest rpc "$machine" services.profile '{}' > profile-before.json
jq -e --slurpfile keep Research/Guest/carplay-service-allow.json '
  .result.record as $record |
  if $record == null then error("No recorded profile; inspect services.profile first")
  else {
    profile: $record.profile,
    groups: $record.groups,
    allow: ((($record.allow // []) + $keep[0]) | unique),
    force: true
  } end
' profile-before.json > carplay-profile.json
```

Inspect the generated request before applying it. It retains the profile, groups
and all existing exceptions; it adds only the recorded CarPlay/Siri exceptions.
Applying a service profile changes guest launchd overrides:

```sh
vphone-launchpad-cli guest rpc "$machine" services.profile.apply "$(cat carplay-profile.json)"
```

Check the reply's `failed` array, restart the guest cleanly, then fully quit and
reopen CarPlay Simulator and reconnect. Query `services.status` for carkitd and
the Siri jobs; jobs may be on demand, so enabled/loaded is distinct from running.
Retain `profile-before.json` locally for rollback; do not commit guest dumps.
The profile API only owns its own overrides, so unrelated manually disabled
jobs need separate diagnosis. No firmware download or host security change is
part of this repair.

Upstream review should decide whether to keep these jobs by default, split
CarPlay/Siri into optional trimming groups, or expose an explicit compatibility
option. This collection documents reproduction and leaves that product-policy
decision open rather than silently changing defaults for every guest.

## Original investigation

Target: iPhone-Duo, iPhone19,4 / iOS 27.1 24A94425 / cloudOS 26.4
23E5207q. Local bundle 2.14.0-local.77724db8.

The slim guest profile disabled com.apple.carkitd. The standalone Simulator's
initial attempt successfully paired through AMDevice but failed its
AMDeviceSecureStartService connection to port 50100 with ECONNREFUSED /
0xe8000065. CarKit was restored by adding com.apple.carkitd to the profile's
allow list, preserving the six Store/account exceptions and all groups.
Loading its original LaunchDaemon plist and starting the job succeeded;
PID 523 remained running, and no related crash report was found.

Subsequent attempts were logged by DeviceHub, including the user's retry at
18:36:21. CreateServiceSocketActionDeclaration failed with CoreDeviceError
1001, missing com.apple.dt.servicesocket.create while requesting
com.apple.carkit.remote-iap.service. The standalone process logged no new
session attempt during this period. This does not establish which window the
user was operating or that the standalone app forwards to DeviceHub.

A fresh read through devicectl device info details at approximately 18:37
reported ddiServicesAvailable=true and advertised Create Service Socket
(com.apple.dt.servicesocket.create). The DDI contents exist at
/System/Developer. This contradicts the earlier operation's missing-capability
view and suggests cached discovery state. Full restart of the Mac clients,
then another connection attempt, remains to be tested. No need for a new IPSW
or restoration has been established. UI inspection of the standalone app
repeatedly timed out; no settings were changed in that app.

## Working connection and external touch rotation

The user confirmed CarPlay connected after fully restarting the Mac clients.
Siri's disabled launch jobs were subsequently allowed in the service profile
and loaded; the user confirmed CarPlay UI worked.

CarPlay then showed rotated/swapped touch coordinates while the Duo was open.
The user confirmed folding the Duo closed corrected CarPlay touch. The
FoldDisplay direct-touch hook applied `(x,y) -> (1-y,x)` to every digitizer
whenever the inner panel was lit, including external display digitizers.
The local fix consults the original digitizer-display UUID resolver and only
rotates an empty UUID, matching the existing built-in digitizer rerouting
condition. A nonempty external display UUID keeps its coordinate space.
Deployed as `2.14.0-local.e1ece920`, preserving the inner 120 Hz and
scaled-window touch fixes. The Release build, bundle admission, installation
preflight and guest boot passed. Siri/CarKit profile exceptions persisted.
After restart, the user confirmed CarPlay touch appeared to work with the
Duo open. The VM was left running in the open posture.
