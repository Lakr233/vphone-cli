#!/usr/bin/env python3
"""
test_patchers_jb.py — Offline self-test for JB patcher modules.

Validates imports, class structure, and method availability without
requiring real firmware data.  For KernelJBPatcher, we construct a
minimal Mach-O and attempt find_all(); since the dummy data contains no
real code patterns the patcher will find 0 patches, but the call must
not raise.

Usage:
    python3 test_patchers_jb.py
"""

import inspect
import struct
import sys
import traceback
from collections import defaultdict

from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE

_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)


def _asm(s, addr=0):
    enc, _ = _ks.asm(s, addr=addr)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)

OK = 0
FAIL = 0
PACIBSP = b'\x7f\x23\x03\xd5'


def check(label, fn):
    global OK, FAIL
    try:
        fn()
        print(f"  [OK] {label}")
        OK += 1
    except Exception as e:
        print(f"  [FAIL] {label}: {e}")
        traceback.print_exc()
        FAIL += 1


def test_imports():
    from patchers.kernel_jb import KernelJBPatcher  # noqa: F401
    from patchers.txm_jb import TXMJBPatcher  # noqa: F401
    from patchers.iboot_jb import IBootJBPatcher  # noqa: F401


def test_kernel_jb_methods():
    from patchers.kernel_jb import KernelJBPatcher

    expected = [
        "patch_amfi_cdhash_in_trustcache",
        "patch_amfi_execve_kill_path",
        "patch_sandbox_hooks_extended",
        "patch_thid_should_crash",
        "patch_nvram_verify_permission",
        "patch_hook_cred_label_update_execve",
        "find_all",
    ]
    for name in expected:
        assert hasattr(KernelJBPatcher, name), f"missing method: {name}"


def test_kernel_jb_find_all_signature():
    """Verify find_all is callable and returns a list (via introspection)."""
    from patchers.kernel_jb import KernelJBPatcher

    sig = inspect.signature(KernelJBPatcher.find_all)
    # Should only take self
    params = [p for p in sig.parameters if p != "self"]
    assert len(params) == 0, f"find_all() has unexpected params: {params}"


def test_kernel_jb_patch_count():
    """Verify find_all defines the expected number of patch methods."""
    from patchers.kernel_jb import KernelJBPatcher

    # Count patch_* methods called inside find_all source
    source = inspect.getsource(KernelJBPatcher.find_all)
    patch_calls = [line.strip() for line in source.splitlines()
                   if "self.patch_" in line and not line.strip().startswith("#")]
    assert len(patch_calls) >= 20, (
        f"find_all() calls only {len(patch_calls)} patch methods, expected >= 20"
    )


def test_txm_jb_apply():
    from patchers.txm_jb import TXMJBPatcher

    assert hasattr(TXMJBPatcher, "apply"), "TXMJBPatcher missing apply()"
    assert hasattr(TXMJBPatcher, "find_all"), "TXMJBPatcher missing find_all()"


def test_iboot_jb_apply():
    from patchers.iboot_jb import IBootJBPatcher

    assert hasattr(IBootJBPatcher, "apply"), "IBootJBPatcher missing apply()"


