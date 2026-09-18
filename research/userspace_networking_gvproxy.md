# Userspace networking (`--network tunnel`) — VM networking behind a VPN

## Why this exists

Guest networking used Apple's `VZNATNetworkDeviceAttachment` (mode `nat`). That
attachment is not a self-contained NAT: it reuses macOS Internet Sharing / vmnet, which
sets up `bridge100` at `192.168.64.1` and installs pf NAT rules in the anchor
`com.apple.internet-sharing/shared_v4` shaped like:

```
nat on en5 inet from 192.168.64.0/24 to any -> (en5:0) extfilter ei
```

The masquerade is **pinned to the host's physical interface** — there is no rule for any
`utun`. When a VPN (Cloudflare WARP, Tailscale exit node, …) installs the default route,
the host's own egress leaves via `utun*` while the guest's egress is still written out
`en5`, and the two directions no longer match: every guest connection is black-holed
even though DHCP and ARP still work. `bridged` does not rescue the situation either —
`VZBridgedNetworkDeviceAttachment` only enumerates physical interfaces (a VPN `utun`
cannot be bridged) — and vmnet does not self-heal when the VPN drops; the NAT daemon has
to be restarted.

Observed symptom on the reference host (WARP on `utun5` with the usual `0.0.0.0/1` +
`128.0.0.0/1` split "default" routes, Tailscale on `utun335`):

```
default            10.10.43.1  UGScg   en5      <- physical
default            link#29     UCSIg   utun5    <- VPN
0.0.0.0/1 … 128.0.0.0/1        Uc      utun5
bridge100         192.168.64.1         (vmnet NAT for the guest)
```

Guest had `192.168.64.x`, could ping its gateway, and had no network beyond it.

## What replaced it

`VPhoneTunnelNetwork` (`sources/VPhoneCore/VPhoneTunnelNetwork.swift`) wires the guest NIC to
a userspace network stack instead of vmnet:

```
guest NIC ── VZFileHandleNetworkDeviceAttachment ── SOCK_DGRAM unix socketpair-ish ── gvproxy ── host sockets
             (raw L2 frames)                        (bind + connect, sun_path ≤ 103)      (DHCP/DNS/NAT)
```

* `VZFileHandleNetworkDeviceAttachment` maps the NIC to a **connected datagram socket**
  (same fd plumbing `vfkit` uses for `unixSocketPath=`, no `com.apple.vm.networking`
  entitlement needed).
* The socket is `bind()`-ed to a short local path and `connect()`-ed to gvproxy's vfkit
  transport. Binding is what lets gvproxy address replies back — unixgram has no
  `accept()`, so the helper learns the peer address from the first datagram.
* gvproxy (`gvisor-tap-vsock`, vendored as a downloaded helper, not a build dependency)
  terminates DHCP/DNS/TCP in a gVisor userspace stack and dials out with ordinary host
  sockets. Egress therefore follows the host routing table — VPN included — which is the
  entire point.
