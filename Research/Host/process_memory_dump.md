# Process and physical memory dumps from the host

How the Processes window's **Save Memory Dump…**, the **Physical memory
image** checkbox and the control socket's `process.dump` and
`memory.dump {"physical":true}` read guest memory without the guest's help,
how they find a process in it, and what was measured. The user's side is
[Memory Dumps](../../Documents/en/machines/memory-dumps.md); the code is in
`VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/GuestMemory/`, and
`VPhoneExecutable/VPhoneVirtualization/Tests/run-guest-memory-tests.sh`
checks the page-table walk, the device-tree reader, both writers and every
shipped symbol map offline. The kernel cores of
[`memory_dump.md`](memory_dump.md) are unchanged.

Measured 2026-11-20 on a MacBook Air with 16 GB RAM, macOS 27.2.1 (`26B131`),
one guest running at a time, 8 GB RAM each, created with `--preset minimal`:

| Machine | Device and iOS | Kernel (symbol map) |
| --- | --- | --- |
| `mp-186` | iPhone11,6, iOS 18.6 (`22G86`) | `18.6_22G86` |
| `mp-265` | iPhone17,3, iOS 26.5 (`23F77`) | `vphone600_26.4_23E5207q` |
| `mp-272` | iPhone17,3, iOS 27.2 (`24B119`) | `27.2_24B119` |

## Reading guest RAM

Virtualization keeps guest RAM in its service process
(`com.apple.Virtualization.VirtualMachine`, the one that runs the AP; the SEP
has a second, small one) as `VM_MEMORY` tag 240 regions: one for DRAM and a
10 MB one for the firmware carve-outs directly below it. `vphone-vm` asks the
VM for that process with `-[VZVirtualMachine _serviceProcessIdentifier]`
(it returns an `int`, so it is called through its implementation), takes its
task port with `task_for_pid`, and maps both regions into itself with
`mach_vm_remap` (no copy, `VM_INHERIT_NONE`), then makes the view read-only.
`task_for_pid` on that platform binary needs `com.apple.security.cs.debugger`
in `VPhoneVirtualization.entitlements` and SIP's debugging restrictions off,
which Host Setup already requires. A read is then a memory access.

Guest physical addresses come from the device tree iBoot leaves in low DRAM:
`dram-base` places DRAM (`0x70a00000` on all three guests), and the
`region-id-N` carve-outs below it identify the small region.

Reading a page through the mapping that the guest never used makes the host
allocate it. On `mp-272` (with a second VM restoring beside it) a first
`memcmp` pass over the 8 GB view took 60.1 s and a second 3.0 s. The
physical image therefore asks the service with `mach_vm_page_range_query`,
while the guest is paused, which pages it ever gave memory (resident or paged
out), and leaves the rest as holes without reading them. The same query
showed how much of a guest the host had pushed out: 1.3 GB of 8 GB resident
and 6.9 GB compressed or swapped, all of it to be decompressed for a full
image.

## Finding a process

Everything below comes from guest RAM; vphoned only lists the processes the
user chooses from, and its pid is checked against the kernel's `p_comm`.

