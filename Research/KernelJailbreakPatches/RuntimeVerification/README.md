# JB Runtime Verification Runbook

> **Archived research procedure.** The commands and local file paths below
> describe the 2026-03-05 investigation and may not exist in the current
> checkout. For the current JB flow, see the
> [VM guide](../../../Documents/Guides/create-and-run.md) and
> [patch notes index](../README.md).

This folder contains runtime + IDA verification artifacts for jailbreak kernel patches.

## Quick Commands

Run runtime verification against a kernel file:

```bash
make jb_verify_runtime KERNEL_PATH=/path/to/kernelcache.research.vphone600 WORKERS=8
```

Refresh patch-doc tails from latest reports:

```bash
make jb_update_runtime_docs
```

## Core Artifacts

- `runtime_verification_report.json`
  - Source of truth for runtime patch hit/no-hit status.
  - Includes scheduler coverage (`methods_scheduled`, `doc_methods_unscheduled`).
- `runtime_verification_summary.md`
  - Human-readable summary.
- `runtime_patch_points.json`
  - Flat list of runtime patch points used for IDA join.
- `ida_runtime_patch_points.json`
  - Runtime points enriched with IDA function/disassembly context.

## Current Baseline (2026-03-05)

- Kernel: `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600`
- Runtime result: `22 hit / 2 nohit / 0 error`
- Default `KernelJBPatcher.find_all()` scheduled methods: `7`
- Doc methods unscheduled: `17`
- No-hit methods:
  - `patch_post_validation_additional`
  - `patch_syscallmask_apply_to_proc`

## Regression Gate

Treat verification as regressed if any of the following occurs:

- `status=error` appears in `runtime_verification_report.json`.
- A previously `hit` method becomes `nohit` without explicit scheduler/matcher change.
- `methods_scheduled_count` changes unexpectedly from intended plan.
- `doc_methods_unscheduled` changes unexpectedly.
