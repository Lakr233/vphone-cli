# vphoned methods

`guest rpc <machine> <method> '<params-json>'` calls a method in the guest's
daemon, through the machine's `vphone.sock`. Params are one JSON object (omit
for none). The reply is `{"ok":true,"result":{…}}`. On `ok:false` the CLI exits 1 with
"The machine refused the request. Try again." and puts the guest's own error
(for example `guest not connected` or `Unknown method: …`) on stderr. When
vphoned itself refused, the last stderr line is its whole error object as JSON
(`code`, `message` and fields such as `results`, `reason`, `errno`,
`retryable`); `vphone.sock` carries the same object as `guest_error`. Add `--screen` to also get the small screen image.

Result shapes are not listed here: `methods.list` is the authority. Each method's
`result` array gives its keys as `name`, `type`, `required` and `open`
(an open result may carry keys beyond those listed). Call it instead of guessing.
Each method and param also carries a `description`; `Research/vphoned_http_api.md`
lists the full field set.

The complete catalog, with REST routes and behaviour, is
`Research/vphoned_http_api.md` ("Method catalog"). This file is the working
subset with parameter names checked against the daemon source
(`VPhoneDaemon/Daemon/GuestAPI*.swift`). When a call fails with an
invalid-request error, read the source named there instead of guessing keys.

## Contents

- Conventions
- Device and screen
- Input
- UI inspection
- Apps
- Installing an app
- Files
- Processes, logs, services
- System and preferences
- Bootstrap
- Running a script in the guest
- Raw HTTP and WebSocket

## Conventions

- Coordinates for `input.*` and `ui.element_at` are **screen points** as
  `device.screen` reports, not the pixels used by the socket's `tap`.
- **force methods** refuse to run unless the params carry `"force":true`.
  `methods.list` (no params) lists every method with its params and its
  `force` value (`always`, `never` or `when:<key>`, as for `services.kickstart`
  with `kill`); this list is the authority. The flag is the confirmation: use it
  only for what the user asked.
- Results can be large. Methods that read data take `limit`, `max_lines`,
  `max_elements` or a `filter`; use them. A reply in the 8–16 KiB band can be
  lost on close (see [troubleshooting](troubleshooting.md)).
- Capability flags in `/v1/health` tell which areas this vphoned supports (`methods`
  means it answers `methods.list`). An
  `unknown method` error against an older guest means update its environment
  ([machines](machines.md)).

## Device and screen

| Method | Params | Notes |
| --- | --- | --- |
| `device.info` | none | Snapshot plus network, screen, rotation, brightness, volume, low power, Developer Mode. Start here |
| `device.snapshot`, `device.screen`, `device.network` | none | Smaller views of the same |
| `screen.screenshot` | `max_dimension?` (integer, 1 or more), `quality?` (0.1-1.0), `region?` `{x, y, width, height}` in points | Base64 JPEG at the panel's pixel size (1179×2556 on a new iPhone17,3); `max_dimension` scales the longer side down, `region` crops first. Reply adds `point_width`, `point_height`, `region`; pixel `(px, py)` is point `(region.x + px / coordinate_scale, region.y + py / coordinate_scale)`. Bad values fail with `invalid_operation` |
| `display.brightness`, `audio.volume` | `value?` | Omit `value` to read |
| `audio.host_latency` | `seconds?` (0-1) | The Mac output latency the guest speaker adds; omit to read. The VM sends it on every connect and output change |
| `display.rotation`, `display.orientation` | `orientation?` | |
| `display.auto_lock` | none | Auto-Lock in seconds (`never` when it is Never) and the Lock Screen timeout vphoned sets to match |
| `screen.unlock` | `passcode?`, `timeout?` (10) | Display on and Lock Screen passed, from any state; `guest unlock <machine>` calls it. `passcode` only for a guest that has one, entered once |
| `device.ioreg` | `plane` | e.g. `IODeviceTree` |

## Input

| Method | Params |
| --- | --- |
| `input.tap` | `x`, `y` |
| `input.double_tap` | `x`, `y`, `interval?` (0.1) |
| `input.long_press` | `x`, `y`, `seconds?` (1) |
| `input.swipe` | `x1`, `y1`, `x2`, `y2`, `seconds?` (0.3), `steps?` (20) |
| `input.drag` | `points` (≥2 `[x,y]` pairs), `seconds?`, `hold?`, `steps?` |
| `input.touch_sequence` | `events` (`{phase,x,y,delay_ms}`), `normalized?` (true) |
| `input.button` | `name` (hardware button) |
| `input.key` | `name` (`return`, `cmd+v`, …) |
| `input.type` | `text`, `delay_ms?` (30) |
| `input.paste` | `text` |
| `input.pointer` | `x`, `y` (0...1 of the interface as shown; iPad, capability `pointer_scroll`), `seq?` (increasing; a late move is dropped) |
| `input.scroll` | `phase` (`began`/`changed`/`ended`/`cancelled`), `dx?`, `dy?` (points, wheel signs), `x?`, `y?` |