1. **Kernelcache.** The `MH_FILESET` header (`0xfeedfacf`, `CPU_TYPE_ARM64`,
   filetype 12) is in DRAM, page-aligned. Its `com.apple.kernel` entry gives
   the kernel's `LC_UUID` and segments. iBoot loads the cache in one piece,
   so `__TEXT` and `__DATA_CONST` sit at the header's physical address plus
   their file offsets; SPTM moves `__TEXT_EXEC` and `__DATA` elsewhere. The
   segment addresses in the in-memory header are the runtime ones, KASLR
   included. Any app can write such a header into its own memory, so every
   header whose kernel UUID has a symbol map is a candidate, lowest first
   (see [Planted kernelcache headers](#planted-kernelcache-headers)).
2. **Kernel page tables.** The root table (`TTBR1_EL1`) is the page of DRAM
   through which three addresses in each of `__TEXT` and `__DATA_CONST`
   translate to where step 1 found them. One pass over DRAM lists the pages
   whose entry for the kernel's first address is a table descriptor into DRAM
   (about 2,800 of 524,288 on a booted 27.2 guest); each candidate is checked
   against that list. The tables use a 16 KB granule, three levels of 2048
   entries at bits 36, 25 and 14, with 64 GB and 32 MB blocks.
3. **Symbols.** The kernel UUID selects a symbol map among the kernelcache
   recipes (`bases/`, `kernels/`, `donors/`), whose manifests now carry
   `kernelUUID` and `kernelSegments`, so a symbol is a segment and an offset.
   Two are needed: `_kernproc` (the `proc` of pid 0) and `_kernel_pmap`. The
   latter is checked: its `tte` must translate to its `ttep`, which must be the
   root from step 2.
4. **Process list.** From `kernproc`, `p_list.le_prev` (offset 8, `p_list`
   being first) leads to older-to-newer processes: launchd, then the rest; the
   walk stops at an address inside the kernel image, the head `allproc`.
   Kernel pointers carry PAC; the upper 17 bits are set again
   (`p | 0xffff800000000000`).
5. **Offsets.** No offset table is shipped. `p_pid` is, among the offsets at
   which kernel_task reads 0 and launchd 1, the one with the most distinct
   values over the whole list. The first version took the first offset whose
   values were distinct over the 32 oldest processes and found 0x24 on every
   kernel: a field that starts the same way (most likely the responsible pid)
   and equals the pid for early daemons, but repeats for XPC services.
   Requiring every value distinct over the whole list failed once while the
   guest was paused. `p_comm` is where kernel_task and launchd have their
   names. The map and pmap pointers are the first pair of offsets (proc to
   map, map to pmap) at which, for eight processes, the pointer chain ends in
   a pmap whose `tte` translates to its `ttep`. The task follows the proc in
   one allocation, so this finds `task->map` without the task's offset. Each
   process dump's `info.json` records the offsets it used.

| Field, as found | 18.6 | 26.4 donor (`mp-265`) | 27.2 |
| --- | --- | --- | --- |
| `p_pid` | 0x60 | 0x60 | 0x60 |
| `p_comm` | 0x56c | 0x56c | 0x55c |
| proc to `task->map` | 0x768 | 0x770 | 0x790 |
| `map->pmap` | 0x40 | 0x58 | 0x58 |

6. **Address space.** The process's pmap `ttep` is the root of its user
   tables (`TTBR0_EL1`). Every valid entry below 2^47 becomes a mapping, and
   adjacent mappings with one protection become one `LC_SEGMENT_64` of a
   Mach-O `MH_CORE` (`CPU_TYPE_ARM64`, `CPU_SUBTYPE_ARM64E`), without thread
   commands. Protection is read, plus write when `AP[7:6]` is 01, plus
   execute when `UXN` is clear.

The guest is paused from before step 1 to the last byte written, so the list,
the tables and the pages are one state.

### Symbol maps

A first pass checked every map's `_kernproc` and `_kernel_pmap` against code
that uses them (`_proc_pid` compares with `kernproc`; `kernel_pmap` is a const
pointer to `kernel_pmap_store`, which 140 to 170 functions reference) and
against same-name functions of the macOS 15.7.3, 26.1 and 26.5.1 KDKs. All 16
were right, so the existing maps are unchanged: the mixer hashes them into
its cache key, and an edit would change mixed kernelcaches. The manifests only
gain `kernelUUID` and `kernelSegments`, which the mixer does not read. The
vphone600 26.2 (`23C55`) and 26.3 (`23D129`) kernels got maps under
`kernels/`; how they and the two keys are made is in the recipes'
[README](../../VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes/README.md).

The same pass found `_get_task_map` wrong in eleven maps and missing in four
(the one leaf that loads `[x0,#0x28]` with discriminator `0x5ef8`). The dump
does not use it; the correction belongs to the mixer and is kept apart.

## Guest data is untrusted

Every byte the dump reads is guest memory, and any app in the guest can write
a device-tree property, a Mach-O header or a page-table-like page into its own
memory, which then sits somewhere in DRAM. None of it may crash or hang
`vphone-vm`:

- No sum of guest values can trap: addresses are compared by difference
  (`offset <= size`, `count <= size - offset`), carve-outs and segments whose
  end would pass 2^64 are dropped, and kernel pointer arithmetic wraps (`&+`).
- A load command is used only if it holds its fields (`LC_SEGMENT_64` 72
  bytes, `LC_UUID` 24, `LC_FILESET_ENTRY` 32), lies within `sizeofcmds`, and
  that within the mapped region.
- The device-tree search looks at no more than 4,096 matches of a name, and
  removes duplicates with a set.
- A header is read only with at most 4,096 load commands in 1 MB and at most
  64 segments; the real kernelcache has 159 commands in 11 KB. Headers whose
  kernel UUID has no symbol map are passed over without cost, and up to 16,384
  others are checked as described below.
- A page-table walk reads each table page at most once (a table that points
  back to itself or is shared is not walked again), at most 65,536 tables,
  and refuses a process with more than 2^21 pages, or with more than twice the
  guest's RAM, instead of writing it out. The process list stops after 20,000
  entries.
- The mapping and the device-tree search run off the main actor, so the
  window and the control socket stay responsive; only the service's pid is
  asked for on it.
- The view of guest RAM is read-only with a read-only maximum protection; a
  failure to set either ends the dump.
- If Virtualization cannot resume the guest, even after a second try, a saved
  dump is kept and the reply (`resume_error`) or the alert says the guest is
  still paused.

`run-guest-memory-tests.sh` covers each case with malformed input behind a
guard page, so a read past the data crashes the test.

### Planted kernelcache headers

The kernel hands out memory below the kernelcache. In a physical image of a
booted 27.2 guest (349 processes), the kernelcache was at DRAM + 58 MB, the
lowest page any process mapped was at DRAM + 32 KB (`photoanalysisd`), and
29,338 user mappings lay below the kernelcache. So an app can hold a copy of
the real header, UUID included, at a lower address than the real one.

A copy cannot pass the check. Its `__TEXT` and `__DATA_CONST` addresses
translate, through the kernel's tables, to the real kernelcache's pages and
not to the copy's own; tables of its own that translate them to the copy
would need the physical addresses of its pages, which an app does not know.
What a copy can cost is time, which is bounded: candidates are checked
lowest first against one list of possible roots, so each costs a few
thousand table lookups, and the limit of 16,384 is more than the pages below
the kernelcache (about 3,700), so copies there cannot use it up before the
real header is reached. Headers above it are never looked at. With this,
process dumps on that guest still paused it for 3.2 to 3.5 s.

`TTBR1_EL1` itself is in the Virtualization service's own memory, where the
guest cannot write: Hypervisor.framework keeps one 16 KB state page per
vCPU (VM tag 28, read-write, followed by a read-only page whose first word
holds the bytes `hyp`), and on macOS 27.2 all five pages of a five-vCPU guest
held the root found above at offset `0x3c0`, next to another root at `0x3b8`
(probably `TTBR0_EL1`) and a `TCR`-like value at `0x3c8`. The dump does not
use it: the layout is private, checked on one macOS release only, and the
search above reaches the same root without it.

## Measurements

| What | 18.6 | 26.5 | 27.2 |
| --- | --- | --- | --- |
| Remap and kernel found | – | – | 1.6 s, then 0.1 s |
| Processes walked | – | 436 | 362 |
| launchd: segments, size, guest paused | 11,954, 836 MB, 2.0 s | 14,590, 916 MB, 0.7 s | 13,887, 768 MB, 0.8 s |
| SpringBoard: segments, size, guest paused | 13,909, 996 MB, 1.4 s | 15,543, 991 MB, 0.7 s | 18,289, 1.30 GB, 5.9 s |
| Physical image, 8.6 GB: stored, guest paused | 6.83 GB, 16.5 s | 7.59 GB, 21.6 s | 4.46 GB, 11.4 s |
| Images LLDB lists in the SpringBoard core | 1,476 | 1,553 | – |

- The 27.2 physical image took 89.5 s (7.52 GB stored) before unused pages
  were skipped, with a second VM restoring beside it; 11.4 s is the next
  boot, alone.
- With the checks of [Guest data is untrusted](#guest-data-is-untrusted),
  on 2026-11-23, another iOS 27.2 machine (`Avocado`), alone: launchd 17,875
  segments, 1.25 GB, guest paused 3.1 s; SpringBoard 19,275 segments,
  1.41 GB, 3.2 s, and LLDB lists 1,778 images; the physical image 7.91 GB
  stored, 11.6 s. A control-socket command sent every half second during a
  dump was answered within 28 ms; before, the remapping and device-tree
  search held the main actor for about 1.6 s.
- After every dump the guest had the same `boot_session_uuid` and its
  uptime went on from where it was. The first `device.info` right after a
  long pause can go unanswered while vphoned reconnects.
- Four processes on each guest, XPC services among them, dumped with their
  names checked: all twelve matched.
- A pid whose process has another name is refused ("pid 34 is now
  SpringBoard, not launchd."), and a pid that does not exist gives "No
  process with pid 99999 runs in the guest."; six of each in a row on
  `mp-265`.
- LLDB opens the cores without threads; `image list` rebuilds the process's
  images from dyld's all-image info in the dump, and `memory read` works at
  their addresses.

## Not kept

- Threads and registers: a process's threads are not saved, and vCPU state
  is in the kernel cores only.
- Pages that are not resident: never touched, compressed by the guest, or
  swapped by it. Their bytes are not in guest RAM.
- Kernels without a symbol map. The two symbols could be found from code
  patterns, but each new kernel gets a recipe with a map anyway, and the
  map's kernel UUID makes a wrong match impossible.
- This reads runtime addresses from the recipes' symbol maps, which the
  patcher otherwise uses only at build time; the maps ship in the bundle for
  the kernelcache mixer already.