def _build_iboot_stub_with_nonce():
    """Build a minimal synthetic iBSS-like blob containing 'boot-nonce' string
    anchor + ADRP/ADD xref + the tbz w0,#0 / mov w0,#0 / bl pattern that
    patch_skip_generate_nonce() looks for.

    Layout (0x3000 bytes total):
      0x0000: padding (NOP sled)
      0x1000: "boot-nonce\\0" string
      0x2000: ADRP x0, #0x1000; ADD x0, x0, #0  (ref to string at 0x1000)
      0x2008: NOP padding
      0x2020: TBZ w0, #0, +0x10   (branch target = 0x2030)
      0x2024: MOV w0, #0
      0x2028: BL #0x100            (dummy target)
      0x202C: NOP (rest)
    """
    size = 0x3000
    blob = bytearray(b'\x1f\x20\x03\xd5' * (size // 4))  # NOP sled

    # Place "boot-nonce\0" at 0x1000
    string_off = 0x1000
    blob[string_off:string_off + 11] = b"boot-nonce\x00"

    # ADRP x0, #0x1000 at 0x2000 (absolute target page = 0x1000)
    adrp_off = 0x2000
    blob[adrp_off:adrp_off + 4] = _asm("adrp x0, #0x1000", addr=adrp_off)

    # ADD x0, x0, #0 at 0x2004 (low 12 bits of string offset = 0x000)
    add_off = 0x2004
    blob[add_off:add_off + 4] = _asm("add x0, x0, #0", addr=add_off)

    # Pattern at 0x2020: TBZ w0, #0, #0x10
    pat_off = 0x2020
    blob[pat_off:pat_off + 4] = _asm("tbz w0, #0, #0x10", addr=pat_off)

    # MOV w0, #0 at 0x2024
    blob[pat_off + 4:pat_off + 8] = _asm("mov w0, #0", addr=pat_off + 4)

    # BL #0x100 at 0x2028 (dummy call target)
    blob[pat_off + 8:pat_off + 12] = _asm("bl #0x100", addr=pat_off + 8)

    return blob


def test_iboot_jb_nonce_patch():
    """Verify IBootJBPatcher finds and patches the nonce-generation pattern
    in a synthetic iBSS blob."""
    from patchers.iboot_jb import IBootJBPatcher

    blob = _build_iboot_stub_with_nonce()
    patcher = IBootJBPatcher(blob, mode='ibss', verbose=False)
    patcher.apply()

    assert len(patcher.patches) == 1, (
        f"expected 1 nonce patch, got {len(patcher.patches)}"
    )
    off, pb, desc = patcher.patches[0]
    assert off == 0x2020, f"patch at wrong offset: 0x{off:X}, expected 0x2020"
    assert "nonce" in desc.lower(), f"unexpected desc: {desc}"


def _build_txm_stub_get_task_allow():
    """Build a synthetic TXM blob with 'get-task-allow' string + the
    BL / TBNZ w0,#0 pattern that patch_get_task_allow_force_true() looks for.

    Layout (0x3000 bytes):
      0x0800: "get-task-allow\\0"
      0x1000: ADRP x1, #-0x800; ADD x1, x1, #0x800  (ref to string)
      0x1008: BL #0x200  (dummy entitlement check)
      0x100C: TBNZ w0, #0, #0x20  (branch if bit 0 set)
      rest: NOP padding
    """
    size = 0x3000
    blob = bytearray(b'\x1f\x20\x03\xd5' * (size // 4))  # NOP sled

    # "get-task-allow\0" at 0x0800
    string_off = 0x0800
    s = b"get-task-allow\x00"
    blob[string_off:string_off + len(s)] = s

    # ADRP x1, #0 at 0x1000 (absolute target page = 0x0000, string at 0x0800)
    adrp_off = 0x1000
    blob[adrp_off:adrp_off + 4] = _asm("adrp x1, #0", addr=adrp_off)

    # ADD x1, x1, #0x800 (low 12 bits of string offset)
    add_off = 0x1004
    blob[add_off:add_off + 4] = _asm("add x1, x1, #0x800", addr=add_off)

    # BL #0x200 at 0x1008
    bl_off = 0x1008
    blob[bl_off:bl_off + 4] = _asm("bl #0x200", addr=bl_off)

    # TBNZ w0, #0, #0x20 at 0x100C
    tbnz_off = 0x100C
    blob[tbnz_off:tbnz_off + 4] = _asm("tbnz w0, #0, #0x20", addr=tbnz_off)

    return blob


def test_txm_jb_get_task_allow_patch():
    """Verify TXMJBPatcher finds get-task-allow BL site and patches it."""
    from patchers.txm_jb import TXMJBPatcher

    blob = _build_txm_stub_get_task_allow()
    patcher = TXMJBPatcher(blob, verbose=False)

    result = patcher.patch_get_task_allow_force_true()
    assert result is True, "patch_get_task_allow_force_true returned False"
    # Should have exactly 1 patch (bl -> mov x0,#1)
    gta_patches = [p for p in patcher.patches if "get-task-allow" in p[2]]
    assert len(gta_patches) == 1, f"expected 1 get-task-allow patch, got {len(gta_patches)}"
    off, pb, _ = gta_patches[0]
    assert off == 0x1008, f"patch at wrong offset: 0x{off:X}, expected 0x1008"
    # Verify it's mov x0,#1
    from patchers.txm_jb import MOV_X0_1
    assert pb == MOV_X0_1, f"patch bytes mismatch: {pb.hex()} != {MOV_X0_1.hex()}"


def _build_txm_stub_developer_mode():
    """Build a synthetic TXM blob with developer-mode string + tbz w9,#0 guard.

    Layout (0x3000 bytes):
      0x0800: "developer mode enabled due to system policy configuration\\0"
      0x1000: ADRP x2, #-0x800; ADD x2, x2, #0x800  (ref to string)
      0x0FFC: TBZ w9, #0, #0x10  (4 bytes before ADRP = guard to NOP)
      rest: NOP padding
    """
    size = 0x3000
    blob = bytearray(b'\x1f\x20\x03\xd5' * (size // 4))  # NOP sled

    # Place string at 0x0800
    string_off = 0x0800
    s = b"developer mode enabled due to system policy configuration\x00"
    blob[string_off:string_off + len(s)] = s

    # ADRP x2, #0 at 0x1000 (absolute target page = 0x0000, string at 0x0800)
    adrp_off = 0x1000
    blob[adrp_off:adrp_off + 4] = _asm("adrp x2, #0", addr=adrp_off)

    # ADD x2, x2, #0x800 at 0x1004
    add_off = 0x1004
    blob[add_off:add_off + 4] = _asm("add x2, x2, #0x800", addr=add_off)

    # TBZ w9, #0, #0x10 at 0x0FFC (4 bytes before ADRP = within back-scan range)
    guard_off = 0x0FFC
    blob[guard_off:guard_off + 4] = _asm("tbz w9, #0, #0x10", addr=guard_off)

    return blob


def test_txm_jb_developer_mode_bypass():
    """Verify TXMJBPatcher finds and NOPs the developer-mode guard."""
    from patchers.txm_jb import TXMJBPatcher, NOP

    blob = _build_txm_stub_developer_mode()
    patcher = TXMJBPatcher(blob, verbose=False)

    result = patcher.patch_developer_mode_bypass()
    assert result is True, "patch_developer_mode_bypass returned False"
    dm_patches = [p for p in patcher.patches if "developer mode" in p[2]]
    assert len(dm_patches) == 1, f"expected 1 developer mode patch, got {len(dm_patches)}"
    off, pb, _ = dm_patches[0]
    assert off == 0x0FFC, f"patch at wrong offset: 0x{off:X}, expected 0x0FFC"
    assert pb == NOP, f"patch bytes not NOP: {pb.hex()}"


def _make_kernel_jb_patcher(blob):
    """Create a KernelJBPatcher from a synthetic blob, bypassing Mach-O init."""
    from patchers.kernel_jb import KernelJBPatcher
    p = object.__new__(KernelJBPatcher)
    p.data, p.raw, p.size = bytearray(blob), bytes(blob), len(blob)
    p.base_va, p.verbose, p.panic_off = 0, False, -1
    p.kern_text = (0, len(blob))
    p.code_ranges = [(0, len(blob))]
    p.all_segments, p.patches, p.kext_ranges = [], [], {}
    p.symbols = {}
    # Build ADRP index
    p.adrp_by_page = defaultdict(list)
    for off in range(0, len(blob) - 3, 4):
        insn = struct.unpack_from("<I", blob, off)[0]
        if (insn & 0x9F000000) != 0x90000000:
            continue
        rd = insn & 0x1F
        immhi, immlo = (insn >> 5) & 0x7FFFF, (insn >> 29) & 0x3
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= (1 << 21)
        p.adrp_by_page[(off & ~0xFFF) + (imm << 12)].append((off, rd))
    # Build BL index
    p.bl_callers = defaultdict(list)
    for off in range(0, len(blob) - 3, 4):
        insn = struct.unpack_from("<I", blob, off)[0]
        if (insn & 0xFC000000) != 0x94000000:
            continue
        imm26 = insn & 0x3FFFFFF
        if imm26 & (1 << 25):
            imm26 -= (1 << 26)
        target = off + imm26 * 4
        if 0 <= target < len(blob):
            p.bl_callers[target].append(off)
    return p


def _make_kernel_blob(string, string_off=0x400):
    """Create a 0x3000-byte blob: zeroed string area + NOP code area."""
    size = 0x3000
    blob = bytearray(size)
    for i in range(0x800, size, 4):
        blob[i:i + 4] = b'\x1f\x20\x03\xd5'
    blob[string_off:string_off + len(string)] = string
    return blob


def _build_kernel_stub_io_secure_bsd_root():
    """'SecureRootName' + ADRP/ADD xref + CBZ forward guard."""
    blob = _make_kernel_blob(b"SecureRootName\x00")
    blob[0xFF0:0xFF4] = PACIBSP
    blob[0x1000:0x1004] = _asm("adrp x0, #0x0", addr=0x1000)
    blob[0x1004:0x1008] = _asm("add x0, x0, #0x400")
    blob[0x1010:0x1014] = _asm("cbz x0, #0x1030", addr=0x1010)
    blob[0x1100:0x1104] = PACIBSP
    return blob


def test_kernel_jb_io_secure_bsd_root():
    """Verify patch_io_secure_bsd_root patches CBZ → unconditional B."""
    blob = _build_kernel_stub_io_secure_bsd_root()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_io_secure_bsd_root()
    assert result is True, "patch_io_secure_bsd_root returned False"
    patches = [x for x in p.patches if "IOSecureBSDRoot" in x[2]]
    assert len(patches) == 1, f"expected 1 patch, got {len(patches)}"
    assert patches[0][0] == 0x1010, f"wrong offset: 0x{patches[0][0]:X}"


def _build_kernel_stub_shared_region_map():
    """'/private/preboot/Cryptexes' + ADRP/ADD + CMP reg,reg + B.NE."""
    blob = _make_kernel_blob(b"/private/preboot/Cryptexes\x00")
    blob[0xFF0:0xFF4] = PACIBSP
    blob[0x1000:0x1004] = _asm("adrp x0, #0x0", addr=0x1000)
    blob[0x1004:0x1008] = _asm("add x0, x0, #0x400")
    blob[0x1010:0x1014] = _asm("cmp x1, x2")
    blob[0x1014:0x1018] = _asm("b.ne #0x20", addr=0x1014)
    blob[0x1100:0x1104] = PACIBSP
    return blob


def test_kernel_jb_shared_region_map():
    """Verify patch_shared_region_map patches CMP → CMP x0,x0."""
    blob = _build_kernel_stub_shared_region_map()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_shared_region_map()
    assert result is True, "patch_shared_region_map returned False"
    patches = [x for x in p.patches if "shared_region" in x[2]]
    assert len(patches) == 1, f"expected 1 patch, got {len(patches)}"
    assert patches[0][0] == 0x1010, f"wrong offset: 0x{patches[0][0]:X}"


def _build_kernel_stub_vm_map_protect():
    """'vm_map_protect(' + ADRP/ADD + TBNZ bit>=24 forward."""
    blob = _make_kernel_blob(b"vm_map_protect(\x00")
    blob[0xFF0:0xFF4] = PACIBSP
    blob[0x1000:0x1004] = _asm("adrp x0, #0x0", addr=0x1000)
    blob[0x1004:0x1008] = _asm("add x0, x0, #0x400")
    blob[0x1010:0x1014] = _asm("tbnz x0, #24, #0x1050", addr=0x1010)
    blob[0x2000:0x2004] = PACIBSP
    return blob


def test_kernel_jb_vm_map_protect():
    """Verify patch_vm_map_protect patches TBNZ → unconditional B."""
    blob = _build_kernel_stub_vm_map_protect()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_vm_map_protect()
    assert result is True, "patch_vm_map_protect returned False"
    patches = [x for x in p.patches if "vm_map_protect" in x[2]]
    assert len(patches) == 1, f"expected 1 patch, got {len(patches)}"
    assert patches[0][0] == 0x1010, f"wrong offset: 0x{patches[0][0]:X}"


def _build_kernel_stub_dounmount():
    """'dounmount:' + ADRP/ADD + BL to func with MAC check pattern."""
    blob = _make_kernel_blob(b"dounmount:\x00")
    # Caller function
    blob[0xFF0:0xFF4] = PACIBSP
    blob[0x1000:0x1004] = _asm("adrp x0, #0x0", addr=0x1000)
    blob[0x1004:0x1008] = _asm("add x0, x0, #0x400")
    blob[0x1010:0x1014] = _asm("bl #0x7F0", addr=0x1010)  # → 0x1800
    blob[0x1100:0x1104] = PACIBSP  # caller func_end
    # Target function with MOV w1,#0; MOV x2,#0; BL pattern
    blob[0x1800:0x1804] = PACIBSP
    blob[0x1804:0x1808] = _asm("mov w1, #0")
    blob[0x1808:0x180C] = _asm("mov x2, #0")
    blob[0x180C:0x1810] = _asm("bl #0x100", addr=0x180C)
    blob[0x1900:0x1904] = PACIBSP  # target func_end
    return blob


def test_kernel_jb_dounmount():
    """Verify patch_dounmount NOPs the MAC check BL."""
    blob = _build_kernel_stub_dounmount()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_dounmount()
    assert result is True, "patch_dounmount returned False"
    patches = [x for x in p.patches if "dounmount" in x[2]]
    assert len(patches) == 1, f"expected 1 patch, got {len(patches)}"
    assert patches[0][0] == 0x180C, f"wrong offset: 0x{patches[0][0]:X}"
    assert patches[0][1] == b'\x1f\x20\x03\xd5', "patch is not NOP"


def _build_kernel_stub_task_conversion_eval():
    """LDR x8,[x8,#off] + CMP x8,x0 + B.EQ + CMP x8,x1 + B.EQ — unique 5-insn guard."""
    blob = _make_kernel_blob(b"")  # no string anchor needed
    # Place the 5-instruction pattern in code area
    off = 0x1000
    blob[off - 4:off] = PACIBSP  # function start
    # LDR x8, [x8, #0x10]
    blob[off:off + 4] = _asm("ldr x8, [x8, #0x10]")
    # CMP x8, x0
    blob[off + 4:off + 8] = _asm("cmp x8, x0")
    # B.EQ forward
    blob[off + 8:off + 12] = _asm("b.eq #0x1020", addr=off + 8)
    # CMP x8, x1
    blob[off + 12:off + 16] = _asm("cmp x8, x1")
    # B.EQ forward
    blob[off + 16:off + 20] = _asm("b.eq #0x1030", addr=off + 16)
    blob[0x1100:0x1104] = PACIBSP  # next function
    return blob


def test_kernel_jb_task_conversion_eval():
    """Verify patch_task_conversion_eval_internal replaces CMP with CMP xzr,xzr."""
    from patchers.kernel_jb import CMP_XZR_XZR
    blob = _build_kernel_stub_task_conversion_eval()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_task_conversion_eval_internal()
    assert result is True, "patch_task_conversion_eval_internal returned False"
    patches = [x for x in p.patches if "task_conversion" in x[2]]
    assert len(patches) == 1, f"expected 1 patch, got {len(patches)}"
    assert patches[0][0] == 0x1004, f"wrong offset: 0x{patches[0][0]:X}"
    assert patches[0][1] == CMP_XZR_XZR, f"patch bytes mismatch"


def _build_kernel_stub_bsd_init_auth():
    """LDR x0,[xN,#0x2b8] + CBZ x0 + BL pattern for _bsd_init auth bypass."""
    blob = _make_kernel_blob(b"")  # no string anchor needed
    off = 0x1000
    blob[off - 4:off] = PACIBSP
    # LDR x0, [x19, #0x2b8]
    blob[off:off + 4] = _asm("ldr x0, [x19, #0x2b8]")
    # CBZ x0, +0x10
    blob[off + 4:off + 8] = _asm("cbz x0, #0x1014", addr=off + 4)
    # BL (dummy target — the auth function call to replace)
    blob[off + 8:off + 12] = _asm("bl #0x200", addr=off + 8)
    blob[0x1100:0x1104] = PACIBSP
    return blob


def test_kernel_jb_bsd_init_auth():
    """Verify patch_bsd_init_auth replaces BL with MOV x0,#0."""
    from patchers.kernel import MOV_X0_0
    blob = _build_kernel_stub_bsd_init_auth()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_bsd_init_auth()
    assert result is True, "patch_bsd_init_auth returned False"
    patches = [x for x in p.patches if "bsd_init" in x[2]]
    assert len(patches) == 1, f"expected 1 patch, got {len(patches)}"
    assert patches[0][0] == 0x1008, f"wrong offset: 0x{patches[0][0]:X}"
    assert patches[0][1] == MOV_X0_0, f"patch bytes mismatch"


def _build_kernel_stub_spawn_validate_persona():
    """LDR wN,[xN,#0x600] + TBNZ wN,#1 pattern for persona validation bypass."""
    blob = _make_kernel_blob(b"")
    off = 0x1000
    blob[off - 4:off] = PACIBSP
    # LDR w8, [x19, #0x600]
    blob[off:off + 4] = _asm("ldr w8, [x19, #0x600]")
    # Some intermediate instructions
    blob[off + 4:off + 8] = _asm("nop")
    blob[off + 8:off + 12] = _asm("nop")
    # TBNZ w8, #1, forward
    blob[off + 12:off + 16] = _asm("tbnz w8, #1, #0x1020", addr=off + 12)
    blob[0x1100:0x1104] = PACIBSP
    return blob


def test_kernel_jb_spawn_validate_persona():
    """Verify patch_spawn_validate_persona NOPs LDR and TBNZ."""
    blob = _build_kernel_stub_spawn_validate_persona()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_spawn_validate_persona()
    assert result is True, "patch_spawn_validate_persona returned False"
    patches = [x for x in p.patches if "spawn_validate_persona" in x[2]]
    assert len(patches) == 2, f"expected 2 patches, got {len(patches)}"
    offsets = sorted(x[0] for x in patches)
    assert offsets == [0x1000, 0x100C], f"wrong offsets: {[hex(o) for o in offsets]}"
    for px in patches:
        assert px[1] == b'\x1f\x20\x03\xd5', f"patch is not NOP at 0x{px[0]:X}"


def _build_kernel_stub_amfi_execve_kill():
    """'AMFI: hook..execve() killing' string + 2x BL+CBZ/CBNZ w0 pairs in early window."""
    blob = _make_kernel_blob(b"AMFI: hook..execve() killing\x00", string_off=0x400)
    # Function start
    func_start = 0x1000
    blob[func_start - 4:func_start] = PACIBSP  # prev function end marker
    blob[func_start:func_start + 4] = PACIBSP  # function prologue
    # ADRP/ADD to string at 0x400
    blob[func_start + 4:func_start + 8] = _asm("adrp x0, #0x0", addr=func_start + 4)
    blob[func_start + 8:func_start + 12] = _asm("add x0, x0, #0x400")
    # First BL+CBZ w0 pair at func_start + 0x20
    site1 = func_start + 0x20
    blob[site1:site1 + 4] = _asm("bl #0x500", addr=site1)
    blob[site1 + 4:site1 + 8] = _asm("cbz w0, #0x1080", addr=site1 + 4)
    # Second BL+CBNZ w0 pair at func_start + 0x40
    site2 = func_start + 0x40
    blob[site2:site2 + 4] = _asm("bl #0x500", addr=site2)
    blob[site2 + 4:site2 + 8] = _asm("cbnz w0, #0x1090", addr=site2 + 4)
    # Next function start (end marker)
    blob[func_start + 0x100:func_start + 0x104] = PACIBSP
    return blob, site1, site2


def test_kernel_jb_amfi_execve_kill_path():
    """Verify patch_amfi_execve_kill_path patches 2 BL sites with MOV x0,#0."""
    from patchers.kernel import MOV_X0_0
    blob, site1, site2 = _build_kernel_stub_amfi_execve_kill()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_amfi_execve_kill_path()
    assert result is True, "patch_amfi_execve_kill_path returned False"
    patches = [x for x in p.patches if "AMFI execve" in x[2]]
    assert len(patches) == 2, f"expected 2 patches, got {len(patches)}"
    offsets = sorted(x[0] for x in patches)
    assert offsets == [site1, site2], (
        f"wrong offsets: {[hex(o) for o in offsets]}, expected [{hex(site1)}, {hex(site2)}]"
    )
    for px in patches:
        assert px[1] == MOV_X0_0, f"patch is not MOV x0,#0 at 0x{px[0]:X}"


def _build_kernel_stub_mac_mount():
    """'mount_common()' string → function with BL+CBNZ w0 (the MAC check to NOP)."""
    blob = _make_kernel_blob(b"mount_common()\x00", string_off=0x400)
    # mount_common function containing string ref
    mc_start = 0x1000
    blob[mc_start - 4:mc_start] = PACIBSP
    blob[mc_start:mc_start + 4] = PACIBSP  # mount_common prologue
    blob[mc_start + 4:mc_start + 8] = _asm("adrp x0, #0x0", addr=mc_start + 4)
    blob[mc_start + 8:mc_start + 12] = _asm("add x0, x0, #0x400")
    # BL to __mac_mount at 0x1800 (absolute target address for keystone)
    blob[mc_start + 0x20:mc_start + 0x24] = _asm("bl #0x1800", addr=mc_start + 0x20)
    blob[mc_start + 0x100:mc_start + 0x104] = PACIBSP  # mount_common end

    # __mac_mount function at 0x1800
    mm_start = 0x1800
    blob[mm_start:mm_start + 4] = PACIBSP
    # BL + CBNZ w0 pattern (MAC check)
    mac_check = mm_start + 0x20
    blob[mac_check:mac_check + 4] = _asm("bl #0x1C20", addr=mac_check)
    blob[mac_check + 4:mac_check + 8] = _asm("cbnz w0, #0x1880", addr=mac_check + 4)
    # MOV instruction with x8 nearby (within 0x60 bytes)
    blob[mac_check + 0x10:mac_check + 0x14] = _asm("mov x8, x1")
    blob[mm_start + 0x100:mm_start + 0x104] = PACIBSP  # __mac_mount end
    return blob, mac_check


def test_kernel_jb_mac_mount():
    """Verify patch_mac_mount NOPs the BL + patches MOV x8."""
    from patchers.kernel_jb import MOV_X8_XZR
    blob, mac_check = _build_kernel_stub_mac_mount()
    p = _make_kernel_jb_patcher(blob)
    result = p.patch_mac_mount()
    assert result is True, "patch_mac_mount returned False"
    patches = [x for x in p.patches if "mac_mount" in x[2]]
    assert len(patches) >= 1, f"expected >= 1 patch, got {len(patches)}"
    # First patch should be NOP at the BL
    nop_patches = [x for x in patches if x[1] == b'\x1f\x20\x03\xd5']
    assert len(nop_patches) >= 1, "no NOP patch found"
    assert nop_patches[0][0] == mac_check, f"NOP at wrong offset: 0x{nop_patches[0][0]:X}"


def main():
    print("=== JB Patcher Self-Test ===\n")

    print("-- Structure checks --")
    check("import all JB patchers", test_imports)
    check("KernelJBPatcher has expected methods", test_kernel_jb_methods)
    check("KernelJBPatcher.find_all() signature", test_kernel_jb_find_all_signature)
    check("KernelJBPatcher.find_all() calls >= 20 patch methods", test_kernel_jb_patch_count)
    check("TXMJBPatcher has apply() and find_all()", test_txm_jb_apply)
    check("IBootJBPatcher has apply()", test_iboot_jb_apply)

    print("\n-- Synthetic ARM64 bytecode tests --")
    check("IBootJBPatcher nonce patch on synthetic iBSS", test_iboot_jb_nonce_patch)
    check("TXMJBPatcher get-task-allow patch on synthetic TXM", test_txm_jb_get_task_allow_patch)
    check("TXMJBPatcher developer-mode bypass on synthetic TXM", test_txm_jb_developer_mode_bypass)
    check("KernelJBPatcher io_secure_bsd_root on synthetic blob", test_kernel_jb_io_secure_bsd_root)
    check("KernelJBPatcher shared_region_map on synthetic blob", test_kernel_jb_shared_region_map)
    check("KernelJBPatcher vm_map_protect on synthetic blob", test_kernel_jb_vm_map_protect)
    check("KernelJBPatcher dounmount on synthetic blob", test_kernel_jb_dounmount)
    check("KernelJBPatcher task_conversion_eval on synthetic blob", test_kernel_jb_task_conversion_eval)
    check("KernelJBPatcher bsd_init_auth on synthetic blob", test_kernel_jb_bsd_init_auth)
    check("KernelJBPatcher spawn_validate_persona on synthetic blob", test_kernel_jb_spawn_validate_persona)
    check("KernelJBPatcher amfi_execve_kill_path on synthetic blob", test_kernel_jb_amfi_execve_kill_path)
    check("KernelJBPatcher mac_mount on synthetic blob", test_kernel_jb_mac_mount)

    print(f"\n=== Results: {OK} passed, {FAIL} failed ===")

    if FAIL > 0:
        sys.exit(1)

    print("[OK] All JB patcher self-tests passed.")
    sys.exit(0)


if __name__ == "__main__":
    main()
