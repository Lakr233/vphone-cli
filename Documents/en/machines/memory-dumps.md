# Memory Dumps

A memory dump saves a running guest's memory and processor state to files on your Mac, for offline analysis with LLDB or your own tools. The guest pauses while its memory is copied, then carries on where it was.

## Save a dump

1. In the VM window, choose **Diagnostics > Save Memory Dump…**.
2. Choose a folder. A new folder named for the machine and the time, such as `myphone Memory 2026-11-19 at 15.20.11`, is created inside it.
3. Wait for the alert that says where the dump was saved. The guest is paused only for the first part, usually 10 to 20 seconds. It runs again while the files are written, which can take another minute.

A guest you have [paused](create-and-run.md#pause-and-resume) can be dumped too. It stays paused, and the dump holds it as it stood at the pause.

Stopping the VM while a dump is being saved waits until the files are written, then shuts the guest down. `vphone-cli vm stop` gives up after 20 seconds and turns the guest off, which ends the dump too; give it a longer `--timeout`, such as `--timeout 300`.

From Terminal, send `memory.dump` to the machine's [control socket](create-and-run.md#control-socket) with the folder to create. The folder must not exist yet; its parent must.

```sh
printf '%s\n' '{"t":"memory.dump","path":"/Users/me/Dumps/myphone-1"}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

The reply comes when the files are written. It lists each file with its size and the bytes it holds, and how long the capture and the writing took. `vphone-launchpad-cli guest send` stops waiting after two minutes, so use `nc` as above on a Mac where writing 8 GB takes longer.

## What a dump contains

| File | Contents |
| --- | --- |
| `AP.core` | The guest's RAM at the kernel's virtual addresses, the user memory of the processes that were running on the vCPUs, and the general registers of every vCPU |
| `SEP-coproc.core` | The Secure Enclave's memory, about 20 MB |
| `info.json` | The machine, the time, the vphone and macOS versions, and each file's size |

Both cores are Mach-O core files. LLDB opens `AP.core` directly, with a thread for each vCPU:

```sh
lldb -c "myphone Memory 2026-11-19 at 15.20.11/AP.core"
```

`thread list`, `register read`, `memory read` and `bt` work without anything else. For symbols, add the kernelcache the guest booted and load it at the guest's KASLR slide with `target modules load --file <kernelcache> --slide <slide>`.

A dump does not include physical addresses, system registers such as the translation table bases or the pointer authentication keys, or memory the kernel does not map.

## Space and time

- `AP.core` is a little larger than the guest's RAM, 8.6 GB for an 8 GB guest. All-zero blocks are left out of the file, so on an APFS volume it takes only the space of its data, usually most of the guest's RAM.
- Saving refuses, before the guest is paused, when the volume has less free space than the guest's RAM and a little more.
- While the guest is paused, macOS holds a copy of its memory. On a Mac that is short of memory the pause and the writing take longer.
- The guest's clock stands still while it is paused. `vphone-vm` puts it back on the Mac's time as soon as the guest runs again.
- One dump of a machine is saved at a time.

Dumps need a macOS whose Virtualization framework writes memory cores. macOS 27.2 does; where it does not, the menu item is unavailable and `memory.dump` says so.

For how dumps are made and what was measured, see [`Research/Host/memory_dump.md`](../../../Research/Host/memory_dump.md).

## See also

- [Create and Run a VM](create-and-run.md)
- [Device Name and Clock](device-name-and-clock.md)
