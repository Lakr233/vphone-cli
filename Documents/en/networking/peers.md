# Machines reaching each other

`nat` machines on one Mac reach each other directly, Bonjour included. A virtual Apple Watch pairs with a virtual iPhone this way. This page shows how to keep one machine apart.

## Isolate a machine

```sh
vphone-cli vm config <name> --nat-peers off   # isolate this guest again
vphone-cli vm config <name> --nat-peers on    # the default
```

In Launchpad it is "Reach other NAT machines" in the machine's Network settings. The change applies from the next launch.

An isolated guest reaches the Mac and the internet, but not another VM. Isolation is a setting of each machine's own attachment, so a machine that opts out stays isolated whatever the others do.

## Which network a machine is on

| Setting | Shared network | The Mac's address |
| --- | --- | --- |
| `--nat-peers on` (default) | `192.168.65.0/24` | `192.168.65.1` |
| `--nat-peers off` | `192.168.64.0/24` | `192.168.64.1` |

A [fixed address](addresses.md#fixed-address) (`--ip`) must be on the network the machine joins. A machine whose fixed address is on the first network (`192.168.64.0/24`) stays isolated unless it asks for its peers, and then needs an address on the second one.

## Background

By default Virtualization.framework isolates each `nat` guest from the others on the Mac's shared network. vphone turns that isolation off, and vmnet then puts the machines that reach each other on a second shared network, the block after the first. The switch is private to Virtualization.framework; a version without it leaves every guest isolated and says so when the VM starts.

## See also

- [Networking](overview.md)
- [MAC and IP addresses](addresses.md)
- [Names on the network](names.md)
