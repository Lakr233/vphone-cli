# vphoned HTTP/WebSocket API

## Transport and ownership

`vphoned` listens on guest VSOCK port 1339 with SwiftNIO HTTP/1.1. A WebSocket
upgrade at `/v1/events` uses the same port. `vphone-vm` can expose that byte
stream on a host TCP address. It opens one VSOCK connection per TCP connection
and forwards bytes in both directions; it does not translate HTTP or WebSocket
messages. The host listener is absent unless boot receives `--api-listen
host:port`. Port `0` asks the OS for an available host port and the actual
address is printed after the VM starts. The API is also usable from guest and
host code that connects to VSOCK 1339 directly.

The SwiftPM `VPhoneAPIKit` product is an unentitled HTTP/WebSocket client for
`vphone-ui` and other macOS apps. The separate public `VPhoneVirtualMachineKit` product
exposes `VPhoneAPIProxy` to an app that owns a `VZVirtioSocketDevice`. The
command-line executable remains unentitled and still launches `vphone-vm`.

The guest links IcliKit directly. App registration refresh is available through
`POST /v1/apps/refresh` or the WebSocket method `apps.refresh`. An optional
`directory` selects a bundle directory; omitted, it uses the bootstrap's
`/Applications`. IcliKit verifies registrations by reading them back.
`screen.screenshot` uses IcliKit's native screen capture and returns a base64
JPEG with `mime_type`, `width`, and `height`; the current VM produces 1290×2796.
The host's Save/Copy Screenshot menu decodes this guest image. It omits the
notch and cutout drawn by the host VM window.
`apps.install` accepts IPA and TIPA archives. IcliKit 0.6.8 validates and
extracts the archive, then calls vphone's signer on the temporary app bundle
before IcliKit copies it into a container, registers it, and owns rollback.
`apps.uninstall` delegates removal to IcliKit and requires `force=true`.
`POST /v1/bootstrap/install` (or RPC method `bootstrap.install`) accepts
`{"layout":"rootless"}` or `{"layout":"roothide"}` and installs the latest
published `Lakr233/Irisin` release as the selected bootstrap's initial app.
Rootless uses `/var/jb`. RootHide reuses the sole valid `.jbroot-<16 hex>` under
`/var/containers/Bundle/Application`, or creates
`.jbroot-000114514191980C` when none exists. The selected stem is zero padded
and its final byte carries RootHide's XOR checksum. Missing bootstrap directories are created.
It selects the matching architecture, verifies the release
asset's GitHub SHA-256 digest and Debian control fields, then uses IcliKit to
extract the `.deb` into a temporary directory. It copies the full payload
into the bootstrap, creates Irisin's mobile-owned data directory, registers
the app with IcliKit, and loads the daemon through IcliKit. It also attempts
to start the daemon; a launchd start error is returned as
`service_start_warning` while the installed bootstrap remains available.
On the iOS 26.6.2 RootHide test VM, launchd returned service-configure status
144 during installation, then started `irisind` on demand when Irisin opened
after a reboot.
RootHide's plist gets a physical daemon path and `__Patched`
marker before launchd reads it. This is a manual payload install: no maintainer
script runs. For this minimal vphone bootstrap, vphoned writes a real installed
`firmware` record with the guest iOS version to the selected root's
`Library/dpkg/status`; Irisin's installed list, resolver, and helper then read
the same record. If the status already contains firmware from another
bootstrap, vphoned preserves it. A vphoned-owned record is updated after an
iOS version change when vphoned starts. For RootHide, vphoned also creates
the `.jbroot` loader links in the bootstrap root and standard executable and
library directories. On startup it repairs missing links for an existing
completed installation without replacing links that point elsewhere. These
links let `@loader_path/.jbroot/usr/lib/...` dependencies resolve when a
package manager later installs tools such as `dash`.
The launchd and SystemHook spawn bridges also create a missing `.jbroot`
beside a bootstrap executable just before it starts, covering applications
installed after the initial bootstrap. The fixed links remain necessary for
jobs whose launch path does not pass through either observed spawn bridge.
`POST /v1/bootstrap/firmware` (RPC `bootstrap.firmware`)
repairs the record for a bootstrap already identified by the completion marker
without running another install. The reply includes the tag,
bootstrap path, registration record, and launchd status. A successful bootstrap
writes `/private/var/db/vphoned/bootstrap.json` on the writable data volume;
later requests refuse to bootstrap again while that record describes an installed
bootstrap. Older records beside the vphoned binary are read when no data-volume
record exists. Uninstall writes a tombstone so a legacy record on a read-only
system volume cannot reappear.
The VM window exposes the same operation at Guest > Install Bootstrap…;
choose Rootless or RootHide in the confirmation sheet. The item is enabled
when vphoned advertises `bootstrap_install`. Its sheet polls
`GET /v1/bootstrap/status` (RPC `bootstrap.status`) while installation runs.
The status reports `phase` and, during download, `downloaded_bytes` and
`total_bytes` when the server provides a length. The sheet shows the download
progress, then the installation result without closing.

