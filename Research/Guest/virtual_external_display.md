# Virtual external monitor prototype (2026-10-29)

Scope: one optional external monitor on the existing iPhone-Duo guest. Only
1920x1080 and 3840x2160 are accepted. No test app, firmware download, host
security change or additional paravirtual GPU port is involved.

The existing FoldDisplay injection prepares two named, disabled, untagged
`CAWindowServerVirtualDisplay` objects during backboardd display detection,
before SpringBoard starts. An explicit request enables only the selected slot;
disconnect disables both without destroying their stable identities.
Named CADisplay overrides classify the selected display as
wireless (type 2), external, cloning-capable, at 1x for 1080p and 2x for 4K.
The render display receives the runtime-resolved AirPlay connection tag, which
gives ordinary clients a native `AirPlay` display identity.
After configuration, SpringBoard refreshes the existing external CADisplay
objects with their native `update` method, inactive slot first and active slot
on the next main-queue turn, so existing monitor observers see reconnections.
SpringBoard and applications choose their native mirroring/external-scene
behavior; the host does not substitute a copy of the phone's screenshot.
The existing Duo hooks now match the recorded inner display identity rather
than every non-Main display, including status-bar provider and idiom handling.

Configuration uses an atomic request plist, Darwin notification, and a matching
nonce in the backboardd response. A stale request is not applied at boot.
`display.external.configure {enabled,width?,height?}` waits up to five seconds
for acknowledgement. `display.external.status` returns component state;
`display.external.frame` captures only the named external display via the
existing CARenderServerRenderDisplay/IOSurface mechanism and encodes a JPEG.
The display component is currently installed only for the Duo, alongside the
existing FoldDisplay support; other products are outside this prototype.

Device → External Display offers Connect 1080p, Connect 4K, and Disconnect.
The host preview window requests one frame at a time, targets the monitor's
60 Hz refresh, and cannot build a queue of stale frames. Actual presentation
rate depends on guest rendering, JPEG encoding, transfer, and host decoding;
this is not a native VZ scanout. Closing the preview requests disconnection.
The preview currently carries output only, not external pointer/touch input.

Runtime validation and any classification changes are recorded below.

First runtime: the render server created both requested resolutions and the
host preview opened, but output was black. Broadcasts was foreground and is
known by its author (the user) to support external displays. FBSDisplayMonitor
showed the monitor's source disconnected with no raw configuration; CADisplay
tag was zero. This matches the documented FrontBoard source gate in
`iphone_duo_bringup.md`: non-always-connected sources with tag zero lose their
raw configuration. A local probe confirmed the initializer's supported keys
contain geometry/timing/pixel-format options, not a display-type override.
The correction reuses the existing guest-resolved unknown connection tag
before enabling the display. Runtime publication results follow below.

The unknown tag restored the raw configuration but left ordinary clients
with a disconnected Unknown identity. A separate diagnostic process then
constructed FBSDisplayConfigurations with isolated CADisplay getter overrides:
for native virtual type 3, tag 4 produced AirPlay[9-1], tag 65536 produced
Unknown[9-1], and tag 32 produced Car[9-1]. Types 1 and 2 did not change these
tag-derived roles. The next build therefore resolves the `AirPlay` tag by name
through NSStringFromBKSDisplayTags, and uses the wireless/external adapter.
That intermediate implementation removed the display after disabling it;
the final stable-slot implementation below retains both render objects.
This changes guest display classification only; no network AirPlay receiver,
Apple Account, pairing, or host security setting is added.

The AirPlay tag did produce a connected source in newly initialized FBS
monitors, including one inspected inside Broadcasts through its existing
Xcode debugger. Broadcasts still had only its normal application scene;
UIScreen.screens contained the cover and inner panel, with no external screen.
The installed app's manifest declares ExternalDisplay and its preference is
at the enabled default. airplayd, replayd and mediaremoted were enabled and
running; avconferenced was enabled/loaded and idle. None of those jobs was
trimmed. The standalone unentitled scene-count probe returned zero despite
Xcode proving one app scene; do not use that count as authoritative evidence.

A read-only SpringBoard snapshot exposed the inventory boundary: its existing
FBDisplayManager had only sources 1–7, even after the newly created 4K monitor
was visible to new monitors. No external root scene existed. This matches the
historic render-display bring-up notes: a newly initialized monitor sees late
render objects, while the existing SpringBoard monitor misses their discovery.

The next implementation declares two disabled, untagged software render nodes
(1080p and 4K) during backboardd's display detection, after the inner node and
before SpringBoard starts. Only the chosen node receives the AirPlay connection
tag and enabled state. Disconnect clears its tag and disables it; it does not
destroy the stable render object. This keeps a single connected external
monitor while allowing both supported resolutions through native connection
changes. Captures use the selected node's exact name from component status.
`display.external.diagnostics` snapshots SpringBoard's monitor, root scenes,
scene manager and relevant policy metadata without changing them. Its initial
one-second wait was shorter than first-use snapshot generation; the wait is
now five seconds. Snapshot files remain under the existing guest cache folder.

Stable-slot runtime (d92ee395): the first 4K connection produced a native
SBUIWindowSceneSessionRoleNonInteractiveDisplay root and Broadcasts' actual
external artwork/title UI. The user confirmed seeing the external display;
the captured image is 3840x2160. Native disconnect removed the external root
and marked both sources disconnected. Unsupported 1280x720 was rejected while
leaving the active 4K configuration unchanged.

Reconnection exposed a cache boundary: CADisplay in a fresh client showed the
requested AirPlay tag, but SpringBoard's existing sources stayed disconnected.
The next build explicitly updates the two existing external CADisplay objects
in SpringBoard after a configure notification. `-[CADisplay update]` is verified
as v16@0:8; it refreshes those objects and their native KVO observers. Other
displays and the cached object array are untouched. The inactive slot is updated
first and the active slot on the next main-queue turn. Both slots are explicitly
untagged/disabled before choosing the active one, and initialization explicitly
sets tag zero. This replaces reliance on hardware-driven display-cache refresh
that these virtual render objects do not provide.

Final validation (`2.14.0-local.b0297e92`): boot status was disabled. Broadcasts
produced its native external artwork/title UI at 1920x1080, switched live to
3840x2160, and produced the same native UI after disconnect/reconnect at 4K.
SpringBoard diagnostics contained zero external root scenes while disconnected
and one after reconnect. The 4K native configuration uses 1920x1080 points at
2x. Captures and diagnostics are retained in the workspace's
`.vphone-setup/external-display/final-*` files. The user confirmed visible
external output. No app source changes, test app, or service untrimming was
needed for this fix.
