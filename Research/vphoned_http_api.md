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
and launchd plist before installing. The Apps menu's Option alternate opens
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
package manager later installs tools such as `dash`. It then links every
bootstrap directory that holds a Mach-O file, and repeats that walk one
second after the root's `Library/dpkg` changes, so a package installed later
by Irisin, apt or dpkg is linked without a reboot.
The launchd and SystemHook spawn bridges also create a missing `.jbroot`
beside a bootstrap executable and its in-root dependencies just before it
starts, when the spawning process may write there. See
`Research/roothide_loader_links.md`.
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
Option on the Apps menu's uninstall item selects this mode. If cleanup fails, the
installed record remains so the operation can be retried. Irisin's mobile
Documents data outside the bootstrap is retained. Apps > Uninstall Bootstrap…
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

SwiftNIO handles parsing, upgrade, masking, and backpressure. IcliKit 0.7.0
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
| Display, audio | `display.brightness {value?}`, `display.rotation {orientation?}`, `display.orientation` (`{degrees, source}`: SpringBoard's interface orientation without a screen capture, for polling; capability `display_orientation`), `display.rotation_lock {locked}`, `display.auto_lock` (`{auto_lock_seconds, never, lock_screen_minimum_seconds}`: Auto-Lock and the Lock Screen timeout vphoned keeps in step with it, see below; capability `display_auto_lock`), `screen.unlock {passcode?, timeout?}` (`{locked, screen_off, was_locked, was_screen_off}`: the display on and the Lock Screen passed, see below; capability `screen_unlock`), `audio.volume {value?, category?}`, `audio.state` |
| Input | `input.touch`, `input.hid`, `input.button {name}`, `input.key {name}`, `input.type {text, delay_ms?}`, `input.paste {text}`, `input.tap`, `input.double_tap`, `input.long_press`, `input.swipe`, `input.drag {points}`, `input.touch_sequence {events}` — gesture coordinates are screen points |
| UI | `ui.tree` (alias `accessibility.tree`), `ui.element_at`, `ui.tap_element`, `ui.wait`, `ui.wait_gone`, `ui.ocr {languages?, min_confidence?}`, `ui.describe`, `screen.screenshot` |
| Processes | `processes.list {filter?}`, `processes.kill {pid, signal?}` **force**, `memory.jetsam`, `memory.pressure` (only the three kernel memory sysctls, for polling) |
| launchd | `services.list`, `status`, `print`, `dump`, `disabled`, `start`, `enable`, `load`; `services.stop`, `disable`, `remove`, `signal`, `unload` **force**; `launchd.getenv`, `setenv`, `unsetenv` |
| Logs | `logs.syslog {seconds, process?, level?, max_lines?}` (a bounded capture of at most 60 s), `logs.crashes {bundle_id?}`, `logs.crash {path}` |
| Darwin notifications | `notify.post {name, state?}` (`postDarwinNotification`; `state` is a UInt64, as a number or a decimal string, stored before the post), `notify.state {name}` (`darwinNotificationState`) |
| Network, security | `network.capture {seconds, interface?, filter?}` (writes a pcap in the guest scratch directory and returns its path), `network.ipv4.get {interface?}`, `network.ipv4.set {interface?, method, address?, subnet_mask?, router?, dns?}`, `network.hostname.get`, `network.hostname.set {local_host_name?}`, `network.static_names.get`, `network.static_names.set {entries}`, `network.resolve {host, family?, port?, first_only?, timeout_ms?}` (see below), `security.ssl_killswitch` |
| Apps | `apps.list`, `search`, `refresh`, `launch`, `terminate`, `foreground`, `open_url`, `install`, `info`, `binary`, `data_dir`, `url_schemes`, `handlers`, `registration`, `register`, `network_policy {repair?}`; `apps.uninstall`, `unregister`, `unregister_dir` **force** |
| System | `system.uicache`, `system.system_apps {visible?}`, `system.respring` **force**, `system.reboot {userspace?}` **force**, `developer_mode.status`, `developer_mode.enable`, `power.low_power_mode`, `diagnostics.self_test` |
| Files | `files.list`, `mkdir`, `remove`, `rename`, `read {binary?, limit?}`, `write`, `find`, `copy`, `symlink`, `chmod`, `chown`, `plist`, `plist_set {value \| remove}` |
| Preferences, clipboard, location | `settings.get/set/delete`, `clipboard.get/set/clear`, `location.set/clear/current` |
| Keychain | `keychain.list {class?}`, `add`, `delete`, `get`, `update`, `database` |
| Packages (read-only) | `packages.list`, `status`, `info {path}`, `compare`, `tweaks`, `repos` |
| Bootstrap | `bootstrap.install {layout}`, `bootstrap.status`, `bootstrap.inspect`, `bootstrap.uninstall {jbroot, force}`, `bootstrap.firmware` (see above) |
| Environment | `environment.status` (SHA-256 of each vphone library in `/usr/lib`, or null when absent, plus the staging directory), `environment.install {libraries: [{name, sha256}]}` (see below) |
| Profile UDID | `udid.get`, `udid.set {udid}`, `udid.clear` — each returns `{udid, path}`, the UDID the guest gives its profile checks and the host (null: the guest's own) and the settings file it came from; `set` and `clear` also return `restarted_pids`, `usb_serial` and `usb_reenumerated` (see below) |
| Setup Assistant | `setup.status` (`{pending, running, pid, setup_done, setup_version, current_version}`), `setup.skip` **force** (sets `SetupDone`, `SetupFinishedAllSteps` and `SetupVersion` in `com.apple.purplebuddy`, restarts SpringBoard, returns the status plus `respring`); `/v1/health` carries `setup_pending` — see `Research/Guest/setup_assistant_skip.md` |

`display.auto_lock` reads Settings' Auto-Lock (`maxInactivity` in profiled's
`EffectiveUserSettings.plist`) and SpringBoard's `SBMinimumLockscreenIdleTime`.
SpringBoard honors Auto-Lock only while unlocked; on the Lock Screen it turns
the screen off after six seconds unless that key says otherwise. vphoned keeps
the key at "never" while Auto-Lock is Never and removes it when Auto-Lock is
anything else (`VPhoneDaemon/Daemon/GuestLockScreenIdle.swift`), at startup
and whenever the settings change. SpringBoard reads the key when it starts, so
a newly written one holds from the next boot or respring. Measurements:
`Research/Guest/lock_screen_idle_timer.md`.

`/v1/health` also carries `mobilegestalt_restart_pending`. At startup vphoned
removes libMobileGestalt's cache,
`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`,
when it is older than the Preboot `devicetree.img4` the guest booted: its
answers were worked out from an older tree
(`VPhoneDaemon/Daemon/GuestMobileGestaltCache.swift`). Running processes keep
the answers they read, so the field is true from that removal until the guest
restarts, also across a vphoned restart in the same boot; vphoned does not
restart the guest itself. See `Research/Guest/virtio_sound.md` §7.

`screen.unlock` reads the lock state, then turns the display on with
`SBSUndimScreen` (no toggle, unlike a power press) and presses Home to dismiss
the Lock Screen: a passcode-free guest goes to the Home Screen, a guest with a
passcode gets the passcode pad, into which `passcode` is typed
(`VPhoneDaemon/Daemon/GuestScreenUnlock.swift`). A lit, unlocked guest returns
at once; a dark but unlocked one is only woken. A guest with a passcode needs
`passcode`, entered once and never retried; without it the call fails before
any key is sent. It needs no private entitlement. `timeout` is 1–60 seconds,
10 by default. Measurements: `Research/Guest/screen_unlock.md`.

`network.ipv4.get` and `network.ipv4.set` read and write the IPv4 settings of
one interface (default `en0`) in configd's network preferences,
`/var/preferences/SystemConfiguration/preferences.plist`, through SCPreferences
resolved with `dlsym` (`VPhoneDaemon/Native/vphoned_network.m`). Both return
`{interface, service, method, managed, address?, subnet_mask?, router?, dns}`;
`set` adds `changed`. `set` with `method: "manual"` needs `address`,
`subnet_mask` and `router`, and takes `dns` as an array; it commits and applies
the preferences, so the address changes at once and survives a reboot. A
manual configuration vphoned writes is marked `VPhoneManaged` in the service's
`IPv4` and `DNS` dictionaries. `method: "dhcp"` undoes only a marked one; an
address the user set in the guest's own Settings is left alone and reported
with `changed: false`. `vphone-vm` calls `set` after every connect with the
setting its network plan derived from the VM's `config.plist`
(`VPhoneNetworking.plan`), so the guest is held to that address.

`network.hostname.get` and `network.hostname.set` read and write the guest's
mDNS name, `System/Network/HostNames/LocalHostName` in the same preferences;
both return `{local_host_name, managed}`, and `set` adds `changed`. `set` with a
`local_host_name` (one DNS label) replaces the name and records the one it
replaced; `set` with none or null puts that one back. A name vphoned did not set
is never changed by a null. `vphone-vm` calls `set` after every connect with the
VM's `localHostName`, or null when it has none.

`network.static_names.set` replaces the names the guest resolves locally, given
as `entries: [{address, names}]` (IPv4 only; an empty list withdraws them).
vphoned registers each name as a LocalOnly, known-unique A record with the
guest's own mDNSResponder (`VPhoneDaemon/Daemon/GuestStaticNames.swift`), the
kind of record an `/etc/hosts` line becomes: an IPv4 lookup of the name returns
that address alone, at once, without a query on the wire or cached answers. It
saves them and registers them again when it starts; `get` lists them.
`vphone-vm` sets this Mac's `<LocalHostName>.local` after every connect.

`network.resolve` runs `getaddrinfo` in the guest (`family` `ipv4`, `ipv6` or
any) and returns `{host, status, elapsed_ms, addresses}`, the addresses in the
resolver's order. With `port`, each address is also connected to for up to two
seconds and reports `connect`, `connect_ms` and the `local` address used, which
names the interface the connection left from; `first_only` connects to the
first address only, as a client that does not fall back would.

`processes.list` joins icli's kernel process list with `proc_pid_rusage`
footprint, resident size and CPU time (`VPhoneDaemon/Native/vphoned_process.m`),
the jetsam priority band and limit, and the RunningBoard bundle identifier.
Account passwords, boot logo rendering and package installation, removal and
repository changes are deliberately not exposed. `/v1/health` lists the new
areas in `capabilities` (`device_info`, `display`, `audio`, `input_gestures`,
`ui_inspection`, `processes`, `services`, `logs`, `network_capture`,
`app_details`, `system_control`, `file_tools`, `packages`, `environment_update`, `udid_override`, `setup_skip`, `network_ipv4`, `network_hostname`, `network_static_names`, `network_resolve`, `display_auto_lock`, `screen_unlock`) so a host can hide
panels an older agent cannot serve. icli failures reach the caller with
icli's own error `code` (`failed`, `unavailable`, `device_locked`, …) and
message.

## Nested accessibility snapshots

`ui.tree` (alias `accessibility.tree`) keeps its existing flat result unless
the RPC params contain `"nested": true`. `nested` must be a JSON boolean.
For example:

```json
{"method":"ui.tree","params":{"nested":true,"max_elements":500,"max_depth":32,"timeout_ms":5000}}
```

Nested snapshots accept only integer bounds: `max_elements` defaults to 500
(1–2000), `max_depth` to 32 (1–32, with the root at depth 0), and `timeout_ms`
to 5000 (100–10000). They preserve structural nodes: omit `visible_only` and
`limit`, and do not enable `clickable_only`; these filters are rejected.
The daemon verifies the same foreground application and PID before and after
the snapshot. A changed or unverifiable foreground returns an operation error.

The native walker starts from that application's AX root and reads immediate
children through private iOS attribute 5001. Attribute 5002 independently
checks each child's parent; labels, frames and visible/explorer arrays do not
establish relationships. The result contains `source: "ax"`, `format: "nested"`,
`relationship_source`, `roots`, and a unique-node `count`. Each node has a
snapshot-local `id`, `label`, `identifier`, `role`, `frame` (or null), `depth`,
`children`, `children_status`, `parent_verified`, and `query_errors`.
Repeated nodes use `ref`; `cycle` distinguishes an active ancestor from a
shared node. IDs do not persist between snapshots. `action_eligible: false`
marks the snapshot as diagnostic; its IDs are not tap selectors.

Inspect `status` (`complete`, `partial`, or `unavailable`), `truncated`, and
`truncation_reasons` before consuming the tree. Element, depth, query and time
limits produce partial results; the query budget is `max_elements * 8`.
`limits`, `queries`, `elapsed_ms`, and `parent_checks` (verified, mismatch,
unavailable) expose the walk's bounds and relationship checks. Per-node errors
include the attribute number and native error code; optional text or frame
attributes can be unavailable even when the structural walk is complete.
`symbols`, `switches_before`, and `switches_after_restore` expose native API
availability and accessibility switch restoration; `native_exception` is
included if a native exception prevented the snapshot. `foreground_before`,
`foreground_after`, and `runtime` identify the verified app and serving daemon.

`readiness` reports `switches_enabled_for_invocation`, `retry_attempted`,
`retry_resolved`, `wait_ms`, `max_wait_ms`, and `initial_query_errors`.
Only an invocation that newly enables an AX switch may retry the first root
label query after error -25215 with no value. It waits once for 400 ms only
when more than 400 ms remain, sharing the original deadline and query budget.
Resolved initial errors stay in `readiness.initial_query_errors`; child errors
do not trigger this retry. Attribute calls request at most a 100 ms messaging
timeout, but private API calls can exceed it if the OS does not honor it.

This is an opt-in diagnostic path using private iOS AX symbols and attribute
numbers, whose availability and behavior can change between OS releases.
Partial checks remain necessary on each snapshot. Run the native walker tests
from the checkout on a Mac with Xcode tools:

```sh
VPhoneDaemon/Tests/run-hierarchy-tests.sh
```

The runner builds in a temporary directory, checks injected child/parent links,
cycles, malformed values, limits, timeout failures and readiness recovery,
prints native coverage, and removes its outputs. The script also accepts an
absolute invocation path from any working directory. It does not require a guest;
these tests do not establish compatibility with every iOS build.

## Environment and identity updates

The environment update keeps `launchdhook-vphone.dylib`,
`SystemHook-vphone.dylib`, `libvcamcaptured.dylib` and `libcamfix.dylib` in
`/usr/lib` in step with the host bundle. After each connection the VM
process compares the guest's hashes with `Contents/Resources/guest-resources`,
uploads the libraries that differ to the staging directory
(`/var/root/Library/Caches/vphone-environment`) and calls
`environment.install`. vphoned accepts only those four names and checks each
SHA-256. When `/` is mounted read-only it runs `/sbin/mount -u -w /`, copies
each library beside its destination, renames it into place with mode 0755
and owner root, and tries `/sbin/mount -u -r /` again. An APFS guest can reject
that live read-only remount; in that case the install still reports success
with `reboot_required: true` and `root_read_only: false`. The reboot restores
the intended root state for jailbreak detection. It stops a running
`cameracaptured` when a camera hook or SystemHook changed, so the next
camera client loads the new hook. The result lists `installed`,
`restarted_pids` and `reboot_required`, which is true when the launchd hook
changed: launchd keeps the copy it mapped at boot.

The profile UDID methods drive `libmisfix.dylib`'s MobileGestalt interpose in
misagent, installd, lockdownd and remoted, and the USB serial string
(`Research/Guest/xcode_install_signature_gate.md`). The hook reads
`UniqueDeviceID` from the first of `/var/db/vphone/misfix.plist` and
`/usr/lib/libmisfix.plist` that exists. vphoned owns the first: `udid.set`
stores the string exactly as sent, with no format check, so the API and
`vphone.sock`'s `rpc` verb can try unusual values; `udid.clear` removes the key
but keeps the file, so a value in the `/usr/lib` copy cannot take over. The file
is written as a binary plist in one rename and read back, then vphoned sends
SIGKILL to misagent, installd, lockdownd and remoted (remoted outlives
SIGTERM), sets the USB serial to the UDID without its hyphen (the guest's own
for `clear`) and takes the USB device off the bus and back. That relaunches
remoted and makes usbmuxd, lockdown clients and CoreDevice read the identity
again; `idevice_id` lists the new UDID within seconds. The guest does not
restart. vphoned reapplies a configured UDID to the USB serial at every boot,
once the USB device exists. A new UDID is a new device to the host: the guest
asks to trust the computer again, and keeps one pair record per host, so
switching back needs trusting again too. The VM window's Device › Set UDID… is stricter than the API: it
accepts only 8 and 16 hex digits joined by a hyphen (sent upper-case) or 40 hex
digits (sent lower-case).

`location.set` is IcliKit's `simulateLocation`: it sends locationd's
`CLSimulationManager` the sequence Xcode uses (`stopLocationSimulation`,
`clearSimulatedLocations`, `appendSimulatedLocation:`, `flush`,
`startLocationSimulation`). locationd sends no reply and silently ignores a
client without `com.apple.locationd.simulation`, so success is decided by a
read-back: vphoned opens a `CLLocationManager` with
`initWithEffectiveBundlePath:` on the first authorized System Services bundle
(`SystemCustomization`, `TimeZone`, `CompassCalibration`), then waits up to 5 s
for a fix stamped no earlier than one second before the read, within 1e-7° of
the requested coordinate. The fix must be `fresh` and
`sourceInformation.isSimulatedBySoftware`; otherwise vphoned clears the
simulation and returns `unavailable` (`no location within 5 s`, or `locationd
did not apply the simulated location`). The reply is `simulating: true` plus
the fix that was read back. `location.clear` stops the simulation and polls for
up to 6 s until locationd stops reporting a fresh simulated fix.
`location.current` reads the same way with the caller's timeout and reports
`fresh` and `simulated` as CoreLocation gives them. The read-back needs
locationd to deliver a fused fix. The 2.0.4 guest in
`Research/Guest/location_simulation_26_4_failure.md` never got one; that build
had the hv_vmm_present concealment on, under which bluetoothd crash-loops and
locationd blocks on it (issue #438). `standard` no longer enables it.

## Connection failure behavior

A dropped HTTP or WebSocket connection closes only that request channel. The
guest launchd plist starts a small vphoned proxy. It uses `posix_spawn` to
start the same signed executable with `--io`, then waits for and reaps that
worker. The worker owns VSOCK 1338 and 1339 and all API state. The proxy
restarts an unexpectedly exited worker after a fixed one-second pause, for
as long as it runs, and forwards shutdown to it. The previous exponential
backoff kept a 26.4 guest's API down until about 24 s after launchd started
the proxy: early-boot workers exited, and the proxy waited 1, 2, 4 and 8 s
between them. The proxy logs each worker exit with its status or signal to
`/var/log/vphoned.log`, which the plist names as stdout and stderr. The plist
also sets `ThrottleInterval` to 1 so launchd restarts the proxy itself one
second after it exits, not the default ten, and `ProcessType` to
`Interactive` so boot-time CPU and I/O throttling does not apply. A pipe
makes the worker exit if launchd kills the proxy, so the old worker cannot
retain the ports after launchd starts a replacement.
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