`GET /v1/bootstrap/inspect` (RPC `bootstrap.inspect`) reports the layout and
path recorded by a completed vphoned installation, or `installed: false`.
`POST /v1/bootstrap/uninstall` (RPC `bootstrap.uninstall`) requires
`{"jbroot":"<path from inspect>","force":true}`. It accepts only the
rootless `/var/jb` directory or a valid RootHide `.jbroot-<16 hex>` directory
recorded by vphoned. A rootless `/var/jb` symlink is accepted only when its
target is a physical directory under `/private/preboot`; the target and link
are both removed. The daemon rejects a changed path and symlinked child
directories. It unloads the bootstrap's launch daemons, unregisters apps in
its `Applications` directory, deletes the bootstrap root, marks the completion
record uninstalled, then schedules a full guest reboot. If cleanup fails, the
installed record remains so the operation can be retried. Irisin's mobile
Documents data outside the bootstrap is retained. Guest > Uninstall Bootstrap…
shows the recorded path
in a destructive confirmation alert before sending the request.

## HTTP and WebSocket contract

JSON resource routes cover device state, apps, input, location, Developer Mode, low power
mode, clipboard, file listing, and keychain. `GET/PUT
/v1/files/content?path=<absolute-guest-path>` transfer bytes with
`application/octet-stream`; upload writes to a temporary file in the same
directory then renames it after all chunks have been written. JSON bodies
have a 1 MiB limit. Binary transfers stream without loading the entire file
into memory.

`GET /v1/device` includes `jailbreak.layout`, `jailbreak.jbroot`, and
`jailbreak.source`. The layout is `roothide`, `rootless`, or `rootful` when
detected. If there is no bootstrap and `/` is read-only, both `layout` and
`jbroot` are JSON `null`; `/` alone is not evidence of a rootful bootstrap.
The daemon checks a loaded RootHide `systemhook.dylib` export and `/var/jb`
at request time so a bootstrap created after daemon startup can be reported.

For raw guest TCP ports, upgrade `GET /v1/ports/<port>` to WebSocket. Each
binary WebSocket message carries an unmodified chunk of the TCP byte stream
in one direction; the server connects only to `127.0.0.1:<port>` inside the
guest. Ports 1 through 65535 are accepted. Ping/pong and close frames retain
normal WebSocket behavior; text frames close the tunnel. A failed guest
connection closes the WebSocket with code 1011. Each tunnel has its own guest
TCP connection and closes it when the WebSocket closes. For example, with
`--api-listen 127.0.0.1:8765`, `ws://127.0.0.1:8765/v1/ports/22` carries
the guest SSH byte stream. An SSH client still needs a local TCP-to-WebSocket
bridge; SSH cannot use a WebSocket URL directly.
WebSocket fragmentation is reassembled before forwarding. On disconnect, the
guest tunnel and the host TCP-to-VSOCK proxy let their final queued write
finish before closing the opposite socket, with a five-second drain limit.

`apps.launch` returns a PID and `frontmost_verified`. IcliKit 0.6.8 checks
RunningBoard's live focal assertion and accepts it only when one real app owns
it. iOS 26.6.2 uses `SuspendableRole-UIFocal`; older systems may use
`Workspace-ForegroundFocal`. The Home screen's widget renderer can also hold
`UIFocal`, so the Kit excludes it. `apps.foreground` reports the Kit's
`verified` and `source` values. If no unique focal app can be confirmed,
a newly started process is reported with `frontmost_verified=false` and a
warning. A failed start or an already running app without foreground
confirmation remains an error.

Upload accepts an optional octal `mode` query parameter (default `644`) and
creates missing parent directories. Download follows file symlinks, matching
the previous file browser behavior. Uploads write to a temporary file and
replace the destination only after the complete request body is written. The
daemon pauses socket reads while disk writes are pending and removes an
unfinished temporary file after a disconnect.

