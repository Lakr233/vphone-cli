# Port forwarding

[Documentation](../README.md) · [Networking](networking.md) · [Addresses](network-addresses.md) · [Tunnel mode](network-tunnel.md)

`--forward` carries a port on the Mac into the guest, in `nat` and `tunnel`
modes. The form is `[tcp|udp:][host-address:]host-port:guest-port`. A forward
listens on `127.0.0.1` unless a host address is given; `0.0.0.0` makes it
reachable from other devices on the LAN.

```sh
vphone-cli vm config <name> --forward tcp:8022:22
vphone-cli vm config <name> --forward udp:0.0.0.0:5353:53
vphone-cli vm config <name> --remove-forward 8022
vphone-cli vm config <name> --clear-forwards
```

`vphone-vm` opens the listeners when the VM starts and closes them when it
stops. In `nat` mode it connects to the guest's address: the fixed one, or the
one vphoned reports. In `tunnel` mode the connection reaches the guest as if it
came from the gateway. A port that is already taken on the Mac is reported in
the VM's log and skipped; the rest still work. `bridged` puts the guest on the
LAN with its own address, so it needs no forwards.