## UI inspection

Prefer these to coordinates.

| Method | Params | Notes |
| --- | --- | --- |
| `ui.describe` | none | Short description of the screen; cheapest orientation |
| `ui.tree` | `max_elements?` (500), `visible_only?` (true), `clickable_only?`, `limit?` | Accessibility elements with positions |
| `ui.element_at` | `x`, `y` | |
| `ui.tap_element` | selector | Taps the match |
| `ui.wait`, `ui.wait_gone` | selector, `timeout?` (10 s) | Wait for an element to appear or go |
| `ui.ocr` | `languages?` (`["en-US"]`), `min_confidence?` (0.3) | Text with boxes; use for non-accessible UI |

Selector keys: `text`, `identifier`, `role`, `match` (`contains` by default),
`index` (0). Example:
`ui.tap_element '{"text":"General","match":"contains"}'`.

## Apps

| Method | Params |
| --- | --- |
| `apps.list` | `filter?` (`all` default) |
| `apps.search` | `query` |
| `apps.launch` | `bundle_id`, `url?` |
| `apps.foreground` | none; reports the verified front app |
| `apps.terminate` | `bundle_id` |
| `apps.open_url` | `url`, `bundle_id?` |
| `apps.info`, `apps.binary`, `apps.data_dir` | `bundle_id` |
| `apps.refresh` | `directory?`; same as `system.uicache` for registration |
| `apps.register`, `apps.registration` | `path` |
| `apps.uninstall` (force) | `bundle_id` |

`frontmost_verified:false` on a launch means the process started but no unique
foreground app could be confirmed. Check with a screenshot.

## Installing an app

Never `xcrun devicectl`: it times out against these guests. Two routes with
different meaning:

- **Through installd** (what Xcode does, and the only route that exercises the
  install gate): `ideviceinstaller -u <UDID> install App.ipa`. The UDID comes
  from `idevice_id -l` or `vm list`.