`POST /v1/rpc` accepts `{ "id": "...", "method": "device.snapshot",
"params": {} }`. JSON operations return
`{ "type": "response", "id": "...", "result": { ... } }` or
`{ "type": "response", "id": "...", "error": { "code": "...",
"message": "..." } }`. The WebSocket accepts the same request JSON and sends
the same response shape; requests may complete out of order, so clients
correlate them by `id`. The socket also sends
`{ "type": "event", "event": "...", "data": { ... } }`. The initial event is
`connected`; changes to screen, frontmost app, or low power mode emit
`device.state`, and completed operations emit `operation.completed`. Ping frames
receive pong frames. JSON WebSocket frames are limited to 1 MiB after
fragment reassembly.

SwiftNIO handles parsing, upgrade, masking, and backpressure. IcliKit 0.6.8
owns general device operations. Each HTTP or WebSocket request runs independently
on a concurrent worker queue, so a stalled system service does not block HID,
file browsing, or unrelated requests. The host serializes the input events it
sends so touch and key sequences retain their order. State polling uses its own
worker queue. `power.low_power_mode` uses IcliKit's completion-based powerd
setter and verifies the resulting state. The vphone-specific IPA signing remains
in native Objective-C.
Keychain listings combine IcliKit's accessible Security.framework attributes
with its protected database metadata. They return no value data, and possible
duplicates remain visible because the two sources have no stable join key.
The VM GUI uses HTTP over
VSOCK 1339 directly; host TCP forwarding is opt-in. The former length-prefixed
VSOCK 1337 protocol and duplicate ObjC command handlers have been removed.
The 1338 virtual camera stream remains. At startup, the host compares the
signed daemon hash from `/v1/health`; an update is uploaded through HTTP,
verified by SHA-256, made executable, and activated through launchd restart.
This intentionally breaks compatibility with guests that still have the old
daemon: install a guest image carrying this vphoned build before using the new
host control client.

## Method catalog

Every method is reachable through `POST /v1/rpc` and the WebSocket. The
original methods also have REST routes in `GuestHyperTextHandler.swift`; the
methods added with the host panels are RPC-only. Each area is one file,
`VPhoneDaemon/Daemon/GuestAPI+<Area>.swift`, and each method is a thin call
into the IcliKit function named in parentheses, so IcliKit's source is the
reference for result keys. Methods marked **force** refuse to run unless the
request carries `"force": true`.

| Area | Methods |
| --- | --- |
| Device | `device.snapshot`, `device.info` (snapshot plus network, screen, rotation, brightness, volume, low power, Developer Mode, agent), `device.screen`, `device.network`, `device.ioreg {plane}`, `device.environment`, `device.basebin {archive?}` |
| Display, audio | `display.brightness {value?}`, `display.rotation {orientation?}`, `display.rotation_lock {locked}`, `audio.volume {value?, category?}`, `audio.state` |
| Input | `input.touch`, `input.hid`, `input.button {name}`, `input.key {name}`, `input.type {text, delay_ms?}`, `input.paste {text}`, `input.tap`, `input.double_tap`, `input.long_press`, `input.swipe`, `input.drag {points}`, `input.touch_sequence {events}` — gesture coordinates are screen points |
| UI | `ui.tree` (alias `accessibility.tree`), `ui.element_at`, `ui.tap_element`, `ui.wait`, `ui.wait_gone`, `ui.ocr {languages?, min_confidence?}`, `ui.describe`, `screen.screenshot` |
| Processes | `processes.list {filter?}`, `processes.kill {pid, signal?}` **force**, `memory.jetsam`, `memory.pressure` (only the three kernel memory sysctls, for polling) |
| launchd | `services.list`, `status`, `print`, `dump`, `disabled`, `start`, `enable`, `load`; `services.stop`, `disable`, `remove`, `signal`, `unload` **force**; `launchd.getenv`, `setenv`, `unsetenv` |
| Logs | `logs.syslog {seconds, process?, level?, max_lines?}` (a bounded capture of at most 60 s), `logs.crashes {bundle_id?}`, `logs.crash {path}` |
| Network, security | `network.capture {seconds, interface?, filter?}` (writes a pcap in the guest scratch directory and returns its path), `security.ssl_killswitch` |
| Apps | `apps.list`, `search`, `refresh`, `launch`, `terminate`, `foreground`, `open_url`, `install`, `info`, `binary`, `data_dir`, `url_schemes`, `handlers`, `registration`, `register`, `network_policy {repair?}`; `apps.uninstall`, `unregister`, `unregister_dir` **force** |
| System | `system.uicache`, `system.system_apps {visible?}`, `system.respring` **force**, `system.reboot {userspace?}` **force**, `developer_mode.status`, `developer_mode.enable`, `power.low_power_mode`, `diagnostics.self_test` |
| Files | `files.list`, `mkdir`, `remove`, `rename`, `read {binary?, limit?}`, `write`, `find`, `copy`, `symlink`, `chmod`, `chown`, `plist`, `plist_set {value \| remove}` |
| Preferences, clipboard, location | `settings.get/set/delete`, `clipboard.get/set/clear`, `location.set/clear/current` |
| Keychain | `keychain.list {class?}`, `add`, `delete`, `get`, `update`, `database` |
| Packages (read-only) | `packages.list`, `status`, `info {path}`, `compare`, `tweaks`, `repos` |
| Bootstrap | `bootstrap.install {layout}`, `bootstrap.status`, `bootstrap.inspect`, `bootstrap.uninstall {jbroot, force}`, `bootstrap.firmware` (see above) |

