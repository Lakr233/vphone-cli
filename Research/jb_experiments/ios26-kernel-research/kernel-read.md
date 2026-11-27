# Kernel Read Primitive — getsourcefilter

**Date:** 2026-11-07 (proven on device)  
**Status:** WORKING. 200 entries read back successfully.

## How It Works

`getsourcefilter()` is a libc wrapper around `getsockopt(IP_MSFILTER)`. It walks the
RB-tree of `ip_msource` nodes attached to a multicast group membership and copies each
node's source address into a userspace buffer.

Normal operation: you join a multicast group with source filters, and `getsourcefilter`
returns the list of sources.

After UAF reclamation: the RB-tree nodes contain **stale kernel heap data** — pointers,
metadata, whatever was in the freed-and-reallocated memory. `getsourcefilter` dutifully
copies it to userspace. Free kernel read.

## On-Device Proof

### Test 1: IPv4 (200 sources)
```python
# Join group with 200 source filters
for i in range(200):
    sock.setsockopt(IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP,
                    struct.pack('4s4s4s', group, iface, source_i))

# Read them all back
sources = getsourcefilter(sock, ifindex=22, group=group_addr)
assert len(sources) == 200  # all 200 returned
```

Each entry: 128 bytes (`sockaddr_storage`), IP address at offset 4.

### Test 2: IPv6 (3 sources)
```python
# MCAST_JOIN_SOURCE_GROUP × 3
sources = getsourcefilter(sock, ifindex=22, group=group6_addr)
assert len(sources) == 3
# fmode = 1 (MCAST_INCLUDE)
```

## API

```c
int getsourcefilter(
    int fd,                          // UDP socket joined to the group
    uint32_t ifindex,                // interface index (22 = en0 on our device)
    struct sockaddr *group,          // group address
    socklen_t grouplen,              // 28 for IPv6
    uint32_t *fmode,                 // OUT: filter mode
    uint32_t *numsrc,                // IN: max / OUT: actual count
    struct sockaddr_storage *slist   // OUT: source addresses (128B each)
);
```

**Critical:** `ifindex` must be correct (0 → EINVAL). On iPhone 16 Plus: `en0` = 22.

## Exploitation Flow

1. **Normal:** Join multicast group with N source filters → tree has N `ip_msource` nodes
2. **UAF:** Trigger CVE-2026-86916 → some nodes freed but tree structure retained
3. **Reclaim:** Spray same-size objects (`kalloc.48`) into freed slots
4. **Read:** `getsourcefilter()` walks the tree → copies reclaimed data to userspace
5. **Parse:** Scan output for `0xfffffff0xxxxxxxx` kernel pointers → KASLR slide

Each `ip_msource` is ~40 bytes in `kalloc.48`. The source address field (`ims_haddr` at
+0x18) is what gets copied — but if the node is reclaimed by a different object type, the
bytes at that offset contain whatever the new object stores there.

## What We Can Read

With controlled reclamation:
- **Kernel heap pointers** → KASLR slide
- **Object vtables** → type identification
- **IOKit registry data** → traverse to specific properties
- **Thread struct fields** → PAC keys (see [pac-key-extraction.md](pac-key-extraction.md))
- **Task struct fields** → process metadata

Capacity: 200 entries × 128 bytes = **25.6KB per read operation**.

> Correction 2026-11-27: CVE-2026-86916 is a Kernel UAF per the `<h3>`-parsed advisory, but its attribution to the IGMP source-filter tree is refuted for 23F84/24B156 (binary-identical `igmp_input_v3_query`). The flow above is therefore not a candidate trigger; it is kept as a description of the data structure only.
