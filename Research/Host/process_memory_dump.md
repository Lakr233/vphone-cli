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
   included.
2. **Kernel page tables.** The root table (`TTBR1_EL1`) is the one page of
   DRAM through which three addresses in each of `__TEXT` and `__DATA_CONST`
   translate to where step 1 found them. The search reads one entry per page
   first and took 0.1 to 0.3 s. The tables use a 16 KB granule, three levels
   of 2048 entries at bits 36, 25 and 14, with 64 GB and 32 MB blocks.
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
were right. `_get_task_map` was wrong in eleven maps and missing in four;
each now names the one leaf that loads `[x0,#0x28]` with discriminator
`0x5ef8`, and `_get_task_pmap` was added. Neither is used by the dump. The
vphone600 26.2 (`23C55`) and 26.3 (`23D129`) kernels got maps under
`kernels/`.

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