`processes.list` joins icli's kernel process list with `proc_pid_rusage`
footprint, resident size and CPU time (`VPhoneDaemon/Native/vphoned_process.m`),
the jetsam priority band and limit, and the RunningBoard bundle identifier.
Account passwords, boot logo rendering and package installation, removal and
repository changes are deliberately not exposed. `/v1/health` lists the new
areas in `capabilities` (`device_info`, `display`, `audio`, `input_gestures`,
`ui_inspection`, `processes`, `services`, `logs`, `network_capture`,
`app_details`, `system_control`, `file_tools`, `packages`) so a host can hide
panels an older agent cannot serve. icli failures reach the caller with
icli's own error `code` (`failed`, `unavailable`, `device_locked`, …) and
message.

## Connection failure behavior

A dropped HTTP or WebSocket connection closes only that request channel. The
guest launchd plist starts a small vphoned proxy. It uses `posix_spawn` to
start the same signed executable with `--io`, then waits for and reaps that
worker. The worker owns VSOCK 1338 and 1339 and all API state. The proxy
restarts an unexpectedly exited worker with bounded backoff, and forwards
shutdown to it. A pipe makes the worker exit if launchd kills the proxy, so
the old worker cannot retain the ports after launchd starts a replacement.
The proxy never initializes NIO, IcliKit, or the camera server under its
6 MB per-process Jetsam limit. A successful `agent.apply_update` worker exit
makes the proxy exit so launchd can restart the updated cached binary. If a
cached worker fails before binding, the bundled-binary fallback remains in
effect. On a 26.6.2 VM, the proxy's physical footprint stayed near 1.4 MB
through 30 health requests and six app listings; the worker served those
requests without a PID change. Killing the proxy caused the worker to leave
and launchd to start one new proxy/worker pair. The worker's Jetsam snapshot
reported no per-process limit.

Host socket writes use `F_SETNOSIGPIPE`, so a guest disconnect becomes
an ordinary error instead of terminating `vphone-vm`. The host HTTP client
also times out stalled reads and writes. Camera frames use a duplicated
descriptor for each in-flight send; the original descriptor remains owned by
`VZVirtioSocketConnection` and is never manually closed. Camera sends and
local control socket operations have bounded timeouts. The optional TCP
proxy uses NIO channels and closes the paired channel when either side ends.

## Usage

```sh
vphone-cli vm launch <name> --api-listen 127.0.0.1:8765
curl http://127.0.0.1:8765/v1/health
```

```swift
import VPhoneAPIKit

let client = VPhoneAPIClient(baseURL: URL(string: "http://127.0.0.1:8765")!)
let device = try await client.call("device.snapshot")
let apps = try await client.call("apps.refresh")
let socket = try client.openWebSocket()
try await socket.send("input.touch", params: [
    "phase": .string("down"), "x": .number(0.5), "y": .number(0.5),
])
let message = try await socket.next()
```

The listener accepts the address specified by the user. For local-only use,
pass `127.0.0.1` or `[::1]`. The API currently has no authentication layer;
exposing it beyond a trusted host requires the caller's own access control.