* No `VFKT` handshake is sent. v0.8.9 identifies vfkit clients with `MSG_PEEK`
  (gvisor-tap-vsock PR #530); sending the legacy magic was tested and is harmless but
  unnecessary.

### Negotiated network

Defaults from the helper, verified against v0.8.9:

| Item | Value |
| --- | --- |
| Subnet / guest address | `192.168.127.0/24` (DHCP lease from the pool) |
| Gateway + DNS + server-id | `192.168.127.1` |
| MTU advertised | 1500 |
| Domain search list (opt 119) | host search domains — on the reference host this was the Tailscale MagicDNS domain |

The subnet differs from vmnet's `192.168.64.0/24`, so the two modes can coexist on one
host without colliding.

## Using it

```bash
make net_helper                      # downloads gvproxy-darwin into .tools/bin (checksum-verified)
make build
./.build/release/vphone-cli vm config <VM_NAME> --network tunnel
make boot
```

Helper lookup order at runtime: `VPHONE_GVPROXY` → next to the executable
(`Contents/MacOS`) → `Contents/Resources` → `PATH` (the Makefile already puts
`.tools/bin` first). `scripts/build.sh` and `make bundle` copy `.tools/bin/gvproxy`
into `Contents/Resources/gvproxy`, so a bundle picks it up with no environment
variable — but only if the helper was downloaded *before* the bundle was built. If
`make net_helper` ran after the `.app` was built/installed, re-bundle
(`./scripts/build.sh`, then refresh the installed copy) and relaunch; a run outside
the project directory has no `.tools/bin` on `PATH` to fall back on, which is exactly
the `helperNotFound` failure that lists only the `.app` paths.
`VPHONE_NET_SOCKET_DIR` overrides the socket directory, which
defaults to `/tmp` because `$TMPDIR` is routinely too long for `sun_path` (103 bytes).
Anything that goes wrong is reported with the helper's own log tail; the helper writes to
`net-helper.log` next to the VM's `config.plist`.

Switching back is `--network nat` (or `bridged` / `none`). The default mode is unchanged.

## How it was validated

Reproduced without a VM, by driving the same transport the guest will use — start
`gvproxy -listen-vfkit unixgram://<path>`, `bind`+`connect` a `SOCK_DGRAM` unix socket,
then synthesize L2 frames (DHCP/ARP/IPv4/TCP/DNS) on that socket. On a host with WARP and
Tailscale both active, the probe observed:

1. `DHCP DISCOVER` → `OFFER` (`192.168.127.3`, options 1/3/6/26/51/53/54/119)
2. `DHCP REQUEST` → `ACK` (same option set)
3. ARP request for `192.168.127.1` → reply with the gateway MAC
4. TCP `SYN` to `1.1.1.1:80` and `:443` → `SYN-ACK` back
5. UDP DNS query for `example.com` to `192.168.127.1` → 2 answers, `rcode 0`

That is the full guest path (address, gateway, TCP egress, name resolution) proven green
*with the VPN up*, which is exactly what `nat` could not do.

`tests/VPhoneCoreTests/TunnelNetworkingTests.swift` covers the mode plumbing, helper
discovery, `sun_path` limits, the bind+connect socket, and start/stop of a real helper
when one is present (`make net_helper`, or `VPHONE_GVPROXY`). It skips those tests when no
helper or no bindable socket directory is available.

## Is the guest actually behind the VPN?

`user` mode is easy to distrust: the guest still gets a `192.168.127.x` address, and WARP's
split-tunnel list excludes `192.168.0.0/16`, which reads like it could swallow the guest's
traffic. It cannot. That list filters **destination** addresses on the host's routing table,
while the guest's address only exists inside the helper's gVisor stack — the helper dials
out with ordinary host sockets, sourced from host interfaces (`172.16.0.2` on the WARP
`utun`, `10.10.43.109` on `en5`), never from `192.168.127.3`.

To check it end-to-end without a VM, drive the same unixgram transport the guest NIC uses
(DHCP → ARP → TCP → HTTP) and compare the answer with the host:

| Target | host | through the helper |
| --- | --- | --- |
| `http://api.ipify.org/` | `104.28.192.14` | `104.28.192.14` |
| `http://www.google.com/` | `302` | `302` |

Same egress address, and the response carries `CF-RAY: …-LAX`, the same colo the host's own
`curl https://1.1.1.1/cdn-cgi/trace` reports (`warp=on colo=LAX`). The guest shares the
host's tunnel. Two consequences worth remembering when a guest site looks broken:

* A site the host cannot reach is unreachable from the guest as well, for the same reason.
  Check the host first (`curl`, `1.1.1.1/cdn-cgi/trace`) before blaming the VM network.
* DNS is the one non-transparent path: the helper answers the guest's queries through the
  host resolver (`192.168.127.1` forwards to `119.29.29.29` here), so name resolution
  follows the host's DNS rather than the tunnel's. WARP on `Mode: TunnelOnly` resolves with
  plain system DNS, and the guest inherits exactly that.

## Throughput: the tunnel is the ceiling, not the helper

Same host, same moment, same URL (`http://speed.cloudflare.com/__down?bytes=5000000`),
comparing a plain `curl` on the host with a probe driving the same unixgram transport the
guest NIC uses:

| Path | Throughput |
| --- | --- |
| host `curl`, through WARP | 1.37 / 0.71 / 1.34 MB/s (every round the same URL) |
| through the helper (the guest's path) | 1.19 / 1.61 / 1.65 MB/s |
| host `curl` to a domestic mirror (`mirrors.aliyun.com`) | 0.67 MB/s |

* **The helper adds nothing measurable.** Its rounds land in the same band as the host's
  own, so the userspace stack is not what limits a guest download.
* **The host is the limit.** `ping 1.1.1.1` measures ~168 ms RTT (the WARP egress landed in
  `LAX`), and the host's own downloads vary by 2x between rounds — the tunnel, not the VM,
  is where both the ceiling and the variance come from.
* **Domestic targets are the worst case.** WARP's split-tunnel list excludes private
  networks only, so traffic to a host in China still leaves through `LAX` and comes back.

MTU is not a factor either: `-mtu 1500` (the helper's default, and what it advertises via
DHCP option 26) and `-mtu 1280` (matching the tunnel) give the same TCP throughput, 1.61 vs
1.65 MB/s. TCP terminates inside the helper, so the guest-side MTU only shapes the local
unixgram link, never the tunnel.

Practical consequence: `--network tunnel` inherits the host VPN's performance, and there is
nothing to tune on the VM side. With the VPN off, `nat` goes through vmnet's in-kernel NAT
and is far faster — the two modes are complements, not alternatives.

## Diagnostics

Both switches are opt-in and read from the environment, so a boot that misbehaves can be
captured without new CLI surface:

| Variable | Effect |
| --- | --- |
| `VPHONE_NET_DEBUG=1` | helper runs with `-debug` and logs every frame it decodes into `net-helper.log` |
| `VPHONE_NET_PCAP=<path>` | helper runs with `-pcap <path>`; every frame the guest sends or receives lands in a libpcap file |

```bash
VPHONE_NET_DEBUG=1 make boot
VPHONE_NET_PCAP=/tmp/vp-net.pcap make boot
```

`VPHONE_NET_DEBUG` matches exactly `1`; anything else leaves the frame log off. The capture
is opened by the helper itself, so its directory must exist and be writable — otherwise the
helper exits immediately and the boot reports its log tail.

## Limits / risks

* **Extra binary, not a build dependency.** `make net_helper` pins `v0.8.9` +
  `sha256 c6f7b4bc7f21bf810b5cf54e04d979b014c5d96472a03a9e97fe62a00940067c`.
  Other versions verify against the release's `sha256sums`, and should be re-verified
  end-to-end (the vfkit transport is specified by convention, not by a stable API).
* **The helper also forwards `127.0.0.1:<ssh-port>` into the guest.** gvproxy defaults
  that to 2222, so the backend always passes a port it picked with `bind(:0)`; otherwise a
  second helper — or a helper next to any unrelated 2222 listener — exits immediately with
  `cannot add network services: listen tcp 127.0.0.1:2222: bind: address already in use`.
* **`gvproxy` must not be left behind.** `VPhoneTunnelNetwork` terminates it on `stop()`,
  registers every live instance for an `atexit` sweep (the CLI exits via `exit()` from
  the VZ delegate callbacks, which skips `deinit`), and removes both sockets. A SIGKILL
  of the CLI can still orphan it — `pkill gvproxy` if a port/subnet looks stale.
* **No port forwarding yet.** gvproxy can expose `-listen`/`-forward-*` control APIs; the
  backend currently starts it with only `-listen-vfkit`.
* **MAC is framework-assigned** in every mode; the manifest's `macAddress` stays unused,
  so DHCP allocations shift between boots (harmless, but it means no stable leases).
* **More host CPU** than vmnet for bulk traffic — TCP/UDP are terminated in userspace
  (throughput itself stayed at the host's own level, because the VPN tunnel was the
  ceiling — see Throughput).
* Modes `nat` / `bridged` remain for hosts without a VPN and are unchanged.
