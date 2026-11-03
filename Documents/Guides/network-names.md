# Names on the network

[Documentation](../README.md) · [Networking](networking.md) · [Addresses](network-addresses.md) · [Tunnel mode](network-tunnel.md)

## Name on the local network (mDNS)

Off by default. `--mdns on` makes the guest answer to `<vm-name>.local`, with
anything but letters and digits in the VM name turned into hyphens
(`ipad_pro.13` becomes `ipad-pro-13.local`). `--mdns <name>` picks another
name, and `--mdns off` puts the guest's own name back.

```sh
vphone-cli vm config <name> --mdns on
ping <vm-name>.local
```

vphoned sets the name in the guest's network settings (`LocalHostName`) each
time `vphone-vm` connects, and the guest's mDNSResponder announces it on every
link it has. Besides its network card, a guest has the network link a USB-connected
iPhone gives the Mac, which shows up on the Mac as an `en` interface with a
`169.254` address. So the name works in
every mode, `none` included:

| Mode | `<name>.local` resolves to |
| --- | --- |
| `nat` | The guest's address on the shared network, and its USB link address |
| `bridged` | The guest's LAN address, for every device on the LAN, and its USB link address on the Mac |
| `tunnel`, `none` | The guest's USB link address, on the Mac only |

The USB link address is link-local, but the Mac reaches the guest on it
directly, so in `tunnel` mode a connection to `<name>.local` reaches a guest
service without a port forward.

If another device already uses the name, mDNS renames the guest (`name-2`).
Renaming the VM with `vm rename` renames a name `--mdns on` derived from it;
one picked by hand stays. A VM stopped with `vm stop` or by closing its window
cannot withdraw its announcement, so the Mac's resolver keeps returning the
old address until the cached record expires, which for a host address is 75
minutes (TTL 4500 s).

## This Mac's name in the guest

On by default. The guest resolves this Mac's mDNS name (`scutil --get
LocalHostName`, plus `.local`) at once, to the address it reaches the Mac at:

| Mode | `<Mac>.local` in the guest |
| --- | --- |
| `nat` | The Mac on the shared network, usually `192.168.64.1` |
| `tunnel` | The gateway, `192.168.127.1` by default. Connections to it reach the Mac's loopback (`127.0.0.1`), the way `10.0.2.2` does in QEMU and VirtualBox |
| `bridged` | The Mac's address on the bridged interface |

Over mDNS alone, an IPv4 lookup of the Mac's name in the guest could fail. The
guest also hears the Mac on the network link a USB-connected iPhone gives the
Mac, where the Mac has no IPv4 address and answers "no such record". Whichever
link answers first decides the lookup, so an app that wants an IPv4 address
got an error until a real answer had been cached from another link.

vphoned registers the name with the guest's own mDNSResponder the way it
holds an `/etc/hosts` line: as a local record that answers an IPv4 lookup at
once, with that one address, without asking the network and without the
answers it has cached. It does so each time `vphone-vm` connects, and again
when vphoned starts, so the name is in place before apps run after a reboot.
The guest's system volume is read-only, so `/etc/hosts` itself is not edited,
and nothing is announced on any network. IPv6 lookups still go to mDNS.

Without it, a lookup also listed the Mac's `169.254` address on the USB link,
first. iOS routes `169.254.0.0/16` through its primary interface, so a plain
socket connecting to that address could leave through `en0`, where nothing
answers, and wait out its timeout.

```sh
vphone-cli vm config <name> --mac-name off   # withdraw it
```

To see what the guest's resolver returns, and whether each address connects:

```sh
vphone-launchpad-cli guest rpc <name> network.resolve '{"host":"<Mac>.local","family":"ipv4","port":8000}'
```
