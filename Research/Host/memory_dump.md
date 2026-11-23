# Memory dumps through Virtualization's core writer

How **Diagnostics > Save Memory Dump…** and the control socket's `memory.dump`
take a running guest's memory, why they use Virtualization's private core
writer, what its files hold, and what was measured. The user's side is
[Memory Dumps](../../Documents/en/machines/memory-dumps.md); the code is
`VPhoneMemoryDump` in `VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/`,
and `VPhoneExecutable/VPhoneVirtualization/Tests/run-memory-dump-tests.sh`
checks its sparse writer and names offline.

Measured 2026-11-19 on a MacBook Air with 16 GB RAM, macOS 27.2.1
(`26B131`, Virtualization 308.2.7), with `devs-272`: iPhone17,3 on iOS 27.2
(`24B119`) over a cloudOS 27.2 kernel, 8 GB RAM, 8 vCPUs, the SEP
coprocessor on OpenSEP. A second guest ran beside it, so the host was short
of memory and swapping throughout.

## The interface

`VZVirtualMachine` has, unlisted in the SDK headers:

| Selector | Behaviour seen |
| --- | --- |
| `_canCreateCore` | `YES` while the state is running or paused (`state` 1 or 2, read from `+0x148`) |
| `_createCoresWithCompletionHandler:` | `NSDictionary` of `NSData`, one per processor: `AP` and `SEP-coproc` |
| `_createCoreWithCompletionHandler:` | `NSData` of the `AP` core only |
| `_createSharedMemoryCoresWithOptions:completionHandler:` | the same request with one boolean option; not used |

The data lives in shared memory the VM service fills
(`VzShared::Messages::Service::create_virtual_machine_cores`, `Base::Xpc::Shmem`);
reading it does not grow `vphone-vm`'s resident memory until the pages are
touched. The completion handler runs on the VM's queue, the main queue in
`vphone-vm`. The service has `VzService::Coprocessor::CoprocessorVirtualMachine::create_core`,
which is where `SEP-coproc` comes from.

## Why not the other ways

- **`saveMachineStateToURL:`** cannot work with a SEP. Every save and restore
  entry point first calls `-[VZVirtualMachineConfiguration
  validateSaveRestoreSupportWithError:]`, which refuses a configuration with
  `_coprocessors` ("Unsupported coprocessor in configuration.",
  `VZErrorDomain` 2), and also one with mailbox devices, a debug stub,
  accelerator or multi-touch devices, all of which vphone configures. A
  refused call raises `NSInvalidArgumentException` rather than calling back
  with an error, which would end `vphone-vm`. `CoprocessorVirtualMachine`
  has start, stop, pause, resume, reset and `create_core`, but no save or
  restore. (Disassembly of macOS 27.2's framework; no older framework was
  available to compare.)
- **Halting through the kernel GDB stub and reading the VM service's memory**
  (`task_for_pid` on `com.apple.Virtualization.VirtualMachine`,
  `task_suspend`, copying its `VM_MEMORY` tag-240 regions) gives a physical
  image and every system register, but it needs the
  `com.apple.security.cs.debugger` entitlement and holds the guest still
  behind Virtualization's back: the SEP, timers and devices are not told.
  One such capture is remembered to have crashed the guest (not reproduced
  here).

The core writer pauses and resumes the guest itself, needs no entitlement
beyond those `vphone-vm` already has, and does not use the debug stub.

## What the files hold

Both cores are Mach-O `MH_CORE`, `CPU_TYPE_ARM64`, with an `LC_NOTE`
"addrable bits".

`AP`, 8,579,104,768 bytes for an 8 GiB guest:

- 8 `LC_THREAD`, one per vCPU, `ARM_THREAD_STATE64` (flavor 6, count 68):
  x0–x28, fp, lr, sp, pc, cpsr. No system registers.
- 82,329 `LC_SEGMENT_64`: 8,443 MiB of kernel virtual addresses
  (`0xfffffdf000000000`…) and 1,100 MiB of user addresses (`0x1004f8000` to
  `0x7dcd2ac000`) in that dump, in which three vCPUs were in user mode; LLDB
  read the instructions at one of their PCs. An earlier dump had 11,183
  segments, all at kernel addresses.
- The file data after the load commands is one contiguous run of 7.98 GiB.
  The segments' sizes add up to more than that, so aliases of one page share
  its bytes; each page is stored once. Physical addresses are not recorded.

`SEP-coproc`, 21,069,824 bytes: four segments at `0xffffffff00000000`
upwards and one thread.

LLDB (`lldb-2103.0.34.407`, Xcode 27.2) loads `AP.core` without a binary: `thread list` shows the
eight vCPUs, and `register read`, `memory read` and `bt` work. Given the
decompressed kernelcache it does not find the kernel's slide by itself; load
the kernelcache with `target modules load --slide`.

## Measurements

| What | Result |
| --- | --- |
| Capture, `_createCores…` call to reply | 8.0, 8.7, 11.2, 14.3, 16.4 s; 44.1 s once with the host deep in swap |
| Guest paused | for the capture: control-socket pings sent during it answered when it ended (13.8 s for a 14.3 s capture) |
| Guest clock | stood still while paused: behind the Mac by about the capture time afterwards (7.9 to 25.7 s logged), now set at once by `VPhoneClockSync` |
| Guest after each of six captures (four in one boot, one in each of the next two) | same `boot_session_uuid` and vphoned pid, no new crash report; 200 processes before and after the last (three on-demand daemons exited, three started) |
| Write, 8.6 GB with zero blocks left out | 78.8 s (7.64 GB stored for `AP`) and 39.6 s (7.31 GB), host swapping; 4.9 MB of `SEP-coproc` |
| A second `memory.dump` while one is saved | refused at once: "A memory dump of this machine is already being saved." |
| Refusals (no space, existing folder, relative path, missing parent) | 0.07 to 0.10 s, before the guest is touched |

The guest is running again before the files are written, so the write time
only matters to the host. APFS keeps the holes of the 8.6 GB `AP.core`
(7.35 GB allocated in the second dump) but allocates any file of up to 16 MB
in full, so `SEP-coproc.core` takes its whole 21 MB. On a host short of memory, the capture copy goes to
swap, and the pause and the write both get longer.

## Not kept

- Physical addresses, `TTBR0/1_EL1`, the PAC keys and the other system
  registers. The kernel's own data reaches all of RAM through its mappings,
  and the registers that matter for a backtrace are in the thread states.
  The CTF-style physical image remains possible with the GDB stub and
  `task_for_pid` when those are needed.
- Memory no page table maps, such as the firmware carve-outs below
  `dram-base` (about 10 MB on an 8 GB guest).
