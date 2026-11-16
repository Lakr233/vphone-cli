# Automation API

Control a running VM from scripts over HTTP and WebSocket. Use this page to turn the API on, authenticate, and make your first calls; the [full API reference](../../../Research/vphoned_http_api.md) lists every route and method.

## Turn it on

Add `--api-listen` when you launch the VM:

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
```

After the VM starts, `vphone-vm` prints the address and a token:

```text
[api] HTTP/WebSocket API: http://127.0.0.1:8765
[api] token: 3f9c…
[api] send it as: Authorization: Bearer 3f9c…
```

- Without `--api-listen` there is no host listener.
- Port `0` asks macOS for a free port; the actual address is printed after the VM starts.
- `--api-listen` is unavailable with `--dfu`.

> [!WARNING]
> vphoned runs as root, and the API can read and write any guest file, list the keychain and load launch daemons. For local-only use, listen on `127.0.0.1` or `[::1]`. Any other address prints a warning: every machine that can reach it needs only the token, which travels in clear text over plain HTTP, so use it only on a trusted network.

## The token

The token is new for each launch: 32 random bytes, in hex. To use a fixed token, set `VPHONE_API_TOKEN` before launching; `vphone-cli vm launch` passes its environment through to `vphone-vm`. The value must be 16 to 256 characters of `A-Z a-z 0-9 - . _ ~`; any other non-empty value stops the launch.

Send the token in any of these forms:

| Form | Use for |
| --- | --- |
| `Authorization: Bearer <token>` header | HTTP, and WebSocket clients that can set headers |
| `token=<token>` query item | WebSocket URLs, such as `ws://127.0.0.1:8765/v1/events?token=<token>` |
| `Sec-WebSocket-Protocol: vphone-token.<token>` | WebSocket clients that can only set a subprotocol |

A missing or wrong token gets `401 Unauthorized`, and the connection closes before anything reaches the guest. If the guest closes the connection before sending any reply byte, the proxy answers `502 Bad Gateway` with error code `guest_closed`; a reply already under way is never altered.

## Example calls

```sh
TOKEN=...   # from the "[api] token:" line, or the VPHONE_API_TOKEN you set

# Health check
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health

# Call any method through /v1/rpc
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"method":"device.snapshot","params":{}}' http://127.0.0.1:8765/v1/rpc

# Event stream
websocat "ws://127.0.0.1:8765/v1/events?token=$TOKEN"

# Interactive shell in the guest (websocat needs --binary)
websocat --binary "ws://127.0.0.1:8765/v1/shell?token=$TOKEN&cols=120&rows=40"
```

Rules that trip up hand-written clients:

- Every `POST` must send `Content-Type: application/json`, or it gets `415`.
- A request with an `Origin` header, or with a `Host` other than `vphoned`, `localhost`, `127.0.0.1` or `::1`, gets `403`. This blocks browser pages from reaching the API.
- `GET` routes only read. To change a setting, use `PUT` or `POST`, for example `PUT /v1/low-power-mode` with `{"enabled": true}`.

Swift apps can use the `VPhoneAPIClient` in the `VPhoneExternalAccessKit` library, which sends the token for you; see the reference for an example.

## Without a network listener

The VM's control socket accepts the same methods without the API listener: send `{"t":"rpc","method":"<method>","params":{}}` as one JSON line. See [Control socket](create-and-run.md#control-socket).

## MCP server

`vphone-mcp` exposes VM control sockets as Model Context Protocol tools, so an MCP client such as Claude Code can look at the screen and drive guests. Build it from the workspace:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhoneMCP -configuration Debug -derivedDataPath build/mcp build
```

The binary is `build/mcp/Build/Products/Debug/vphone-mcp`. Every call names the VM in its required `vm` argument, so one server drives several running VMs.

The tools:

- `screenshot`, `push`, `pull`, `shell`, `methods` and `rpc` are fixed.
- Thirteen area tools (`input`, `ui`, `apps`, `files`, `processes`, `services`, `device`, `sensors`, `network`, `settings`, `system`, `bootstrap`, `script`) are generated from the guest catalog (`methods.list`) embedded in `vphone-mcp` (`VPhoneMCP/VPhoneMCPCLI/GuestCatalog.swift`, checked by `zsh VPhoneDaemon/Tests/run-methods-tests.sh`; rewrite it with `zsh VPhoneDaemon/Tests/run-methods-tests.sh --write-catalog`), so the tool list is the same whichever VMs run. A guest build that lacks a method answers with its own unknown-method error. Each takes `action` (a method name such as `input.tap`) and that method's parameters; its schema and description come from the catalog, and `force: true` confirms an action that needs it.

`--profile` limits what exists: `full` (default) offers everything; `standard` drops the actions the catalog marks `destructive` (those that need `force`) and the host tools `push`, `pull`, `shell` and `rpc`; `readonly` offers only `read` actions, `screenshot` and `methods`. `--tools` is an explicit allowlist of tool names, applied on top. A tool or action the profile removes is not listed, and calling it is refused.

With a profile:

```json
{"mcpServers":{"vphone":{"command":"/path/to/vphone-mcp","args":["--profile","readonly"]}}}
```

With `--tools`:

```json
{"mcpServers":{"vphone":{"command":"/path/to/vphone-mcp","args":["--tools","screenshot,input,ui,apps,methods"]}}}
```

With neither (every tool and action offered):

```json
{"mcpServers":{"vphone":{"command":"/path/to/vphone-mcp","args":[]}}}
```

Warning: `push` and `pull` reach any host path the VM host process can reach, and `rpc`, `shell` and the destructive actions of the group tools reach guest actions. Leaving them out of `--tools`, or starting with `--profile standard` or `--profile readonly`, denies this.

`screenshot` returns the screen at point size, and the `input` actions take points, so look before acting. `shell` runs a session in the guest: pass `program: "bash"` for shell commands. Failures from the VM come back as tool errors; a call that names an unknown tool, action or a bad argument is a JSON-RPC error and sends nothing to the VM.

## See also

- [Full API reference](../../../Research/vphoned_http_api.md)
- [Create and Run a VM](create-and-run.md)
- [Port Forwarding](../networking/port-forwarding.md)
- [Launchpad Command Line](../launchpad/launchpad-cli.md)
