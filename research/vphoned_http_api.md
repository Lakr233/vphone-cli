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

The guest build also includes the pinned `icli` executable, signed with
icli's entitlements and installed at `/usr/bin/icli` alongside vphoned.
`POST /v1/icli/execute` and the WebSocket method `icli.execute` accept
`{"argv":["device","info"]}`. The guest passes that array to icli directly,
captures its JSON output, and returns `exit_code`, `output`, and `stderr`.
This exposes icli's complete command tree, including newly added subcommands,
without duplicating each command in vphoned. `stdin` or `stdin_base64` supports
commands that read standard input. The process has a 120 second deadline.

## HTTP and WebSocket contract

`GET /openapi.json` is the machine-readable HTTP description. JSON resource
routes cover device state, apps, input, location, Developer Mode, low power
mode, clipboard, file listing, and keychain. `GET/PUT
/v1/files/content?path=<absolute-guest-path>` transfer bytes with
`application/octet-stream`; upload writes to a temporary file in the same
directory then renames it after all chunks have been written. JSON bodies
have a 1 MiB limit. Binary transfers stream without loading the entire file
into memory.

Upload accepts an optional octal `mode` query parameter (default `644`) and
creates missing parent directories. Download follows file symlinks, matching
the previous file browser behavior.

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

SwiftNIO handles parsing, upgrade, masking, and backpressure. IcliKit 0.6.1
owns general device operations; they run on a serial worker queue because its
in-process bridge is synchronous. The vphone-specific IPA signing and all-app
keychain view remain in native Objective-C modules. The VM GUI uses HTTP over
VSOCK 1339 directly; host TCP forwarding is opt-in. The former length-prefixed
VSOCK 1337 protocol and duplicate ObjC command handlers have been removed.
The 1338 virtual camera stream remains. At startup, the host compares the
signed daemon hash from `/v1/health`; an update is uploaded through HTTP,
verified by SHA-256, made executable, and activated through launchd restart.
This intentionally breaks compatibility with guests that still have the old
daemon: install a guest image carrying this vphoned build before using the new
host control client.

## Connection failure behavior

A dropped HTTP or WebSocket connection closes only that request channel. The
guest launchd plist keeps vphoned alive and restarts it if the daemon itself
exits. Host socket writes use `F_SETNOSIGPIPE`, so a guest disconnect becomes
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
curl http://127.0.0.1:8765/openapi.json
```

```swift
import VPhoneAPIKit

let client = VPhoneAPIClient(baseURL: URL(string: "http://127.0.0.1:8765")!)
let device = try await client.call("device.snapshot")
let icli = try await client.runIcli(["device", "info"])
let socket = try client.openWebSocket()
try await socket.send("input.touch", params: [
    "phase": .string("down"), "x": .number(0.5), "y": .number(0.5),
])
let message = try await socket.next()
```

The listener accepts the address specified by the user. For local-only use,
pass `127.0.0.1` or `[::1]`. The API currently has no authentication layer;
exposing it beyond a trusted host requires the caller's own access control.
