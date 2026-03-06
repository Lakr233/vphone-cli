"""kernel_jb.py — Jailbreak extension patcher for iOS kernelcache."""

import time

from .kernel_jb_base import KernelJBPatcherBase
from .kernel_jb_patch_amfi_trustcache import KernelJBPatchAmfiTrustcacheMixin
from .kernel_jb_patch_amfi_execve import KernelJBPatchAmfiExecveMixin
from .kernel_jb_patch_task_conversion import KernelJBPatchTaskConversionMixin
from .kernel_jb_patch_sandbox_extended import KernelJBPatchSandboxExtendedMixin
from .kernel_jb_patch_post_validation import KernelJBPatchPostValidationMixin
from .kernel_jb_patch_proc_security import KernelJBPatchProcSecurityMixin
from .kernel_jb_patch_proc_pidinfo import KernelJBPatchProcPidinfoMixin
from .kernel_jb_patch_port_to_map import KernelJBPatchPortToMapMixin
from .kernel_jb_patch_vm_fault import KernelJBPatchVmFaultMixin
from .kernel_jb_patch_vm_protect import KernelJBPatchVmProtectMixin
from .kernel_jb_patch_mac_mount import KernelJBPatchMacMountMixin
from .kernel_jb_patch_dounmount import KernelJBPatchDounmountMixin
from .kernel_jb_patch_bsd_init_auth import KernelJBPatchBsdInitAuthMixin
from .kernel_jb_patch_spawn_persona import KernelJBPatchSpawnPersonaMixin
from .kernel_jb_patch_task_for_pid import KernelJBPatchTaskForPidMixin
from .kernel_jb_patch_load_dylinker import KernelJBPatchLoadDylinkerMixin
from .kernel_jb_patch_shared_region import KernelJBPatchSharedRegionMixin
from .kernel_jb_patch_nvram import KernelJBPatchNvramMixin
from .kernel_jb_patch_secure_root import KernelJBPatchSecureRootMixin
from .kernel_jb_patch_thid_crash import KernelJBPatchThidCrashMixin
from .kernel_jb_patch_cred_label import KernelJBPatchCredLabelMixin
from .kernel_jb_patch_syscallmask import KernelJBPatchSyscallmaskMixin
from .kernel_jb_patch_hook_cred_label import KernelJBPatchHookCredLabelMixin
from .kernel_jb_patch_kcall10 import KernelJBPatchKcall10Mixin
from .kernel_jb_patch_iouc_macf import KernelJBPatchIoucmacfMixin


