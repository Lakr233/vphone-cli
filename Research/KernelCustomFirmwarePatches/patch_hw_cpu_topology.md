# `kernel-exp-cpu_topology` — the CPU count sysctls answer a phone

## 1. Patch Metadata

- Patch ID: `kernel-exp-cpu_topology`; patcher `KernelExperimentalPatcher.patchCpuTopology()` in `Kernel/ExperimentalPatches/KernelExperimentalPatchCpuTopology.swift`.
- Declared in `FirmwareKernelHypervisorPatchSet`; blocked in `standard` (`manualOnlyPatches`), on in `experimental`.
- Analysis date: 2026-11-27. Static only; the Basil kernelcache (iOS 27.2 / 24B119, iPhone17,3) was the sample. No guest has booted this patch yet.

## 2. Patch Goal

`hw.ncpu`, `hw.activecpu`, `hw.physicalcpu`, `hw.physicalcpu_max`, `hw.logicalcpu` and `hw.logicalcpu_max` come from one handler, `sysctl_hw_generic`, which copies the live counts out of the host and cluster tables on every call. A VM with 4 vCPUs answers 4; no iPhone since the iPhone 8 has fewer than 6 cores, and none has SMT, so all six answers are the same number on every iPhone profile this project presents. The patch makes the six sysctls answer 6.

What it does not change: the scheduler, the per-CPU arrays, the IPI loops, and the Mach `host_info(HOST_BASIC_INFO)` trap, which copies `max_cpu`/`processor_count` straight out of the kernel's own tables. An app that asks the trap directly still reads the real count. That is deliberate (see §12).

## 3. Target Function and Binary Location

- `sysctl_hw_generic` @ `0xfffffff00b1d93b0` (Basil, unslid; chained-ptr base `0xfffffff007004000`).
- `ncpu` cstring @ image offset `0x9ce15`... (for `hv_vmm_present`; `ncpu` is found the same way at run time, not fixed).
- oid_name slot in `__DATA_CONST,__const`; the handler is the next slot (struct `sysctl_oid`: `oid_name`, then `oid_handler`).

## 6. Patch Hit Points (Basil 24B119)

| # | VA | Before | After | Serves |
|---|---|---|---|---|
| 1 | `0xfffffff00b1d9488` | `ldr w14, [x13]` (max_cpus) | `mov w14, #6` | hw.ncpu |
| 2 | `0xfffffff00b1d9490` | `ldr w15, [x15, #0xd4]` (avail_cpus) | `mov w15, #6` | hw.activecpu |
| 3 | `0xfffffff00b1d95f4` | `add x9, sp, #0x50` | `mov w9, #6` | hw.logicalcpu |
| 4 | `0xfffffff00b1d95f8` | `add x1, x9, #0x1c` | `str w9, [sp, #0x6c]` | |
| 5 | `0xfffffff00b1d95fc` | `b out` | `b cave+0` | |
| 6–8 | `0xfffffff00b1d9624..2c` | same shape, `#0x24` | `mov`/`str [sp,#0x74]`/`b cave+8` | hw.logicalcpu_max |
| cave | zeros in `__TEXT_EXEC` | — | `add x1, sp, #0x6c; b out; add x1, sp, #0x74; b out` (16 bytes) | |
| 9 | `0xfffffff00b1d96a4` | `ldr w9, [x0, #8]` | `mov w9, #6` | hw.physicalcpu |
| 10 | `0xfffffff00b1d96c0` | `ldr w9, [x0, #0x10]` | `mov w9, #6` | hw.physicalcpu_max |

Each replacement is one 32-bit word from `ARM64Encoder` (`encodeMovzW`, `encodeStrWUnsignedOffset`, `encodeAddImm12`, `encodeB`). The logical cases are three words long and the replacement needs four, so the case's own `b out` becomes a branch into a 16-byte cave that hands `x1` the slot and takes the original branch. The first version overwrote that branch with `add x1` and let the case fall through into the next one; the test now checks that both cave exits land where the original `b out` went.

## 7. Current Patch Search Logic

