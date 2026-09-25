# vphoned HTTP/WebSocket API

## Transport and ownership

`vphoned` listens on guest VSOCK port 1339 with SwiftNIO HTTP/1.1. A WebSocket
upgrade at `/v1/events` uses the same port. `vphone-vm` can expose that byte
stream on a host TCP address. After it admits a connection's first request
head with the API token (see [Access control](#access-control)), it opens one
VSOCK connection for that TCP connection and forwards bytes in both
directions; it does not translate HTTP or WebSocket messages. The host
listener is absent unless boot receives `--api-listen host:port`. Port `0`
asks the OS for an available host port and the actual address is printed
after the VM starts. The API is also usable from guest and host code that
connects to VSOCK 1339 directly.

## Access control

vphoned runs as root, and the API can read and write any guest file, list
the keychain and load launch daemons. It cannot tell a proxied connection
from the VM's own VSOCK client, so the host proxy and vphoned each apply a
check.

**Token (host proxy).** `vphone-vm` creates a token when the proxy starts: 32
bytes from `SecRandomCopyBytes`, in hex, new for each launch. It prints the
token after the API address:

```text
[api] HTTP/WebSocket API: http://127.0.0.1:8765
[api] token: 3f9c…
[api] send it as: Authorization: Bearer 3f9c…
```

To use a fixed token, set `VPHONE_API_TOKEN` before launching.
`vphone-cli vm launch` passes its environment through to `vphone-vm`. The
value must be 16 to 256 characters of `A-Z a-z 0-9 - . _ ~`; any other
non-empty value stops the launch. The proxy reads at most 16 KiB of the
first request head, waiting up to 10 seconds, and accepts the token in any
of these forms:

- `Authorization: Bearer <token>`, for HTTP and for WebSocket clients that
  can set headers
- a `token=<token>` query item, such as `ws://127.0.0.1:8765/v1/events?token=<token>`
- a `Sec-WebSocket-Protocol` value `vphone-token.<token>`; vphoned selects
  that protocol in its 101 reply

The comparison runs in constant time. A missing or wrong token, an oversized
head, or a malformed head gets `401 Unauthorized` and the connection closes
before any guest connection opens. A malformed head includes bare CR or LF,
control bytes, folded lines, or a space before a header colon. On success the
proxy removes the `Authorization` header and the `token` query item, so
`/v1/events?token=…` reaches vphoned as `/v1/events`. It forwards every other
byte unchanged. The token covers the whole TCP connection. vphoned closes
each HTTP connection after one reply, and a WebSocket stays on the connection
it was admitted on. A listen address other than loopback prints a warning.
The proxy then sends `Host: localhost` in place of the client's value, so
vphoned's Host check still passes. `VPhoneAPIClient` sends the token as a
bearer header on HTTP and as the `token` query item on WebSocket. It takes
the token from its `token:` argument or from `VPHONE_API_TOKEN`.

**Browser requests (vphoned).** Browsers apply no CORS to WebSockets, and a
page can send a form POST to any address. vphoned therefore refuses a request
that carries an `Origin` header, or a `Host` whose name is not `vphoned`,
`localhost`, `127.0.0.1` or `::1`. It ignores the port, and it allows a
request with no `Host`. The refusal is `403`, for WebSocket upgrades too. The
check runs before an upload to `PUT /v1/files/content` or
`/v1/clipboard/image` stages a file. Every `POST` must send `Content-Type:
application/json` or it gets `415`. That closes the no-preflight form and
`text/plain` routes. The VM's own client sends `Host: vphoned` and a JSON
content type, and `VPhoneAPIClient` sends the loopback address it connects
to. Neither sends `Origin`. GET routes only read. vphoned ignores a GET
request body, so `GET /v1/low-power-mode` cannot turn low power mode on or
off; use `PUT` with `{"enabled": true}`.

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
An optional `package_path` selects a guest-uploaded Irisin `.deb` instead.
The path must be `/var/root/Library/Caches/vphoned-irisin-<UUID>.deb`; vphoned
opens it without following symlinks, requires a regular file of at most 64 MiB,
and validates the Debian package name, architecture, app version, executables,
and launchd plist before installing. The Guest menu's Option alternate opens
a file picker, uploads the selected package, and chooses the layout. The default
menu item retains the verified latest-release download.
Rootless uses `/var/jb`. RootHide reuses the sole valid `.jbroot-<16 hex>` under
`/var/containers/Bundle/Application`, or creates
`.jbroot-000114514191980C` when none exists. The selected stem is zero padded
and its final byte carries RootHide's XOR checksum. Missing bootstrap directories are created.
It selects the matching architecture, verifies the release
asset's GitHub SHA-256 digest and Debian control fields, then uses IcliKit to
extract the `.deb` into a temporary directory. It copies the full payload
into the bootstrap, creates Irisin's mobile-owned data directory, registers
the app with IcliKit, and loads the daemon through IcliKit. mobile owns
`/var/mobile/Documents`, so vphoned opens it and `wiki.qaq.irisin` without
following a symlink. It refuses an entry that is not a real directory and sets
the owner and mode through the directory descriptor. It also attempts
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

`GET /v1/bootstrap/inspect` (RPC `bootstrap.inspect`) reports `roots`, the
rootless `/var/jb` and all valid RootHide `.jbroot-<16 hex>` environments found
on the guest, including the completed vphoned root if it is now missing.
`POST /v1/bootstrap/uninstall` (RPC `bootstrap.uninstall`) requires
`{"roots":["<paths from inspect>"],"force":true}` and removes all the listed
environments in one operation. The paths must still match the current
inspection result. A single `jbroot` is accepted for older clients only when
it is the only environment. A rootless `/var/jb` symlink is accepted only when its
target is a physical directory under `/private/preboot`; the target and link
are both removed. The daemon rejects a changed path and symlinked child
directories. It unloads each bootstrap's launch daemons, unregisters its apps,
deletes both rootless and RootHide roots, marks the completion record uninstalled,
then schedules a full guest reboot. `"reboot":false` skips the reboot; holding
Option on the Guest menu's uninstall item selects this mode. If cleanup fails, the
installed record remains so the operation can be retried. Irisin's mobile
Documents data outside the bootstrap is retained. Guest > Uninstall Bootstrap…
shows every path in a destructive confirmation alert before sending the request.

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
`--api-listen 127.0.0.1:8765`, `ws://127.0.0.1:8765/v1/ports/22?token=<token>`
carries the guest SSH byte stream. An SSH client still needs a local TCP-to-WebSocket
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
The 1338 virtual camera stream remains. mobile owns
`/var/mobile/Media/SimulatedCamera`. vphoned opens that directory, its
`vphone-vcam-frame.shm` frame file and its `vphone-vcam.log` log with
`openat` and `O_NOFOLLOW`. It opens the log once at startup. An entry that
is not a root-owned regular file with one link is removed and created again
exclusively. Only after that does vphoned resize, chmod or map it.
At startup, the host compares the signed daemon hash from `/v1/health`; an update is uploaded through HTTP,
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
| Environment | `environment.status` (SHA-256 of each vphone library in `/usr/lib`, or null when absent, plus the staging directory), `environment.install {libraries: [{name, sha256}]}` (see below) |

`processes.list` joins icli's kernel process list with `proc_pid_rusage`
footprint, resident size and CPU time (`VPhoneDaemon/Native/vphoned_process.m`),
the jetsam priority band and limit, and the RunningBoard bundle identifier.
Account passwords, boot logo rendering and package installation, removal and
repository changes are deliberately not exposed. `/v1/health` lists the new
areas in `capabilities` (`device_info`, `display`, `audio`, `input_gestures`,
`ui_inspection`, `processes`, `services`, `logs`, `network_capture`,
`app_details`, `system_control`, `file_tools`, `packages`, `environment_update`) so a host can hide
panels an older agent cannot serve. icli failures reach the caller with
icli's own error `code` (`failed`, `unavailable`, `device_locked`, …) and
message.

The environment update keeps `launchdhook-vphone.dylib`,
`SystemHook-vphone.dylib`, `libvcamcaptured.dylib` and `libcamfix.dylib` in
`/usr/lib` in step with the host bundle. After each connection the VM
process compares the guest's hashes with `Contents/Resources/guest-resources`,
uploads the libraries that differ to the staging directory
(`/var/root/Library/Caches/vphone-environment`) and calls
`environment.install`. vphoned accepts only those four names and checks each
SHA-256. When `/` is mounted read-only it runs `/sbin/mount -u -w /`, copies
each library beside its destination, renames it into place with mode 0755
and owner root, and runs `/sbin/mount -u -r /` again; jailbreak detection
reads a writable root as a rootful layout. It stops a running
`cameracaptured` when a camera hook or SystemHook changed, so the next
camera client loads the new hook. The result lists `installed`,
`restarted_pids` and `reboot_required`, which is true when the launchd hook
changed: launchd keeps the copy it mapped at boot.

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
effect. Before it execs `/var/root/Library/Caches/vphoned`, the proxy
opens the binary and its `vphoned.api-v2` marker without following a link.
The two files and their directory must be root-owned and not writable by
group or other. The proxy hashes the descriptor it opened and execs the path
only while it still names the same device and inode. The guest has no
`fexecve`. Anything else leaves the bundled binary running. On a 26.6.2 VM, the proxy's physical footprint stayed near 1.4 MB
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
# copy the value from the "[api] token:" line, or set VPHONE_API_TOKEN first
TOKEN=...
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"method":"device.snapshot","params":{}}' http://127.0.0.1:8765/v1/rpc
websocat "ws://127.0.0.1:8765/v1/events?token=$TOKEN"
```

```swift
import VPhoneAPIKit

let client = VPhoneAPIClient(
    baseURL: URL(string: "http://127.0.0.1:8765")!,
    token: token, // or nil to read VPHONE_API_TOKEN
)
let device = try await client.call("device.snapshot")
let apps = try await client.call("apps.refresh")
let socket = try client.openWebSocket()
try await socket.send("input.touch", params: [
    "phase": .string("down"), "x": .number(0.5), "y": .number(0.5),
])
let message = try await socket.next()
```

The listener accepts the address specified by the user. For local-only use,
pass `127.0.0.1` or `[::1]`. Any other address prints a warning: every machine
that can reach it needs only the token, which travels in clear text over
plain HTTP, so use it only on a trusted network.
