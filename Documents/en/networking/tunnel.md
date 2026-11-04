# Tunnel mode

Use `tunnel` mode when the Mac's traffic goes through a VPN or a proxy app and the guest's traffic must go the same way. In `nat` and `bridged`, the guest's packets bypass the VPN.

## Turn it on

Stop the machine, then:

```sh
vphone-cli vm config <name> --network tunnel
```

In Launchpad, pick `tunnel` in the Network section of the machine's Settings…. The bundle must list `tunnel` in `vphone-cli vm config --help`; an older bundle rejects it.

## Check that it works

1. Start the machine and wait for it to finish booting.
2. Read the guest's address:

   ```sh
   vphone-launchpad-cli guest rpc <name> device.network
   ```

   `en0` should show `192.168.127.3`. If it shows only an `fe80::` address, DHCP has not finished yet. Wait a few seconds and try again.
3. Open a page in the guest:

   ```sh
   vphone-launchpad-cli guest rpc <name> apps.open_url '{"url":"https://example.com"}'
   ```

4. On the Mac, check that the connections belong to `vphone-vm` and use the VPN's address:

   ```sh
   lsof -nP -a -i -p "$(pgrep -f 'vphone-vm.*<name>')"
   ```

## What the guest sees

| Item | Value |
| --- | --- |
| Guest address | `192.168.127.3/24` by DHCP, or the [fixed address](addresses.md#fixed-address) |
| Gateway and DNS | `192.168.127.1`, or the first address of the fixed address's subnet |
| MTU | 1500 |
| DNS | Queries to `192.168.127.1` go to the Mac's resolver |
| Other connections to the gateway | The Mac's loopback, `127.0.0.1` (TCP and UDP) |

In a proxy app the guest shows up as its own client, named after the machine, and the app's rules apply to it as to any other app.

## Limits

- **IPv4 only.** The guest gets no IPv6 address, and IPv6 traffic is dropped.
- **Outbound only, apart from forwarded ports.** Nothing on the Mac or the LAN can reach the guest through this network except the ports listed under [Port forwarding](port-forwarding.md). USB access (`iproxy`, `ideviceinstaller`) and `vphone.sock` do not use the guest network, so they still work. A `.local` name also reaches the guest over its USB link; see [Names on the network](names.md).
- **Ping reaches the gateway only.** ICMP to the internet is not forwarded, so `ping 1.1.1.1` in the guest fails even while TCP and UDP work.
- **Throughput is limited by `vphone-vm`.** Every packet is handled in that process. Downloads and video work, but `nat` is faster when no VPN is involved.

## How it works

When a VPN owns the Mac's default route (WireGuard, Cloudflare WARP, or a proxy app in TUN mode such as Surge or Clash), packets that `nat` and `bridged` send out through a physical interface skip the VPN. They leave unencrypted, or not at all.

In `tunnel` mode the guest's network card is implemented inside `vphone-vm`. It answers DHCP, ARP and ping for the gateway, and turns each guest TCP connection and UDP flow into a normal socket on the Mac. Those sockets follow the Mac's routing table like any other app's, so the VPN carries them. It needs no root, no new network interface and no change to the Mac's network settings.

## See also

- [Networking](overview.md)
- [MAC and IP addresses](addresses.md)
- [Port forwarding](port-forwarding.md)
