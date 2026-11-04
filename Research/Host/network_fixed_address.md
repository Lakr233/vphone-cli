# Guest MAC, fixed address, port forwarding and names

What was tried on a real guest before settling the design in
`VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift`, and why some of it
was taken out again. User-facing behaviour is in
`Documents/en/networking/overview.md`.

Tested on 2026-10-02: macOS 27.0.1 (26A434) host, `pcc-research-01` guest
(iOS 27.0, 24A435, cloudOS 26.4), launched headless from a local bundle.

## A fixed MAC does not break guest networking

`c6fa19e` left the MAC to Virtualization, noting that forcing one broke guest
networking. Without a fixed MAC every launch gets a new random one, so a NAT
guest takes a new DHCP lease, and usually a new address, each time.

`vphone-vm` now generates a random, locally administered, unicast MAC on first
launch and saves it in `config.plist` (`networkConfig.macAddress`), the way it
saves `machineIdentifier`. With `aa:73:76:98:a7:06`:

- the guest got `192.168.64.20` from vmnet's DHCP on `en0`;
- the Mac's ARP table showed the guest at that MAC on the shared bridge;
- ping from the Mac, and DNS and HTTPS from the guest (Safari opening
  `https://example.com`, seen with `network.capture`), all worked.

Whatever broke before was not a fixed MAC as such. One likely cause is the same
MAC on several VMs, for example from a manifest template: two guests on one
L2 network with one MAC cannot both work. Each VM now gets its own, and a clone
keeps the original's, like its machine identifier, unless made with
`vm clone --new-identity` ([machine identity and clone](machine_identity_and_clone.md)).

## Leases held by MACs no machine uses

Read from bootp-534.120.2 (`bootpd.tproj/dhcpd.c`, `bootplib/NICache.c`) and
checked against `/var/db/dhcpd_leases` on 2026-10-04.

- bootpd looks a client up by its identifier (`1,<mac>`) first. An entry is
  a binding: an expired lease is renewed in place, with the same address.
- A new client gets an address no entry holds (`acquire_ip`). Expired entries
  are reclaimed (`DHCPLeases_reclaim`, oldest first) only when that fails, so
  a full pool reclaims a stopped machine's lease as readily as a dead one's.
- On the test Mac the file held 130 entries, `192.168.64.2` to `.131`: 125
  `iPhone`/`iPad` entries for MACs no machine had (random MACs from launches
  before `macAddress` was saved, and deleted test machines), the five
  machines' own, and four `ManagedlMachine` entries from another app.
- The `name` is the client's host name option. IPConfiguration sends the
  device type (`get_device_type`) when the network is private, which is how
  iOS treats it, so a vphone guest is always `iPhone` or `iPad`, whatever
  `--mdns` set. `vm leases` uses that, the shared subnet, and an expired lease
  to tell a guest's dead binding from another app's or a live one.
- bootpd re-reads the file on SIGHUP, before it handles the next packet, and
  writes it only while handling one (`<file>-` then `rename`). It is started
  on demand by launchd (`bootps.plist`) and exits when idle. `--release-orphans`
  checks the file did not change between read and rename, renames a copy
  with the same owner and mode over it, sends SIGHUP to any running bootpd,
  and posts `com.apple.bootpd.DHCPLeaseList` as bootpd does.
- DHCPRELEASE from the host is no substitute: bootpd answers it by setting
  the entry's lease to now (`dhcp_msgtype_release_e`), which is exactly the
  state of every orphan already.

## Fixed address in nat mode: the shared network only

vphoned writes a manual IPv4 configuration into the guest's network
preferences (`network.ipv4.set`, `VPhoneDaemon/Native/vphoned_network.m`).
With `--ip 192.168.64.210`:

- `network.ipv4.get` reported `method: manual`, `managed: true`, router
  `192.168.64.1`, and `en0` carried `192.168.64.210`;
- ping from the Mac, and DNS (now sent to `192.168.64.1`) and HTTPS from the
  guest worked.

### vmnet networks of the VM's own were tried and dropped

macOS 26 added `vmnet_network_configuration_create` and
`VZVmnetNetworkDeviceAttachment`, which give a VM a NAT network on a subnet of
its choosing. Three findings:

