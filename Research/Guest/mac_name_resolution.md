# The Mac's `.local` name in the guest

A guest process doing a plain BSD `connect("<mac>.local")` hung. What the
guest's resolver returned, and what vphoned now does about it. User-facing
behaviour is in `Documents/en/networking/overview.md`.

Measured 2026-10-03 with vphoned's `network.resolve` and a temporary in-guest
probe (register a record, then `getaddrinfo(AF_INET)` every 20 ms) on a macOS
27.0.1 host (LocalHostName `JackyMacBook-Pro`): `pcc-research-01` and the
freshly created `nettest-01` (iOS 27.0, nat and tunnel), and `ipad-mini-01`
(iOS 26.6.2, nat).

## Two links to the Mac

Besides its NIC (`en0`), a guest has the network link a USB-connected iPhone
gives the Mac: `en1` (a self-assigned `169.254` address) and `anpi0` (IPv6
only) in the guest, an `enN` and an `anriN` on the Mac. The Mac announces its
name on all of them: `dns-sd -G v4v6 JackyMacBook-Pro.local` on the Mac lists
`192.168.64.1` on the NAT bridge, a `169.254` address on the USB-link `enN`,
and, for the A record on each `anriN`, "No Such Record" with a TTL of 1 s.

## What the guest's resolver returned

- Right after boot, `getaddrinfo(AF_INET)` failed in 1 ms with "nodename nor
  servname provided"; `AF_INET6` returned only `fe80::…%anpi0`. The negative
  answer over `anpi0` arrived first and the guest took it as final.
- Later, with answers cached from the other links, IPv4 lookups returned the
  Mac's `169.254` address on `en1` first, then `192.168.64.1`. They still
  failed now and then: with nothing registered, about one lookup in a
  thousand at 20 ms intervals (1 in 748, 1 in 76, 0 in 2199), as the 1 s
  negative is queried again and again.
- The first plain connect to the `169.254` address could leave through `en0`
  (source `192.168.64.61`) and time out: iOS routes `169.254.0.0/16` through
  the primary interface. Seen against the Mac's own TCP stack too.

`/etc/hosts` is not a way out: `/private/etc` is on the sealed System volume,
mounted read-only ("Read-only file system" on write).

## What a registered record does, by kind

mDNSResponder (`mDNSCore/mDNS.c`, mDNSResponder-2881) treats a record that is
LocalOnly *and* of a unique type as it treats an `/etc/hosts` line
(`UniqueLocalOnlyRecord`): it answers an address question at once, keeps the
question off the wire, and while it answers (`LOAddressAnswers`) cached
answers, positive or negative, are not delivered. An unverified `Unique`
record is never delivered to a question, and LocalOnly records are never
probed, so the flag that works is `kDNSServiceFlagsKnownUnique`.

What `getaddrinfo(AF_INET)` returned, with `JackyMacBook-Pro.local` →
`192.168.64.1` registered each way:

| Registration | Answer |
| --- | --- |
| none | `169.254.198.56, 192.168.64.1` |
| shared, on `lo0` | the cached answers plus `192.168.64.1`. A multicast record on loopback reaches the resolver through the cache, so the race stays, and each registration churned the cache (11 failures in the 2 s after one registration) |
| shared, LocalOnly | `169.254.198.56, 192.168.64.1, 192.168.64.1`, alongside the cache |
| known-unique, LocalOnly | `192.168.64.1` alone, from the first lookup |

With the known-unique LocalOnly record: 0 failures in 2210 and 2202 lookups
(60 s each), and 0 in each run right after registering; the answer was never
anything but `192.168.64.1`. Because the cache is not consulted, neither the
negative answer nor the `169.254` address reaches an IPv4 lookup, so nothing
needs routing over the USB link.

## What vphoned does

1. `vphone-vm` sends `<LocalHostName>.local` → the address the guest reaches
   the Mac at after every connect (the shared NAT host address, the tunnel
   gateway, or the Mac's address on the bridged interface), and an empty list
   without a NIC. vphoned registers it as a known-unique LocalOnly A record
   (`GuestStaticNames.swift`), saves it, and registers it again as it starts,
   so it is in place before apps run after a reboot. IPv6 lookups still go to
   mDNS and get the Mac's link-local addresses, which are scoped and work.
2. In tunnel mode the name points at the gateway, and connections to the
   gateway (other than DNS) are carried to the Mac's `127.0.0.1`. A refused
   connection now resets the guest with the acknowledgment number its
   SYN-SENT state requires; before, the guest dropped the `seq 0, ack 0` reset
   and retried its SYN until it timed out. iOS reports the refusal after about
   a second either way, as it does against the Mac's own stack.

`--mac-name off` withdraws the record and removes the saved file.
