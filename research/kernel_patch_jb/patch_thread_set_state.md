# JB-23b `patch_thread_set_state_core_registers`

## Scope

This is an **opt-in Frida patch**. It is emitted only when firmware patching uses
`--frida`; baseline JB/EXP firmware is unchanged.

## Problem

After the `VM_PROT_COPY` path succeeds, Frida Stalker can still terminate a target when
following an existing thread with:

```text
EXC_GUARD / GUARD_TYPE_MACH_PORT / THREAD_SET_STATE
```

The failure comes from `thread_set_state_allowed()` in
`research/reference/xnu/osfmk/kern/thread_act.c`. Its three entitlement checks cover,
in source order:

1. cross-task Mach exception handling;
2. core CPU register updates;
3. fatal-PAC debug-register updates.

Only the second check blocks Stalker's existing-thread operation.

## Patch

The patch NOPs the second entitlement-failure branch only:

```asm
bl  IOTaskHasEntitlement
cbz w0, common_guard_exception   // before
nop                              // after
```

The exception-handler and fatal-PAC debug-state checks remain unchanged.

## Reveal Procedure

1. Find all references to `com.apple.private.thread-set-state`.
2. Group them by recovered function.
3. Require exactly three entitlement `BL` calls followed within three instructions by
   `CBZ W0` in one function.
4. Require the three calls and denial targets to be identical.
5. Select the middle gate; fail closed on ambiguity.

The replacement uses the project's preverified `ARM64.nop` and contains no
firmware-specific offset or instruction word.

## Applicability and Runtime Validation

The three-gate shape is present on the tested 26.4 kernel. Older supported kernels that
do not contain it are skipped without changing bytes. Even on 26.4 it is not applied
unless `KernelJBPatcher.applyFrida` is true through `--frida`.

On a fresh end-to-end `26.4-frida` restore with Frida 17.17.0, Stalker followed an
existing active Procursus `yes` thread for 1.5 seconds, delivered 5 call-summary batches
covering 81,920 calls, and detached with the target still alive.