class KernelJBPatcher(
    KernelJBPatchKcall10Mixin,
    KernelJBPatchIoucmacfMixin,
    KernelJBPatchHookCredLabelMixin,
    KernelJBPatchSyscallmaskMixin,
    KernelJBPatchCredLabelMixin,
    KernelJBPatchThidCrashMixin,
    KernelJBPatchSecureRootMixin,
    KernelJBPatchNvramMixin,
    KernelJBPatchSharedRegionMixin,
    KernelJBPatchLoadDylinkerMixin,
    KernelJBPatchTaskForPidMixin,
    KernelJBPatchSpawnPersonaMixin,
    KernelJBPatchBsdInitAuthMixin,
    KernelJBPatchDounmountMixin,
    KernelJBPatchMacMountMixin,
    KernelJBPatchVmProtectMixin,
    KernelJBPatchVmFaultMixin,
    KernelJBPatchPortToMapMixin,
    KernelJBPatchProcPidinfoMixin,
    KernelJBPatchProcSecurityMixin,
    KernelJBPatchPostValidationMixin,
    KernelJBPatchSandboxExtendedMixin,
    KernelJBPatchTaskConversionMixin,
    KernelJBPatchAmfiExecveMixin,
    KernelJBPatchAmfiTrustcacheMixin,
    KernelJBPatcherBase,
):
    _TIMING_LOG_MIN_SECONDS = 10.0
    
    # Group A: Core gate-bypass methods.
    _GROUP_A_METHODS = (
        "patch_amfi_cdhash_in_trustcache",  # JB-01 / A1
        "patch_amfi_execve_kill_path",  # JB-02 / A2
        "patch_task_conversion_eval_internal",  # JB-08 / A3
        "patch_sandbox_hooks_extended",  # JB-09 / A4
        "patch_iouc_failed_macf",  # JB-10 / A5
    )

    # Group B: Pattern/string anchored methods.
    _GROUP_B_METHODS = (
        "patch_post_validation_additional",  # JB-06 / B5
        "patch_proc_security_policy",  # JB-11 / B6
        "patch_proc_pidinfo",  # JB-12 / B7
        "patch_convert_port_to_map",  # JB-13 / B8
        "patch_bsd_init_auth",  # JB-14 / B13 (retargeted 2026-03-06 to real _bsd_init rootauth gate)
        "patch_dounmount",  # JB-15 / B12
        "patch_io_secure_bsd_root",  # JB-16 / B19 (retargeted 2026-03-06 to SecureRootName deny-return)
        "patch_load_dylinker",  # JB-17 / B16
        "patch_mac_mount",  # JB-18 / B11
        "patch_nvram_verify_permission",  # JB-19 / B18
        "patch_shared_region_map",  # JB-20 / B17
        "patch_spawn_validate_persona",  # JB-21 / B14
        "patch_task_for_pid",  # JB-22 / B15
        "patch_thid_should_crash",  # JB-23 / B20
        "patch_vm_fault_enter_prepare",  # JB-24 / B9 (retargeted 2026-03-06 to upstream cs_bypass gate)
        "patch_vm_map_protect",  # JB-25 / B10
    )

    # Group C: Shellcode/trampoline heavy methods.
    _GROUP_C_METHODS = (
        "patch_cred_label_update_execve",  # JB-03 / C21 (disabled: reworked on 2026-03-06, pending boot revalidation)
        "patch_hook_cred_label_update_execve",  # JB-04 / C23 (faithful upstream trampoline)
        "patch_kcall10",  # JB-05 / C24 (ABI-correct rebuilt cave)
        "patch_syscallmask_apply_to_proc",  # JB-07 / C22
    )

    # Active JB patch schedule (known failing methods are temporarily excluded).
    _PATCH_METHODS = _GROUP_A_METHODS + _GROUP_B_METHODS + _GROUP_C_METHODS

    def __init__(self, data, verbose=False):
        super().__init__(data, verbose)
        self.patch_timings = []

    def _run_patch_method_timed(self, method_name):
        before = len(self.patches)
        t0 = time.perf_counter()
        getattr(self, method_name)()
        dt = time.perf_counter() - t0
        added = len(self.patches) - before
        self.patch_timings.append((method_name, dt, added))
        if dt >= self._TIMING_LOG_MIN_SECONDS:
            print(f"  [T] {method_name:36s} {dt:7.3f}s  (+{added})")

    def _run_methods(self, methods):
        for method_name in methods:
            self._run_patch_method_timed(method_name)

    def _build_method_plan(self):
        methods = list(self._PATCH_METHODS)
        final = []
        seen = set()
        for method_name in methods:
            if method_name in seen:
                continue
            if not callable(getattr(self, method_name, None)):
                continue
            seen.add(method_name)
            final.append(method_name)
        return tuple(final)

    def _print_timing_summary(self):
        if not self.patch_timings:
            return
        slow_items = [
            item
            for item in sorted(
                self.patch_timings, key=lambda item: item[1], reverse=True
            )
            if item[1] >= self._TIMING_LOG_MIN_SECONDS
        ]
        if not slow_items:
            return

        print(
            "\n  [Timing Summary] JB patch method cost (desc, >= "
            f"{self._TIMING_LOG_MIN_SECONDS:.0f}s):"
        )
        for method_name, dt, added in slow_items:
            print(f"    {dt:7.3f}s  (+{added:3d})  {method_name}")

    def find_all(self):
        self._reset_patch_state()
        self.patch_timings = []

        plan = self._build_method_plan()
        self._log("[*] JB method plan: " + (", ".join(plan) if plan else "(empty)"))
        self._run_methods(plan)
        self._print_timing_summary()

        return self.patches

    def apply(self):
        patches = self.find_all()
        for off, patch_bytes, _ in patches:
            self.data[off : off + len(patch_bytes)] = patch_bytes
        return len(patches)

    # ══════════════════════════════════════════════════════════════
    # Group A: Existing patches (unchanged)
    # ══════════════════════════════════════════════════════════════
