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

## Intercept guest TCP through a SOCKS5 proxy

Tunnel mode can also send the guest's TCP through a SOCKS5 proxy, so a tool on the Mac can observe or filter the guest's connections. Stop the machine, then:

```sh
vphone-cli vm config <name> --intercept socks5://host:1080
```

This applies only in `tunnel` mode and takes effect at the next start. Each guest TCP connection is opened through the proxy with a SOCKS5 CONNECT to its original destination. Traffic to the gateway still connects directly to the Mac's loopback (`127.0.0.1`) and never goes through the proxy.

QUIC rides UDP, which the proxy does not carry, so a QUIC app would bypass the proxy. Add `--intercept-block-quic` to drop guest UDP to port 443, which makes those apps fall back to TCP the proxy can carry:

```sh
vphone-cli vm config <name> --intercept socks5://host:1080 --intercept-block-quic
```

`vphone-cli vm info <name>` shows the active proxy (with its password redacted) and whether QUIC blocking is on.

### Credentials

A proxy that needs a username and password takes them in the URL. Do not put a literal password on the command line: it is visible to `ps` and saved in your shell history, and it is stored in plaintext in the VM manifest on disk. Read it from the environment instead, with a single-quoted `${env:NAME}` token that `vphone-cli` resolves at each VM start:

```sh
vphone-cli vm config <name> --intercept 'socks5://user:${env:PROXY_PASS}@host:1080'
```

`vm config` only stores the token. The variable is read from the environment of the process that starts the VM, so set it on `vm launch`, not on `vm config`. Fill it from the keychain rather than typing the password, which would put it in your shell history:

```sh
PROXY_PASS="$(security find-generic-password -s <item> -w)" vphone-cli vm launch <name>
```

The single quotes keep the shell from expanding the token, so the password stays out of the command line and out of the manifest.

A VM started from Launchpad gets Launchpad's environment, which does not have the variable. The token is then undefined, the intercept fails closed, and guest TCP is reset until you start the VM from a process that has the variable.

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
