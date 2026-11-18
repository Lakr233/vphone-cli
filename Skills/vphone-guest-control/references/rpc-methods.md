# vphoned methods

`guest rpc <machine> <method> '<params-json>'` calls a method in the guest's
daemon through the machine's `vphone.sock`. Params are one JSON object (omit
for none). The reply is `{"ok":true,"result":{…}}`. On `ok:false` the CLI exits 1
and puts the guest's own error (for example `guest not connected` or
`Unknown method: …`) on stderr; when vphoned itself refused, the last stderr
line is its error object as JSON (`vphone.sock` carries it as `guest_error`).
`--screen` also returns the small screen image. Full catalog:
`Research/vphoned_http_api.md` ("Method catalog").

## How to read methods.list

`methods.list` (no params) is the authority for params and results. Call it
once, filter by area (name prefix such as `files.`), and read each method's
`params` (`name`, `type`, `required`, default, `description`) and `result`
array (`name`, `type`, `required`, `open`; an `open` result may carry more
keys). Read `force` as `always`, `never` or `when:<key>` (`services.kickstart`
is `when:kill`). To test for a method, look for it there; a missing method
fails with `not_found`, usually an older guest environment ([machines](machines.md)).
`/v1/health` capability flags exist only over HTTP with `vm launch --api-listen`.

## Conventions

- `input.*` and `ui.element_at` take **screen points**, not pixels
  ([guest-socket](guest-socket.md)).
- Every `input.*` method takes optional `observe` (boolean, false) and
  `observe_delay_ms` (0...5000, 300). With `observe: true` the reply gains
  `observed: {frontmost_bundle_id, ui_element_count, …}` after the delay;
  `ui_element_count` is capped at 500. A failed observe gives
  `observed: {observe_error}` and the action still succeeds.
- **force methods** refuse to run unless the params carry `"force":true`. The
  flag is the confirmation: use it only for what the user asked. Without it
  the call fails with `force_required` and the hint `Confirm with the user,
  then repeat the call with force: true`.
- **Errors** are `{code, message, hint?}`; read `hint`, which names the fix
  (the closest param or method, valid values) and is absent when there is none.
  A param the method does not list fails with `invalid_param`.

  | Code | Meaning |
  | --- | --- |
  | `invalid_param` | Missing, malformed, out-of-range or undeclared param |
  | `not_found` | Target or method does not exist (hint may name the closest method) |
  | `unavailable` | Platform, OS or component cannot do it |
  | `force_required` | Repeat with `"force":true` after the user confirms |
  | `permission` | The OS refused for lack of entitlement or access |
  | `invalid_operation` | Any other operation failure |
  | `already_done` | The operation was already in that state |

  **Guest not connected:** retry rule in [troubleshooting](troubleshooting.md).
- Results can be large: use `limit`, `max_lines`, `max_elements` or `filter`.
- **Paging.** `apps.list`, `processes.list`, `services.list`, `services.dump`,
  `files.list`, `files.find`, `apfs.snapshots` and `logs.crashes` return at most
  `limit` entries (1 to 1000, default 200, so a long list is cut by default).
  The reply has `total` and `truncated`; when `truncated` is true it has
  `next_cursor`: pass it as `cursor` for the next page. A bad cursor fails with
  `invalid_param`; repeat without one. `processes.spawn` returns a first page
  per stream and spools the rest; page it with `processes.output`. Spools expire
  after 10 minutes (`not_found`; repeat the spawn).

## Method areas

Names only; params come from `methods.list`. Prefer `ui.*` to coordinates.
- **Device, screen:** `device.*` (`device.info` first), `screen.screenshot`
  (the reply gives `point_width`, `point_height`, `coordinate_scale`),
  `screen.unlock`, `display.*`, `audio.*`.
- **Input:** `input.*`. `input.type` types key by key; `input.paste` and
  `clipboard.set` go through the pasteboard, faster for long or non-ASCII text.
- **UI:** `ui.describe` (cheapest), `tree`, `element_at`, `tap_element`, `wait`,
  `wait_gone`, `ocr`. Selector keys: `text`, `identifier`, `role`, `match`,
  `index`.
- **Apps:** `apps.*`. A launch reply with `frontmost_verified:false` means the
  front app was not confirmed as this app (always so when `url` is passed);
  check with a screenshot.
- **Processes, logs, services:** `processes.*` (`spawn` runs `ps`, `launchctl`
  or `log`, no shell), `logs.*`, `services.*`, `launchd.*`, `memory.*`,
  `apfs.snapshots`.
- **System:** `system.*`, `setup.*`, `developer_mode.*`, `settings.*`,
  `notify.*`, `time.timezone`, `time.clock` (the VM resends the Mac's time
  every minute, so a set time lasts only with `automatic: false`),
  `keychain.*` (only on request; never print values), `location.*`: `set` and
  `current` fail with `location_services_off` while Location Services is off;
  `location.services` fails with `invalid_operation` if the switch did not change.
- **Bootstrap:** `bootstrap.*`; flow in [guest-layout](guest-layout.md).

## Installing an app

Two routes with different meaning:

- **Through installd** (what Xcode does; exercises the install gate):
  `ideviceinstaller -u <UDID> install App.ipa`. UDID: `idevice_id -l` or `vm list`.
- **Through vphoned:** `apps.install '{"path":"/private/var/tmp/App.ipa"}'`,
  optional `registration:"System"` and `cert_path`. `path` is a **guest** path
  and vphoned **deletes the file after installing**. It re-signs the bundle,
  bypassing installd and the profile checks, and keeps the app's entitlements
  (`get-task-allow` survives); extensions are registered. It proves nothing
  about installd. Getting the file in: [guest-layout](guest-layout.md).

## Files

`files.*` paths are real-root paths. Read a small file with `files.read` (`path`). `files.write` replaces the whole file and takes one JSON line of at most 1 MiB,
so a binary over about 700 KiB does not fit. For any size use
`vphone-launchpad-cli guest push` and `guest pull` ([guest-layout](guest-layout.md)).

## Running a script in the guest

`script.eval {source, timeout_ms?}` runs JavaScript with vphoned's identity in
a separate session process. Use it only when no method covers the need;
`script.info` says whether this guest has it. Details:
`Research/vphoned_http_api.md` ("Scripting sessions").

## Raw HTTP and WebSocket

Served only when the VM was launched with `vphone-cli vm launch --api-listen
host:port` (`vm start` has no such option); keep it on loopback. File streaming,
tunnels, events, auth rules: `Research/vphoned_http_api.md`.
