# Memory Dumps

A memory dump saves a running guest's memory and processor state to files on your Mac, for offline analysis with LLDB or your own tools. The guest pauses while its memory is copied, then carries on where it was.

There are three kinds:

| Kind | Started from | What it saves |
| --- | --- | --- |
| [Kernel and vCPU cores](#save-a-dump) | **Diagnostics > Save Memory Dump…** | The guest's RAM at the kernel's virtual addresses, the registers of every vCPU, and the Secure Enclave's memory |
| [Physical memory image](#physical-memory-image) | The checkbox in the same panel | All of the guest's RAM at its physical addresses |
| [One process](#dump-one-process) | **Save Memory Dump…** in the Processes window | The resident memory of one process at its own addresses |

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

## Physical memory image

Select **Physical memory image** in the Save Memory Dump panel to save `physical.elf` instead of the cores. It is an ELF core with one `PT_LOAD` for the guest's DRAM and one for the firmware carve-outs below it; each segment's address is the guest physical address. A `VPHONE` note (type `0x5650`) holds JSON naming the machine, the guest's kernel, its physical address and the root of its page tables. Use it with tools that read physical memory, or to translate addresses through the guest's page tables yourself.

Pages the guest never used are left out of the file. The guest stays paused until the whole image is written, usually 10 to 20 seconds when the Mac has enough free memory.

From Terminal, add `"physical":true` to `memory.dump`:

```sh
printf '%s\n' '{"t":"memory.dump","path":"/Users/me/Dumps/myphone-2","physical":true}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

## Dump one process

1. Choose **Diagnostics > Processes** and select one process.
2. Choose **Save Memory Dump…** in the toolbar or the context menu, then a folder. The new folder is named for the machine, the process and its pid, such as `myphone SpringBoard (36) Memory 2026-11-20 at 10.02.03`.

vphone reads the process's memory from the Mac, without the guest's help: it finds the guest kernel in guest RAM, walks its process list to the pid, and copies every page the process's page tables map. The guest is paused for this, usually a few seconds. vphoned only supplies the process list you choose from. If the pid belongs to a different process by the time you save, the dump is refused; refresh the list and try again.

The folder holds a Mach-O core named for the process and an `info.json`. LLDB opens the core and finds the process's images from dyld's data in it:

```sh
lldb -c "myphone SpringBoard (36) Memory 2026-11-20 at 10.02.03/SpringBoard.core"
(lldb) image list
(lldb) memory read 0x104218000
```

The core has the process's resident pages only. Pages it never touched, pages the guest compressed or paged out, and its threads and registers are not in it. Each segment's permissions come from the page table entries.

From Terminal, send `process.dump` with the pid. `name` is optional; when given, the dump is refused unless the process has that name:

```sh
printf '%s\n' '{"t":"process.dump","pid":36,"name":"SpringBoard","path":"/Users/me/Dumps/springboard"}' | nc -U ~/.vphone/machines/myphone/vphone.sock
```

Process dumps work for guests whose kernel is one of the kernelcache recipes vphone ships, iOS 18.1 to 27.2; vphone needs two addresses from that kernel's symbol map. For any other kernel, the dump says the kernel is unknown.

## Space and time

- `AP.core` is a little larger than the guest's RAM, 8.6 GB for an 8 GB guest. All-zero blocks are left out of the file, so on an APFS volume it takes only the space of its data, usually most of the guest's RAM.
- Saving refuses, before the guest is paused, when the volume has less free space than the guest's RAM and a little more. A process dump asks for 4 GB.
- While the guest is paused, macOS holds a copy of its memory. On a Mac that is short of memory the pause and the writing take longer.
- The guest's clock stands still while it is paused. `vphone-vm` puts it back on the Mac's time as soon as the guest runs again.
- One dump of a machine is saved at a time.

Kernel and vCPU cores need a macOS whose Virtualization framework writes memory cores. macOS 27.2 does; where it does not, the menu item is unavailable and `memory.dump` says so. Physical images and process dumps read guest RAM from the Virtualization process that runs the VM, which needs System Integrity Protection's debugging restrictions off, as [Host Setup](../get-started/host-setup.md) already requires.

For how dumps are made and what was measured, see [`Research/Host/memory_dump.md`](../../../Research/Host/memory_dump.md) and [`Research/Host/process_memory_dump.md`](../../../Research/Host/process_memory_dump.md).

## See also

- [Create and Run a VM](create-and-run.md)
- [Device Name and Clock](device-name-and-clock.md)
