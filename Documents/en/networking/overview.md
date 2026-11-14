# Networking

Each VM has one network mode. This page shows how to pick it and how to unplug a running VM's network; the other pages in this section cover tunnel mode, addresses, port forwarding, names and machines reaching each other.

## Network modes

| Mode | How the guest reaches the internet | Use it when |
| --- | --- | --- |
| `nat` | Virtualization.framework's built-in NAT | The default. The Mac has no VPN, or the VPN does not need to carry the guest. |
| `bridged` | Directly on a physical interface of the Mac, with its own address on that network | The guest has to be reachable from other machines on the LAN. |
| [`tunnel`](tunnel.md) | Through ordinary connections that `vphone-vm` opens on the Mac | The Mac's traffic goes through a VPN or a proxy app, and the guest's traffic must follow it. |
| `none` | No network device | The guest must stay offline. |

The mode is stored in the VM's `config.plist` and read when the VM starts, so a change applies from the next launch.

## Choose a mode

In Launchpad:

1. Stop the machine.
2. Choose Settings… from the `⋯` menu or the right-click menu.
3. Pick the mode in the Network section.

New Machine sets the mode under Advanced Options. With one machine selected, Settings… also has Address and Port Forwarding sections.

From the command line:

```sh
vphone-cli vm config <name> --network tunnel
# or through Launchpad
vphone-launchpad-cli exec vm config <name> --network tunnel
```

`tunnel` needs a `VPhone.bundle` that lists it in `vphone-cli vm config --help`. An older bundle rejects the setting.

## Unplug a running VM

`vm network` acts on a running VM, and nothing it does is saved:

```sh
vphone-cli vm network <name>               # state of the NIC
vphone-cli vm network <name> --link down   # unplug the cable
vphone-cli vm network <name> --link up     # plug it back in
```

The guest sees the link drop and come back. The same request is available on `vphone.sock` as `{"t":"network"}`, with `"link":"down"` or `"link":"up"`.

> [!NOTE]
> A running VM cannot move to another network. Virtualization accepts the change and then stops the VM with an internal error, so `vm network` only ever puts back the network the VM started on. To change the mode, use `vm config` and restart the VM.

## See also

- [Optional guest SOCKS5 server](../../../Addons/SOCKS5/README.md) for TCP connections and UDP datagrams through a NAT guest.
- [Tunnel mode](tunnel.md): a Mac behind a VPN or proxy app
- [MAC and IP addresses](addresses.md): the saved MAC, leases held by old MACs, fixed addresses
- [Port forwarding](port-forwarding.md): carry a port on the Mac into the guest
- [Names on the network](names.md) and [Machines reaching each other](peers.md)