1. **The subnet address is the host's address.**
   `vmnet_network_configuration_set_ipv4_subnet` with `192.168.70.0` creates a
   network, but the VM's interface then fails at start with
   `VZErrorDomain Code=1` "internal network error", and the attachment is
   detached. A default network reports `192.168.65.1` from
   `vmnet_network_get_ipv4_subnet`. Passing `192.168.71.1` works: the Mac gets
   a `bridgeN` at `192.168.71.1`, and the guest, at `192.168.71.10`, had ping,
   DNS, HTTPS and a forwarded port.
2. **A DHCP reservation broke creation.**
   `vmnet_network_configuration_add_dhcp_reservation` returned success, and
   `vmnet_network_create` then returned `VMNET_FAILURE` (1001). (This may have
   been finding 3 instead: the reserved run came straight after a run on the
   same subnet.)
3. **A used subnet stays reserved.** Once a VM on `192.168.71.1/24` stopped
   (`vm stop`, which ends `vphone-vm` with SIGINT; Virtualization reports an
   unexpected stop, as it does for every `vm stop`), every later
   `vmnet_network_create` on that subnet failed with `VMNET_FAILURE`, retried
   every 30 seconds for six minutes. `192.168.70.0/24` was still refused 40
   minutes after its last use. Releasing the `vmnet_network_ref` explicitly
   (`CFRelease` in `applicationWillTerminate`, logged) did not help: a fresh
   `192.168.72.0/24` was refused straight after one stop too. Only
   `/usr/libexec/InternetSharing` (root) was involved; nothing in `vphone-vm`
   was still alive.
   (2026-10-05: the unexpected stop came from `vm stop` sending SIGINT to
   Virtualization's service, the process holding the disk, rather than to
   `vphone-vm`. `vm stop` now finds `vphone-vm` by its `--config` and stops
   it, and the VM exits with status 0. Whether a subnet stays reserved after
   such a stop has not been tested again.)

A fixed address that works for one launch is not a fixed address, so nat
accepts addresses on the shared network only (`Shared_Net_Address` and
`Shared_Net_Mask` in `/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist`,
default `192.168.64.1/24`), and tunnel covers other subnets. The subnets used
in testing (`192.168.70`, `.71`, `.72`) may stay unusable for vmnet on that
Mac until whatever holds them lets go.

To revisit: check whether a clean guest power-off (`guestDidStop`) frees the
subnet, whether a restart of InternetSharing does, and whether
`vmnet_network_copy_serialization` lets one network be reused across launches.

## Port forwarding

Listeners live in `vphone-vm` (`VPhonePortForwarder`), on `127.0.0.1` unless a
host address is given.

- nat: a forward from `127.0.0.1:18078` to guest port 62078 (lockdownd) made
  vphone-vm connect from `192.168.64.1` to `192.168.64.210:62078`; a capture in
  the guest showed the handshake. lockdownd closes unpaired network
  connections at once, directly and through the forward alike, so it shows
  the connection, not data. Data both ways, half-close and UDP are covered by
  `VPhonePortForwardingTests` over loopback.
- tunnel: covered by the same tests, which drive the userspace network's frame
  loop: SYN to the guest from the gateway, SYN-ACK, data both ways, and a
  guest RST closing the client.

## Changing the attachment of a running VM

`VZNetworkDevice.attachment` is settable while the VM runs.

- Setting it to nil and then back to the attachment the VM started with works:
  ping stopped, and came back about three seconds after the replug.
  `vm network --link down|up` does exactly this.
- Setting it to a new `VZNATNetworkDeviceAttachment` stopped the VM with
  `VZErrorDomain Code=1` "internal virtualization error" within seconds. So
  there is no runtime switch to another network; a mode change needs a restart.

## mDNS name

`--mdns` sets `System/Network/HostNames/LocalHostName` in the guest's network
preferences (`network.hostname.set`); the guest's mDNSResponder picks the new
name up at once, with no restart.

- nat: `pcc-research-01.local` resolved on the Mac to the guest's shared
  network address (and its IPv6 addresses), and answered ping.
- Every mode, `none` included: the guest also announces the name over the
  network link a USB-connected iPhone gives the Mac (`en1` and `anpi0` in the
  guest; on the Mac an `enN` with a `169.254` address and an `anriN`). With no
  network device, `lab-none-test.local` resolved to `169.254.96.74`, and in
  tunnel mode the Mac pinged the guest's link address and opened TCP 62078 on
  it.
