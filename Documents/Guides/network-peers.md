# Machines reaching each other

[Documentation](../README.md) · [Networking](networking.md) · [Addresses](network-addresses.md) · [Names on the network](network-names.md)

In `nat`, Virtualization.framework isolates each guest from the others on the
Mac's shared network by default: a guest reaches the Mac and the internet, not
another VM. vphone turns that isolation off, so `nat` machines reach each other
directly, Bonjour included. A virtual Apple Watch pairs with a virtual iPhone
this way. A machine that should stay apart opts out:

```sh
vphone-cli vm config <name> --nat-peers off   # isolate this guest again
vphone-cli vm config <name> --nat-peers on    # the default
```

In Launchpad it is "Reach other NAT machines" in the machine's Network
settings. It applies from the next launch.

vmnet puts the machines that reach each other on a second shared network, the
block after the first: 192.168.65.0/24 beside 192.168.64.0/24, with the Mac at
192.168.65.1. A fixed address (`--ip`) goes on that network; a machine whose
fixed address is on the first network keeps its isolation unless it asks for
its peers, and then needs an address on the second one. Isolation is a setting of each
machine's own attachment, so a machine that opts out keeps vmnet's isolation
whatever the others do. The switch is private to Virtualization.framework; a
version without it leaves every guest isolated and says so when the VM starts.
