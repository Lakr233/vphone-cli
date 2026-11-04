# MAC and IP addresses

This page covers the guest's saved MAC address, freeing DHCP leases that old MACs still hold, and giving a guest a fixed IPv4 address.

## MAC address

The first launch gives the guest's network card a random, locally administered MAC address and saves it in `config.plist`, the way it saves the machine identifier. The guest then keeps one identity, and one DHCP lease, across launches.

To set or replace it:

```sh
vphone-cli vm config <name> --mac 02:11:22:33:44:55
vphone-cli vm config <name> --mac random   # a new one now
vphone-cli vm config <name> --mac auto     # a new one at the next launch
```

A cloned machine keeps the MAC of the original, like its machine identifier. Before running both at once, either clone with `vm clone --new-identity`, which gives the copy a new identity and MAC, or give the copy a new MAC. `--new-identity` also clears the copy's fixed address, port forwards and mDNS name.

## Addresses held by old MACs

Symptom: in `nat` mode, new guests get higher and higher addresses, until they reach the fixed addresses you picked high in the range.

List the leases on the shared network and who owns each, then release the orphans (needs `VPhone.bundle` 2.5 or later):

```sh
vphone-cli vm leases
sudo vphone-cli vm leases --release-orphans
```

Through Launchpad:

```sh
vphone-launchpad-cli vm leases
vphone-launchpad-cli vm leases --release
```

In the Launchpad window, Host Setup shows the count under NAT Network, and Release… frees them after an administrator approves. Launchpad compares against every library it lists.

An orphan is an iOS or iPadOS guest's lease whose MAC belongs to no machine in the library and whose lease has run out. `--release-orphans` removes the orphans from `/var/db/dhcpd_leases` and has the DHCP server read the file again, so it needs root. It never touches:

- a machine's own lease, even one that ran out while the machine was stopped;
- a lease that has not run out, such as a running guest's whose MAC was just replaced;
- leases of other VM apps, or of devices on Internet Sharing.

Machines in another library count only when that library is named too: repeat `--library-root` for each. The release refuses to run when a library has no machines or a machine's settings cannot be read, since every lease there would look orphaned.

Why it happens: the Mac's DHCP server keeps each address bound to the MAC it was given to, even after the lease runs out, and hands it to anyone else only once every other address in the range is taken. Deleting a machine or replacing its MAC leaves its address bound to a MAC nothing uses any more, and so does every launch made before MACs were saved.

## Fixed address

`--ip` gives the guest a fixed IPv4 address. Without a prefix, `/24` is assumed. `--gateway` and `--dns` are optional; `auto` returns them to the default. `--ip dhcp` removes the fixed address.

```sh
vphone-cli vm config <name> --ip 192.168.65.50
vphone-cli vm config <name> --network tunnel --ip 10.20.0.5/16 --dns 1.1.1.1
vphone-cli vm config <name> --ip dhcp
```

How the address reaches the guest depends on the mode:

| Mode | Address | How it is applied |
| --- | --- | --- |
| `nat` | On the Mac's shared NAT network: normally `192.168.65.0/24`, or `192.168.64.0/24` for a machine with `--nat-peers off` (see [Machines reaching each other](peers.md)) | vphoned writes it into the guest's network settings. The gateway and DNS are the Mac, `192.168.65.1` or `192.168.64.1`. |
| `tunnel` | Any private subnet | The tunnel's own DHCP hands it out. The gateway, which is also the DNS resolver, is the subnet's first address unless `--gateway` names another. |
| `bridged` | An address on the physical network | vphoned writes it into the guest. Set `--gateway` and `--dns` to the network's own. |

> [!TIP]
> An address on the shared `nat` network is not reserved in the Mac's DHCP server. Pick one high in the range, such as `.200`, that DHCP is unlikely to have handed to another VM.

In `nat` mode the address has to be on the shared network the machine joins: the second one (`192.168.65.0/24`) for machines that reach each other, which is the default, or the first (`192.168.64.0/24`) with `--nat-peers off`. Both follow vmnet's `Shared_Net_Address` if it has been moved. For any other subnet, use `tunnel`.

vphoned applies the address each time `vphone-vm` connects to it, so a guest changed while the Mac was not looking is put back. It only undoes its own setting: an address typed into the guest's Settings app is left alone when the VM goes back to DHCP.

macOS 26 can give a VM a NAT network of its own, but the subnet then stays reserved after the VM stops (still reserved 40 minutes later in testing), and every launch on it fails meanwhile, so vphone does not use it.

## See also

- [Networking](overview.md)
- [Port forwarding](port-forwarding.md)
- [Machines reaching each other](peers.md)
