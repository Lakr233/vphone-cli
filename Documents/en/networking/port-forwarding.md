# Port forwarding

Use `--forward` to carry a port on the Mac into the guest in `nat` and `tunnel` modes. `bridged` puts the guest on the LAN with its own address, so it needs no forwards.

## Add and remove forwards

```sh
vphone-cli vm config <name> --forward tcp:8022:22
vphone-cli vm config <name> --forward udp:0.0.0.0:5353:53
vphone-cli vm config <name> --remove-forward 8022
vphone-cli vm config <name> --clear-forwards
```

The form is:

```text
[tcp|udp:][host-address:]host-port:guest-port
```

| Part | Meaning |
| --- | --- |
| `tcp` or `udp` | Protocol |
| `host-address` | Where the forward listens on the Mac. The default is `127.0.0.1`; `0.0.0.0` makes it reachable from other devices on the LAN. |
| `host-port` | Port on the Mac |
| `guest-port` | Port in the guest |

Repeat `--forward` for more ports. In Launchpad, the machine's Settings… has a Port Forwarding section.

## How forwards behave

- `vphone-vm` opens the listeners when the VM starts and closes them when it stops.
- In `nat` mode it connects to the guest's address: the [fixed one](addresses.md#fixed-address), or the one vphoned reports.
- In `tunnel` mode the connection reaches the guest as if it came from the gateway.
- A port that is already taken on the Mac is reported in the VM's log and skipped; the other forwards still work.

## See also

- [Networking](overview.md)
- [Tunnel mode](tunnel.md)
- [MAC and IP addresses](addresses.md)