- **Through vphoned:** `apps.install '{"path":"/private/var/tmp/App.ipa"}'`,
  optional `registration:"System"` and `cert_path`. `path` is a **guest** path,
  and vphoned **deletes the file after installing**. It re-signs and places the
  bundle itself, bypassing installd and the profile checks, and keeps the app's
  own entitlements (so `get-task-allow` survives, which is the way to get a
  debuggable test app in). Its `PlugIns/*.appex` are registered with the app,
  so extensions (packet tunnels, share sheets, widgets) launch. It proves nothing about installd. To get the file
  into the guest, see [guest-layout](guest-layout.md) ("Handing a file to
  vphoned").

Then launch with `apps.launch`.

## Files

Paths are real-root paths. All take `path` unless noted.

| Method | Params |
| --- | --- |
| `files.list` | `path` |
| `files.read` | `path`, `limit?`, `binary?` (base64) |
| `files.write` | `path`, `content`, `encoding?` (`utf8`) |
| `files.mkdir` | `path` |
| `files.remove` | `path`, `recursive?` |
| `files.rename` | `from`, `to` |
| `files.copy` | `from`, `to` |
| `files.find` | `root`, `pattern` |
| `files.symlink` | `target`, `link`, `replace?` |
| `files.chmod` | `path`, `mode` |
| `files.chown` | `path`, `owner` |
| `files.plist` | `path` |
| `files.plist_set` | `path`, `key`, and `value` or `remove:true` |

`files.write` replaces the whole file and takes one JSON line of at most
1 MiB, so a binary over about 700 KiB does not fit. Copy files of any size with
`vphone-launchpad-cli guest push` and `guest pull`, which stream
([guest-layout](guest-layout.md), "Handing a file to vphoned"). `files.read`
with `binary:true` is for small reads; keep `limit` small, since large reads
are the usual way to hit the reply size problem.

## Processes, logs, services

| Method | Params | Notes |
| --- | --- | --- |
| `processes.list` | `filter?` | a stuck SpringBoard shows ~0 CPU |
| `processes.kill` (force) | `pid`, `signal?` | |
| `memory.jetsam`, `memory.pressure` | none | |
| `logs.syslog` | `seconds?` (2, max 60), `process?`, `level?` (`all`), `max_lines?` (500) | A bounded capture |
| `logs.crashes` | `bundle_id?` | Lists reports |
| `logs.crash` | `path` | Reads one report |
| `services.list` | none | launchd |
| `services.status`, `services.print` | `label` | |
| `services.start`, `services.enable` | `label` | |
| `services.kickstart` | `label`, `kill?` | `launchctl kickstart`. `kill` (force) replaces a running instance, so a re-deployed daemon runs its new binary; without it a running service is left alone (capability `service_kickstart`) |
| `services.stop`, `disable`, `remove`, `unload` (force) | `label` | |
| `launchd.getenv` / `setenv` / `unsetenv` | `key`, `value?` | |

## System and preferences

| Method | Params |
| --- | --- |
| `system.uicache` | none; re-registers apps |
| `system.respring` (force), `system.reboot` (force) | `userspace?` for reboot |
| `system.shutdown` (force) | none; shuts the guest down, which stops the VM (capability `system_shutdown`) |
| `setup.status` | none; `setup.skip` (force) skips Setup Assistant |
| `developer_mode.status` / `enable` | none |
| `settings.get` | `domain`, `key?` |
| `settings.set` | `domain`, `key`, `value`, `type?` |
| `settings.delete` | `domain`, `key` |
| `clipboard.get` / `set` / `clear` | `set` takes `text` |
| `location.set` / `clear` / `current` / `services` | `set` takes latitude/longitude; `set` and `current` fail with `location_services_off` while the guest's Location Services switch is off; `location.services` reads `{enabled}`, and `enabled: true/false` sets the switch and returns the state read back (fails with `operation_failed` if it did not change; idempotent, so re-read with `location.services` before retrying); read-back can fail on some guests |
| `time.timezone` | none reads `{identifier, automatic, seconds_from_gmt}`; `identifier` (Olson name) pins the zone and turns automatic off; `automatic: true` hands it back to timed. The VM sends the Mac's zone on every connect |
| `time.clock` | none reads `{time, automatic}` (seconds since 1970; `automatic` is timed's automatic time); `time` (the Mac's time) moves a guest more than a second away onto it unless `automatic` is off, and adds `offset` and `changed`; `automatic` turns automatic time on or off. The VM sends the Mac's time on every connect and every minute, so a time set this way lasts only with `automatic: false` |
| `notify.post` / `notify.state` | `name`, `state?` |
| `keychain.*` | Lists, adds and edits secrets; use only on request and never print values |

## Bootstrap

`bootstrap.install {layout, package_path?}`, `bootstrap.status`,
`bootstrap.inspect`, `bootstrap.uninstall {roots, force, reboot?}`,
`bootstrap.firmware`. Behavior and the install flow: [guest-layout](guest-layout.md).

## Running a script in the guest

`script.eval {source, timeout?}` evaluates JavaScript with vphoned's own
identity and answers `{ok, result, output, crashed}`. It is the way to reach
something no method covers, and on an Apple TV guest it is the only
debugging environment there is: no shell, no package manager, no debugserver.
`script.info` reports whether this guest has it (capability `script_js`;
watchOS does not ship JavaScriptCore).

The script runs in a session process of its own, so a crash or a runaway loop
costs the session and nothing else; `timeout` defaults to 30 seconds. Inside
it, `api('method', {...})` calls any method in this file, `ObjC.use('NSFoo')`
and `ObjC.classes.NSFoo` call ObjC methods by name — an underscore stands for
a colon, `setValue_forKey_(v, k)` — and `fs`, `proc`, `console` and `print`
cover files, one program, and output. A returned collection stays an object;
`$value` converts it to plain JSON.

```sh
guest rpc script.eval '{"source":"ObjC.use(\"NSProcessInfo\").processInfo().operatingSystemVersionString()"}'
```

Prefer a real method when one exists: it is checked, documented and stable.
Reach for a script when nothing covers what is needed, then say so, because a
missing method is usually worth adding. The interactive form is the
`/v1/shell` WebSocket, which needs `--api-listen` — see
`Research/vphoned_http_api.md` ("Scripting sessions").

## Raw HTTP and WebSocket

The same methods are served as HTTP/WebSocket on guest VSOCK 1339. A host
listener exists only if the VM was launched with `vphone-cli vm launch
--api-listen host:port` (the launch prints `[api] token: …`); `vm start` has no
such option, so an agent cannot enable it through the CLI. Use it on loopback only:

```sh
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"method":"device.snapshot","params":{}}' http://127.0.0.1:8765/v1/rpc
```

It adds streaming file transfer (`GET/PUT /v1/files/content?path=`), a TCP
tunnel to a guest port (`/v1/ports/<port>` over WebSocket) and an event stream
(`/v1/events`). Every `POST` needs `Content-Type: application/json`. Details
and the 401/403/415/502 rules: `Research/vphoned_http_api.md` ("Access control").