1. `ncpu\0` with a NUL before it: exactly one hit, else refuse.
2. Walk `__DATA_CONST`; the slot whose chained pointer's low word is the cstring's image offset is `oid_name`; the next slot's target is the handler, which must land in a code range.
3. Host loads: in the first 0x100 bytes, an `stp wA, wB, [sp, #D]` whose registers match two `ldr wN, [xM(, #d)]` within the six instructions before it. Both loads → `movz #6`.
4. Logical slots: `add x9, sp, #D` + `add x1, x9, #0x1c|0x24` anywhere in the first 0x800 bytes. `#0x20` between them is `physical_cpu_max` from the *host* struct (not the cluster one) and is deliberately not matched — the first version matched it and would have written 6 over it.
5. Cluster loads: `mov x8, x20` then within four instructions `ldr w9, [x0, #8|0x10]`. → `movz #6`.
6. Fewer than 2 of either kind: say so in the log, keep what matched. Nothing matched: write nothing, return false.

Idempotent: a replaced load is no longer a load; the replaced `add` pair no longer matches step 4.

## 8–9. Pseudocode

Before: `hinfo = host_info(HOST_BASIC_INFO); switch (arg2) { case HW_NCPU: return hinfo.max_cpus; case HW_LOCAL_LOGICALCPU: return hinfo.logical_cpu; case HW_LOCAL_PHYSICALCPU: return ml_get_cpu_number_type(...)->cpus; ... }`

After: the same switch, with the two stack fields pre-filled by `movz`, the two logical fields stored by the case itself, and the two cluster loads replaced by `movz`.

## 10. Validation

`KernelExperimentalPatchCpuTopologyTests` (fixture via `TEST_RUNNER_VPHONE_CPUTOP_KERNEL`): on the Basil kernelcache exactly 6 words become `mov wN, #6` (4 loads and the 2 handoff `add`s), 2 stores of `w9` into `sp+0x6c`/`sp+0x74`, 2 branches into a 16-byte cave whose two `b` land on the original `b out` target, every replaced instruction decodes as claimed, and a second run writes nothing. A zero buffer is refused. Not run: no guest has booted the patched kernel.

## 11. Expected Failure if Unpatched

None for the system; only the detection: `hw.ncpu == 4` on an `iPhone17,3` that reports an A18-class identity.

## 12. Risk / Side Effects

- **`host_info(HOST_BASIC_INFO)` still returns the real counts.** libdispatch and a few Apple frameworks read `hw.ncpu`/`hw.activecpu` through sysctl; anything that calls the trap sees 4. A detector that compares the two sees the seam. Closing it means patching the trap's copy of `max_cpu` (not the global — per-CPU sizing depends on it), which is a separate, second site and was not done here.
- `hw.perflevelN.physicalcpu/logicalcpu` go through `ml_get_cpu_number_type` under other OIDs and still answer the cluster's real count (e.g. 2+2 on a 4-vCPU VM). On a 6-core phone they should sum to 6. Not patched: the per-perflevel split of a 4-vCPU VM is not a phone's 2P+4E or 4P+2E, so a plausible answer needs a per-profile table, not a constant.
- `hw.nperflevels` is left real.
- A VM configured with 6 vCPUs already matches; the patch is then a no-op in effect.

## 14. Open Questions and Confidence

- Confidence the patched handler returns 6 for the six sysctls: **high** (every replaced word decodes to the intended instruction; the stack layout is read off the same disassembly the patcher matches).
- Confidence the kernel boots: **medium** — all writes are single-word, inside one function, with no control-flow change other than the three-word handoff whose branch target is unchanged. Not boot-tested.
- Whether the userland reads the trap more often than the sysctl: unknown until appvisor runs on a patched guest (it reports both).

## 15. Evidence

- Disassembly of `sysctl_hw_generic`: `/tmp/shg.txt` (775 lines). `host_basic_info` on the stack at `sp+0x50`: max_cpus `+0x50`, avail_cpus `+0x54`, physical_cpu `+0x5c`, physical_cpu_max `+0x60`, logical_cpu `+0x6c`, logical_cpu_max `+0x74`.
- XNU reference: `bsd/kern/kern_mib.c` `sysctl_hw_generic` (the `HW_NCPU`/`HW_LOCAL_*` cases read `hinfo` filled by `host_info((host_t)BSD_HOST, HOST_BASIC_INFO, …)`; `HW_LOCAL_PHYSICALCPU` and the perflevel cases call `ml_get_cpu_number_type`).
