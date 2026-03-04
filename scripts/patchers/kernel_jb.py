"""kernel_jb.py — Jailbreak extension patcher for iOS kernelcache."""

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


class KernelJBPatcher(
    KernelJBPatchKcall10Mixin,
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
    def find_all(self):
        self.patches = []

        # Commented patches are broken to boot into panic.

        # Group A: Existing patches
        self.patch_amfi_cdhash_in_trustcache()          # A1
        # self.patch_amfi_execve_kill_path()              # A2 (PANIC)
        self.patch_task_conversion_eval_internal()      # A3
        self.patch_sandbox_hooks_extended()             # A4

        # Group B: Simple patches (string-anchored / pattern-matched)
        self.patch_post_validation_additional()           # B5
        # self.patch_proc_security_policy()               # B6 (PANIC)
        self.patch_proc_pidinfo()                        # B7
        # self.patch_convert_port_to_map()                # B8 (PANIC)
        self.patch_vm_fault_enter_prepare()              # B9
        self.patch_vm_map_protect()                      # B10
        self.patch_mac_mount()                           # B11
        self.patch_dounmount()                           # B12
        self.patch_bsd_init_auth()                       # B13
        self.patch_spawn_validate_persona()              # B14
        self.patch_task_for_pid()                        # B15
        self.patch_load_dylinker()                       # B16
        self.patch_shared_region_map()                   # B17
        self.patch_nvram_verify_permission()             # B18
        self.patch_io_secure_bsd_root()                  # B19
        self.patch_thid_should_crash()                   # B20

        # Group C: Complex shellcode patches
        self.patch_cred_label_update_execve()            # C21
        self.patch_syscallmask_apply_to_proc()           # C22
        # self.patch_hook_cred_label_update_execve()      # C23 (PANIC)
        # self.patch_kcall10()                            # C24 (NOT_BOOT)

        return self.patches

    def apply(self):
        patches = self.find_all()
        for off, patch_bytes, _ in patches:
            self.data[off : off + len(patch_bytes)] = patch_bytes
        return len(patches)

    # ══════════════════════════════════════════════════════════════
    # Group A: Existing patches (unchanged)
    # ══════════════════════════════════════════════════════════════
