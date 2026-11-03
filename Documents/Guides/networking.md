# Networking

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Troubleshooting](troubleshooting.md)

Each VM has one network mode, stored in its `config.plist`. It is read when the
VM starts, so a change applies from the next launch.

| Mode | How the guest reaches the internet | Use it when |
| --- | --- | --- |
| `nat` | Virtualization.framework's built-in NAT | The default. The Mac has no VPN, or the VPN does not need to carry the guest. |
| `bridged` | Directly on a physical interface of the Mac, with its own address on that network | The guest has to be reachable from other machines on the LAN. |
| [`tunnel`](network-tunnel.md) | Through ordinary connections opened by `vphone-vm` on the Mac | The Mac's traffic goes through a VPN or a proxy app, and the guest's traffic must follow it. |
| `none` | No network device | The guest must stay offline. |

## Choosing a mode

In Launchpad, stop the machine, then choose Settings… from the `⋯` menu or the
right-click menu. The Network section has a Mode picker. New Machine sets the mode under
Advanced Options.

From the command line:

```sh
vphone-cli vm config <name> --network tunnel
# or through Launchpad
vphone-launchpad-cli exec vm config <name> --network tunnel
```

`tunnel` needs a `VPhone.bundle` that lists it in `vphone-cli vm config --help`.
An older bundle rejects the setting.

## Unplugging a running VM

`vm network` acts on a VM that is running, and nothing it does is saved:

```sh
vphone-cli vm network <name>               # state of the NIC
vphone-cli vm network <name> --link down   # unplug the cable
vphone-cli vm network <name> --link up     # plug it back in
```

The guest sees the link drop and come back. The same is available on
`vphone.sock` as `{"t":"network"}`, with `"link":"down"` or `"link":"up"`.

A running VM cannot move to another network. Virtualization accepts the
change and then stops the VM with an internal error, so `vm network` only ever
puts back the network the VM started on. Change the mode with `vm config` and
restart.

In Launchpad, Settings… has Address and Port Forwarding sections when one
machine is selected.

## Further reading

- [Tunnel mode](network-tunnel.md): why it exists, what the guest sees, its limits, and how to check it works.
- [MAC and IP addresses](network-addresses.md): the saved MAC address, leases held by old MACs, and fixed addresses.
- [Port forwarding](network-port-forwarding.md): carry a port on the Mac into the guest.
- [Names on the network](network-names.md): the guest's `.local` name, and this Mac's name in the guest.
- [Machines reaching each other](network-peers.md): `nat` machines on one shared network.