- A first design registered `<name>.local` → `127.0.0.1` with the Mac's
  mDNSResponder (`DNSServiceRegisterRecord` on `lo0`; a LocalOnly record
  registered as `kDNSServiceFlagsUnique` showed in `dns-sd` but not in
  `getaddrinfo`, since an unverified unique record is never delivered to a
  question, see "The Mac's name in the guest" below) for tunnel guests. The guest's
  own announcement over the USB link claimed the same name, the Mac's record
  lost the conflict, and it was dropped. The guest's announcement is all that
  is needed.
- `vm stop` gives the guest no chance to send mDNS goodbyes, so the Mac's
  cache keeps the last address for the record's TTL, 4500 s.
- `network.hostname.set` with a null name put back the guest's original
  `iPhone` and removed the marker; a second call reported `changed: false`.

## The Mac's name in the guest

Reported from another session: a guest process doing a plain BSD
`connect("jackymacbook-pro.local")` hung. Measured with vphoned's
`network.resolve` on `pcc-research-01` (NAT, Mac `JackyMacBook-Pro`).

### What the guest's resolver returned

- Right after boot, `getaddrinfo(AF_INET)` failed in 1 ms with "nodename nor
  servname provided"; `AF_INET6` returned only `fe80::…%anpi0`, the Mac on the
  virtual iPhone's private USB link. The Mac does announce
  `JackyMacBook-Pro.local` → `192.168.64.1` on the NAT bridge (`dns-sd -G`
  lists it on `bridge103`), but on its `anriN` interfaces, the other end of the
  guest's `anpi0`, it answers A with "No Such Record". That link answers first,
  and the guest returns the negative.
- Minutes later the same lookup returned `192.168.64.1` and the Mac's `169.254`
  address on the USB link (`en1` in the guest), once those answers had been
  cached. So the failure is a race whose outcome depends on timing.
- With both cached, the `169.254` address is listed first (link-local sorts
  first). The first connection to it left through `en0` (source
  `192.168.64.61`) and timed out: iOS routes `169.254.0.0/16` through the
  primary interface only. Later connections left through `en1` and worked.
  This was seen against the Mac's own TCP stack too, with no tunnel involved.

### What did not work

- `/etc/hosts`: `/private/etc` is on the sealed System volume, mounted
  read-only ("Read-only file system" on write). An earlier test that appeared
  to work was reading cached mDNS answers.

### What is in place

1. vphoned registers `<LocalHostName>.local` → the address the guest reaches
   the Mac at as a LocalOnly, known-unique A record (`GuestStaticNames.swift`),
   saves it, and registers it again when it starts. mDNSResponder
   (`mDNSCore/mDNS.c`, mDNSResponder-2881) treats a LocalOnly record of a
   unique type as it treats an `/etc/hosts` line (`UniqueLocalOnlyRecord`): it
   answers an address question at once, keeps the question off the wire, and
   while it answers (`LOAddressAnswers`) cached answers, the negative one
   included, are not delivered. An unverified `Unique` record is never
   delivered and LocalOnly records are never probed, hence
   `kDNSServiceFlagsKnownUnique`.
2. In tunnel, the name points at the gateway, and connections to the gateway
   (other than DNS) are carried to the Mac's `127.0.0.1`. A refused connection
   now resets the guest with the acknowledgment number its SYN-SENT state
   requires; before, the guest dropped the `seq 0, ack 0` reset and retried its
   SYN until it timed out. iOS reports a refused connect after about one second
   either way, against the Mac's own stack too.

What `getaddrinfo(AF_INET)` returned on `nettest-01` (iOS 27.0, nat), with
`JackyMacBook-Pro.local` → `192.168.64.1` registered each way, polling every
20 ms:

| Registration | Answer |
| --- | --- |
| none | `169.254.198.56, 192.168.64.1`; about one failure in a thousand lookups (1 in 748, 1 in 76, 0 in 2199) |
| shared, on `lo0` (the first version) | the cached answers plus `192.168.64.1`; the race stays, and each registration churned the cache (11 failures in the 2 s after one registration on `pcc-research-01`) |
| shared, LocalOnly | `169.254.198.56, 192.168.64.1, 192.168.64.1`, alongside the cache |
| known-unique, LocalOnly | `192.168.64.1` alone, from the first lookup; 0 failures in 2210 and 2202 lookups (60 s each) and in every run right after registering |

Since the cache no longer reaches an IPv4 lookup of the name, the `169.254`
address is not returned either. The first version also routed
`169.254.0.0/16` through the USB link (two `/17` routes) so that address
would connect; that is gone with the shared `lo0` record.

`--mac-name off` withdraws the record and removes the saved file.
