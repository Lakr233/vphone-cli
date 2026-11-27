/*
 * pongoOS - https://checkra.in
 *
 * Copyright (C) 2019-2021 checkra1n team
 *
 * This file is part of pongoOS.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */
#include <pongo.h>
#include <mach-o/loader.h>
#include <kerninfo.h>
#include <mac.h>
#define NOP 0xd503201f
#define RET 0xd65f03c0

uint32_t offsetof_p_flags, *dyld_hook;

#if DEV_BUILD
    #define DEVLOG(x, ...) do { \
        printf(x "\n", ##__VA_ARGS__); \
    } while (0)
    #define panic_at(addr, str, ...) do { \
        panic(str " (0x%llx)", ##__VA_ARGS__, xnu_ptr_to_va(addr)); \
    } while (0)
#else
    #define DEVLOG(x, ...) do {} while (0)
    #define panic_at(addr, str, ...) do { \
        (void)(addr); \
        panic(str, ##__VA_ARGS__); \
    } while (0)
#endif

#if 0
        // AES, sigh
        else if((fetch & 0xfffffc00) == 0x510fa000 && (apfs_privcheck[i+1] & 0xfffffc1f) == 0x7100081f && (apfs_privcheck[i+2] & 0xff00001f) == 0x54000003) {
             apfs_privcheck_repatch[i+2] = 0xd503201f; // nop
             puts("KPF: Preparing keygen");
        }
        // AESs8000 patch, more sigh
        else if(fetch == 0x711f3c3f && (apfs_privcheck[i+1] & 0xff00001f) == 0x5400000c && apfs_privcheck[i+2] == 0x710fa03f && (apfs_privcheck[i+3] & 0xff00001f) == 0x54000000 && apfs_privcheck[i+4] == 0x710fa43f) {
            apfs_privcheck_repatch[i]   = 0x52800000; // mov w0, 0
            apfs_privcheck_repatch[i+1] = RET; // ret
            puts("KPF: Gatekeeping 0x3e8");
        }
        // Pre-s8000 AES patch, I'm getting tired of this
        else if((fetch & 0xfffffc1f) == 0x711f401f && (apfs_privcheck[i+1] & 0xff00001f) == 0x54000000 && (apfs_privcheck[i+2] & 0xfffffc1f) == 0x710fa41f) {
            uint32_t tmp = apfs_privcheck[i+1];
            apfs_privcheck_repatch[i+1] = (tmp & 0xfffffff0) | 0xf; // make unconditional
            int32_t idx = (int32_t)i + 1 + ((int32_t)(tmp << 8) >> 13);
            uint32_t tmp2 = apfs_privcheck[idx];
            apfs_privcheck_repatch[i] = 0xd2800000 | (tmp2 & 0x1f);
            // NOP if not strb
            if((tmp2 & 0xffc00000) == 0x39000000) {
                apfs_privcheck_repatch[idx] = 0xd503201f; // nop
            }
            puts("KPF: Gatekeeping 0x3e8");
        }
        // MacEFIManager patch
        // 3f 04 00 71 ? ? 00 54 3f 08 00 71 ? ? 00 54 ? ? ? 39
        else if (fetch == 0x7100043F && (apfs_privcheck[i+1] & 0xffff0000) == 0x54000000 && apfs_privcheck[i+2] == 0x7100083f && (apfs_privcheck[i+3] & 0xffff0000) == 0x54000000 && (apfs_privcheck[i+4] & 0xff000000) == 0x39000000) {
             puts("KPF: MacEFIManager img4 validation");
            uint32_t* cmp = find_next_insn(&apfs_privcheck_repatch[i], 0x10, 0x7100081f, 0xFFFFFFFF);
            if (!cmp) {
                goto fail;
            }
            *cmp = 0x6b00001f;
        }
#endif

uint32_t* find_next_insn(uint32_t* from, uint32_t num, uint32_t insn, uint32_t mask)
{
    while(num)
    {
        if((*from & mask) == (insn & mask))
        {
            return from;
        }
        from++;
        num--;
    }
    return NULL;
}
uint32_t* find_prev_insn(uint32_t* from, uint32_t num, uint32_t insn, uint32_t mask)
{
    while(num)
    {
        if((*from & mask) == (insn & mask))
        {
            return from;
        }
        from--;
        num--;
    }
    return NULL;
}

int32_t sxt32(int32_t value, uint8_t bits) {
    value = ((uint32_t)value)<<(32-bits);
    value >>= (32-bits);
    return value;
}

int64_t sxt64(int64_t value, uint8_t bits) {
    value = ((uint64_t)value)<<(64-bits);
    value >>= (64-bits);
    return value;
}

uint32_t* follow_call(uint32_t* from) {
    if ((*from&0x7C000000) != 0x14000000) {
        DEVLOG("follow_call 0x%llx is not B or BL", xnu_ptr_to_va(from));
        return NULL;
    }
    uint32_t *target = from + sxt32(*from, 26);
    if(
        (target[0] & 0x9f00001f) == 0x90000010 && // adrp x16, ...
        (target[1] & 0xffc003ff) == 0xf9400210 && // ldr x16, [x16, ...]
        target[2] == 0xd61f0200                   // br x16
    ) {
        // Stub - read pointer
        int64_t pageoff = sxt64((((((uint64_t)target[0] >> 5) & 0x7ffffULL) << 2) | (((uint64_t)target[0] >> 29) & 0x3ULL)) << 12, 33);
        uint64_t page = ((uint64_t)target&(~0xfffULL)) + pageoff;
        uint64_t ptr = *(uint64_t*)(page + ((((uint64_t)target[1] >> 10) & 0xfffULL) << 3));
        target = xnu_va_to_ptr(kext_rebase_va(ptr));
    }
    DEVLOG("followed call from 0x%llx to 0x%llx", xnu_ptr_to_va(from), xnu_ptr_to_va(target));
    return target;
}

uint32_t* dyld_hook_addr;
bool kpf_dyld_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    // This makes the kernel use a custom dyld path if it is present
    // it replaces the check for dyld matching "/usr/lib/dyld" with code to
    // just force it to be either "/usr/lib/dyld" or our custom path if it
    // is present.
    if (dyld_hook_addr) {
        puts("dyld_hook_addr already found; skipping");
        return false;
    }
    uint8_t rn = (opcode_stream[6]>>5)&0x1f;
    if ((opcode_stream[10]&0xFF00001F) != (0x35000000|rn)) {
        DEVLOG("Invalid match for dyld patch at 0x%llx (missing CBNZ w%d)", xnu_rebase_va(xnu_ptr_to_va(opcode_stream)), rn);
        return false;
    }
    rn = (opcode_stream[3]>>16)&0x1f;
    dyld_hook_addr = &opcode_stream[1];
    opcode_stream[1] = 0;             // BL dyld_hook;
    opcode_stream[2] = 0xAA0003E0|rn; // MOV x20, x0
    opcode_stream[3] = 0x14000008;    // B
    puts("KPF: Patched dyld check");
    return true;
}

bool kpf_amfi_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    // possibly AMFI patch
    // this is here to patch out the trustcache checks so that AMFI thinks that everything is in trustcache
    // there are two different versions of the trustcache function either it's just a leaf that's branched to or it's a function with a real prolog
    // the first protion of this function here will try to detect the prolog and if it fails has_frame will be false
    // if that's the case it will just make it return null
    // otherwise it has to respect the epilog so it will search for all the movs that move into x0 and then turn them into a movz x0, 1
    char has_frame = 0;
    for(int x = 0; x < 128; x++)
    {
        uint32_t opcde = opcode_stream[-x];
        if (opcde == RET || opcde == 0xd65f0fff /*retab*/ || (opcde & 0xFF000000) == 0x94000000 /*bl*/|| (opcde & 0xFF000000) == 0x14000000/*b*/) {
            break;
        }
        if ((opcde & 0xffff0000) == 0xa9430000/*ldp???*/) {
            has_frame = 1;
            break;
        }
        else if((opcde & 0xff0003e0) == 0xa90003e0 /*stp x*,x*, [sp,*]!*/)
        {
            has_frame = 1;
            break;
        }
    }
    if(!has_frame)
    {
        puts("KPF: Found AMFI (Leaf)");
        opcode_stream[0] = 0xd2800020;
        opcode_stream[1] = RET;
    }
    else
    {
        bool found_something = false;
        uint32_t* retpoint = find_next_insn(&opcode_stream[0], 0x180, RET, 0xffffffff);
        if (retpoint == NULL)
        {
            DEVLOG("kpf_amfi_callback: failed to find retpoint");
            return false;
        }
        uint32_t *patchpoint = find_prev_insn(retpoint, 0x40, 0xAA0003E0, 0xffe0ffff);
        // __TEXT_EXEC:__text:FFFFFFF007CDDFDC E0 03 13 AA                 MOV             X0, X19
        if(patchpoint != NULL)
        {
            patchpoint[0] = 0xd2800020;
            found_something = true;
        }
        patchpoint = find_prev_insn(retpoint, 0x40, 0x52800000, 0xffffffff);
        // __TEXT_EXEC:__text:FFFFFFF007CEC260 00 00 80 52                 MOV             W0, #0
        if(patchpoint != NULL)
        {
            patchpoint[0] = 0xd2800020;
            found_something = true;
        }
        if(!found_something)
        {
            DEVLOG("kpf_amfi_callback: failed to find anything");
            return false;
        }
        puts("KPF: Found AMFI (Routine)");
    }
    return true;
}
bool kpf_has_done_mac_mount;
bool kpf_mac_mount_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    puts("KPF: Found mac_mount");
    uint32_t* mac_mount = &opcode_stream[0];
    // search for tbnz w*, 5, *
    // and nop it (enable MNT_UNION mounts)
    uint32_t* mac_mount_1 = find_prev_insn(mac_mount, 0x40, 0x37280000, 0xfffe0000);
    if (!mac_mount_1) {
        mac_mount_1 = find_next_insn(mac_mount, 0x40, 0x37280000, 0xfffe0000);
    }
    if (!mac_mount_1) {
        kpf_has_done_mac_mount = false;
        DEVLOG("kpf_mac_mount_callback: failed to find NOP point");
        return false;
    }
    mac_mount_1[0] = NOP;
    // search for ldrb w8, [x8, 0x71]
    mac_mount_1 = find_prev_insn(mac_mount, 0x40, 0x3941c508, 0xFFFFFFFF);
    if (!mac_mount_1) {
        mac_mount_1 = find_next_insn(mac_mount, 0x40, 0x3941c508, 0xFFFFFFFF);
    }
    if (!mac_mount_1) {
        kpf_has_done_mac_mount = false;
        DEVLOG("kpf_mac_mount_callback: failed to find xzr point");
        return false;
    }
    // replace with a mov x8, xzr
    // this will bypass the (vp->v_mount->mnt_flag & MNT_ROOTFS) check
    mac_mount_1[0] = 0xaa1f03e8;
    kpf_has_done_mac_mount = true;
    xnu_pf_disable_patch(patch);
    puts("KPF: Found mac_mount");
    return true;
}

bool kpf_conversion_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    uint32_t * const orig = opcode_stream;
    uint32_t lr1 = opcode_stream[0],
             lr2 = opcode_stream[2];
    // step 2
    // this makes sure that the register used in the first ldr;tbz is the same and the register in the second one is also the same
    // it makes also sure that both lr offsets are the same
    if((lr1 & 0x1f) != (opcode_stream[1] & 0x1f) || (lr2 & 0x1f) != (opcode_stream[3] & 0x1f) || (lr1 & 0x3ffc00) != (lr2 & 0x3ffc00))
    {
        panic_at(orig, "kpf_conversion_callback: opcode check failed");
    }
    puts("KPF: Found task_conversion_eval");

    // step 3
    // this will then backwards search for this: if (caller == victim) {
    // if the caller is the victim it will always return SUCCESS and so we patch that to always be true and then it will always return SUCCESS
    // for that we first get both of the regs that are used in both of the ldrs (should point to caller and victim)
    // then we look for a cmp where both of them are used
    // this also does some basic flow analysis where it will detect moves that move caller and victim around
    // and we have to check that it is followed by either a ccmp or a b.eq/b.ne, to make sure we got the right one in case there are multiple
    uint32_t regs = (1 << ((lr1 >> 5) & 0x1f)) | (1 << ((lr2 >> 5) & 0x1f));
    for(size_t i = 0; i < 128; ++i) // arbitrary limit
    {
        uint32_t op = *--opcode_stream;
        if((op & 0xffe0fc1f) == 0xeb00001f && (regs & (1 << ((op >> 5) & 0x1f))) != 0 && (regs & (1 << ((op >> 16) & 0x1f))) != 0) // cmp xN, xM
        {
            uint32_t next = opcode_stream[1];
            if(
                (next & 0xffe0fc10) == 0xfa401000 || // ccmp x*, x*, ?, ne
                (next & 0xff00001e) == 0x54000000    // b.eq or b.ne
            )
            {
                *opcode_stream = 0xeb1f03ff; // cmp xzr, xzr
                return true;
            }
        }
        else if((op & 0xffe0ffe0) == 0xaa0003e0) // mov xN, xM
        {
            uint32_t src = (op >> 16) & 0x1f,
                     dst = op & 0x1f;
            regs |= ((regs >> dst) & 1) << src;
        }
    }
    panic_at(orig, "kpf_conversion_callback: failed to find cmp");
}
void kpf_conversion_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // this patch is here to allow the usage of the extracted tfp0 port from userland (see https://bazad.github.io/2018/10/bypassing-platform-binary-task-threads/#the-platform-binary-mitigation)
    // the task_conversion_eval function is often inlinded tho and because of that we need to find it across the kernel
    // there is this line in the functon: if ((victim->t_flags & TF_PLATFORM) && !(caller->t_flags & TF_PLATFORM)) {
    // and we are trying to patchfind it with the sequence below (step 1)
    // we verify that the ldr and tbzs use the same register and that the offset for both ldrs is the same (step 2)
    // after we found that we will upwards search for if (caller == victim) { and patch it to always be true because then the function returns SUCCESS (step 3)
    // this is implemented in the callback
    // example from an iPhone 7 13.3:
    // 0xfffffff00713dca4      3a2f00d0       adrp x26, sym.___stack_chk_guar
    // 0xfffffff00713dca8      5a233b91       add x26, x26, 0xec8
    // 0xfffffff00713dcac      392f00f0       adrp x25, 0xfffffff007724000
    // 0xfffffff00713dcb0      f5260310       adr x21, 0xfffffff00714418c
    // 0xfffffff00713dcb4      1f2003d5       nop
    // 0xfffffff00713dcb8      963640f9       ldr x22, [x20, 0x68] ; [0x68:4]
    // 0xfffffff00713dcbc      08a747f9       ldr x8, [x24, 0xf48] ; [0xf48:4
    // 0xfffffff00713dcc0      9f0316eb       cmp x28, x22 <- then we find this and patch it into cmp xzr, xzr (step 3)
    // 0xfffffff00713dcc4      04115cfa       ccmp x8, x28, 4, ne
    // 0xfffffff00713dcc8      60010054       b.eq 0xfffffff00713dcf4
    // 0xfffffff00713dccc      df0200f1       cmp x22, 0
    // 0xfffffff00713dcd0      041156fa       ccmp x8, x22, 4, ne
    // 0xfffffff00713dcd4      c0060054       b.eq 0xfffffff00713ddac
    // 0xfffffff00713dcd8      218f47f9       ldr x1, [x25, 0xf18] ; [0xf18:4
    // 0xfffffff00713dcdc      e00316aa       mov x0, x22
    // 0xfffffff00713dce0      4e0a0194       bl 0xfffffff007180618
    // ;-- hit0_2:
    // 0xfffffff00713dce4      c8ba43b9       ldr w8, [x22, 0x3b8] ; [0x3b8:4 <- we find this sequence (step 1)
    // 0xfffffff00713dce8      68005036       tbz w8, 0xa, 0xfffffff00713dcf4 <- then we make sure that the register here is also w8 (step 2 in the callback)
    // 0xfffffff00713dcec      88bb43b9       ldr w8, [x28, 0x3b8] ; [0x3b8:4 <- we also make sure that this is also 0x3b8 (step 2)
    // 0xfffffff00713dcf0      e8055036       tbz w8, 0xa, 0xfffffff00713ddac <- same here (step 2)
    // 0xfffffff00713dcf4      81d038d5       mrs x1, tpidr_el1
    // 0xfffffff00713dcf8      c82e4039       ldrb w8, [x22, 0xb] ; [0xb:4]=1
    // 0xfffffff00713dcfc      1f890071       cmp w8, 0x22
    // 0xfffffff00713dd00      41070054       b.ne 0xfffffff00713dde8

    // to find this with r2 run the following cmd:
    // /x 000040b900005036000040b900005036:0000c0ff0000f8ff0000c0ff0000f8fe
    uint64_t matches[] = {
        0xb9400000, // ldr x*, [x*]
        0x36500000, // tbz w*, 0xa, *
        0xb9400000, // ldr x*, [x*]
        0x36500000, // tbz w*, 0xa, *
    };
    uint64_t masks[] = {
        0xffc00000,
        0xfff80000,
        0xffc00000,
        0xfef80000, // match both tbz or tbnz
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "conversion_patch", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_conversion_callback);
}

bool found_convert_port_to_map = false;

bool kpf_convert_port_to_map_callback(struct xnu_pf_patch *patch, uint32_t *opcode_stream)
{
    // Verify that the high regs actually match
    if((opcode_stream[0] & 0x1f) != ((opcode_stream[3] >> 5) & 0x1f))
    {
        return false;
    }
    // Find the next b.eq
    uint32_t *patchpoint = find_next_insn(opcode_stream + 5, 0x18, 0x54000000, 0xff00001f); // b.eq *
    if(!patchpoint)
    {
        return false;
    }
    // Only once
    if(found_convert_port_to_map)
    {
        panic("convert_port_to_map found twice!");
    }
    puts("KPF: Found convert_port_to_map_with_flavor");
    found_convert_port_to_map = true;
    *patchpoint = NOP;
    return true;
}

void kpf_convert_port_to_map_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // This patch is required because in some iOS 14.0 beta, Apple started cracking down on tfp0 usage.
    // In particular, convert_port_to_map_with_flavor will be called when a `vm_map_t` is required for
    // write operations, and that function will panic if the map is backed by the kernel_pmap:
    //
    // panic(cpu 4 caller 0xfffffff007a3a57c): "userspace has control access to a "
    // "kernel map 0xfffffff0ec61a320 through task 0xffffffe19bad64f0"
    //
    // Example from N69 14.0GM kernel:
    //
    // 0xfffffff00713db84      f50301aa       mov x21, x1
    // 0xfffffff00713db88      3f080071       cmp w1, 2
    // 0xfffffff00713db8c      c0020054       b.eq 0xfffffff00713dbe4
    // 0xfffffff00713db90      bf060071       cmp w21, 1
    // 0xfffffff00713db94      e0000054       b.eq 0xfffffff00713dbb0
    // 0xfffffff00713db98      d5020035       cbnz w21, 0xfffffff00713dbf0
    // 0xfffffff00713db9c      21008052       mov w1, 1
    // 0xfffffff00713dba0      97fcff97       bl 0xfffffff00713cdfc
    // 0xfffffff00713dba4      f30300aa       mov x19, x0
    // 0xfffffff00713dba8      a00000b5       cbnz x0, 0xfffffff00713dbbc
    // 0xfffffff00713dbac      11000014       b 0xfffffff00713dbf0
    // 0xfffffff00713dbb0      acfdff97       bl 0xfffffff00713d260
    // 0xfffffff00713dbb4      f30300aa       mov x19, x0
    // 0xfffffff00713dbb8      c00100b4       cbz x0, 0xfffffff00713dbf0
    // 0xfffffff00713dbbc      681640b9       ldr w8, [x19, 0x14]
    // 0xfffffff00713dbc0      c8010034       cbz w8, 0xfffffff00713dbf8
    // 0xfffffff00713dbc4      741640f9       ldr x20, [x19, 0x28]
    // 0xfffffff00713dbc8      802640f9       ldr x0, [x20, 0x48]
    // 0xfffffff00713dbcc      1f2003d5       nop
    // 0xfffffff00713dbd0      c8eeb658       ldr x8, sym._kernel_pmap
    // 0xfffffff00713dbd4      1f0008eb       cmp x0, x8
    // 0xfffffff00713dbd8      80010054       b.eq 0xfffffff00713dc08
    //
    // We look for the first 5 instructions, then find the next `b.eq` and NOP it out.

    // r2 masked search:
    // /x f00301aa3f080071000000541f06007100000054:f0ffffffffffffff1f0000ff1ffeffff1f0000ff
    uint64_t matches[] = {
        0xaa0103f0, // mov x[16-31], x1
        0x7100083f, // cmp w2, #2
        0x54000000, // b.eq *
        0x7100061f, // cmp w[16-31], #1
        0x54000000, // b.eq *
    };
    uint64_t masks[] = {
        0xfffffff0, // mov x[16-31], x1
        0xffffffff, // cmp w2, #2
        0xff00001f, // b.eq *
        0xfffffe1f, // cmp w[16-31], #1
        0xff00001f, // b.eq *
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "convert_port_to_map", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_convert_port_to_map_callback);
}

void kpf_dyld_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // This patch allows us to use a custom dyld path when it is present
    // It matches a small number of places then the callback identifies
    // the correct location for application
    //
    // Applied to load_dylinker; replaces:
    //  if (0 != strcmp(name, DEFAULT_DYLD_PATH)) {
    //    return (LOAD_BADMACHO);
    //  }
    //  with:
    //  name = dyld_hook()
    //
    //  ASM Code we replace looks something like:
    //
    //    B.CS  _return_error
    //    ADRP  X8, #aUsrLibDyld@PAGE ; "/usr/lib/dyld"
    //    ADD   X8, X8, #aUsrLibDyld@PAGEOFF ; "/usr/lib/dyld"
    //    MOV   X9, X20
    //  _next:            // strcmp
    //    LDRB  W10, [X9]
    //    LDRB  W11, [X8] ; "/usr/lib/dyld"
    //    CMP   W10, W11
    //    B.NE  _return_error
    //    ADD   X8, X8, #1
    //    ADD   X9, X9, #1
    //    CBNZ  W10, _next

    uint64_t matches[] = {
        0x54000002, // B.CS
        0x90000000, // ADRP
        0x91000000, // ADD Xn, Xn, #imm
        0xAA0003E0, // MOV Xn, Xy
        0x39400000, // LDRB Wa
        0x39400000, // LDBR Wb
        0x6B00001F  // CMP Wa, Wb
    };
    uint64_t masks[] = {
        0xFF00000F,
        0x9F000000,
        0xFF000000,
        0xFFE0FFE0,
        0xFFFFC000,
        0xFFFFC000,
        0xFFE0FC1F
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "dyld_patch", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_dyld_callback);
}

void kpf_amfi_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // This patch leads to AMFI believing that everything is in trustcache
    // this is done by searching for the sequence below (example from an iPhone 7, 13.3):
    // 0xfffffff0072382b0      29610091       add x9, x9, 0x18
    // 0xfffffff0072382b4      ca028052       movz w10, 0x16
    // 0xfffffff0072382b8      0bfd41d3       lsr x11, x8, 1
    // 0xfffffff0072382bc      6c250a9b       madd x12, x11, x10, x9
    // then the callback checks if this is just a leaf instead of a full routinue
    // if it's a leave it will just replace the above with a movz x0,1;ret
    // if it isn't a leaf it searches for all the places where a return happens and patches them to return true
    // To find the patch in r2 use:
    // /x 0000009100028052000000d30000009b:000000FF00FFFFFF000000FF000000FF
    uint64_t matches[] = {
        0x91000000, // add x*
        0x52800200, // mov w*, 0x16
        0xd3000000, // lsr *
        0x9b000000  // madd *
    };
    uint64_t masks[] = {
        0xFF000000,
        0xFFFFFF00,
        0xFF000000,
        0xFF000000
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "amfi_patch", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_amfi_callback);
}
void kpf_mac_mount_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // This patch makes sure that we can remount the rootfs and that we can UNION mount
    // we first search for a pretty unique instruction movz/orr w9, 0x1ffe
    // then we search for a tbnz w*, 5, * (0x20 is MNT_UNION) and nop it
    // After that we search for a ldrb w8, [x8, 0x71] and replace it with a movz x8, 0
    // at 0x70 there are the flags and MNT_ROOTFS is 0x00004000 -> 0x4000 >> 8 -> 0x40 -> bit 6 -> the check is right below
    // that way we can also perform operations on the rootfs
    uint64_t matches[] = {
        0x321f2fe9, // orr w9, wzr, 0x1ffe
    };
    uint64_t masks[] = {
        0xFFFFFFFF,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "mac_mount_patch1", matches, masks, sizeof(matches)/sizeof(uint64_t), false, (void*)kpf_mac_mount_callback);
    matches[0] = 0x5283ffc9; // movz w9, 0x1ffe
    xnu_pf_maskmatch(xnu_text_exec_patchset, "mac_mount_patch2", matches, masks, sizeof(matches)/sizeof(uint64_t), false, (void*)kpf_mac_mount_callback);
}

bool dounmount_found;
bool kpf_mac_dounmount_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    uint8_t rn;
    if ((opcode_stream[-1]&0xFFE0FFFF) == 0xAA0003E0 &&  // MOV X0, Xn
         (opcode_stream[3]&0xFC000000) == 0x94000000) {  // BL vnode_rele_internal
        rn = (opcode_stream[-1]>>16)&0x1f;
        opcode_stream += 3;
    } else if ((opcode_stream[3]&0xFFE0FFFF) == 0xAA0003E0 &&    // MOV X0, Xn
               (opcode_stream[4]&0xFC000000) == 0x94000000) {    // BL vnode_rele_internal
        rn = (opcode_stream[3]>>16)&0x1f;
        opcode_stream += 4;
    } else {
        // not a match
        return false;
    }

    if ( opcode_stream[1] != (0xAA0003E0|(rn<<16))   || // MOV X0, Xn
        (opcode_stream[2]&0xFC000000) != 0x94000000) {  // BL lck_mtx_lock_spin || BL vnode_put
        // Also not a match
        return false;
    }

    // This is probably it...

    // Find call to vnode_getparent
    // MOV X0, Xn
    // BL vnode_getparent
    // MOV Xn, X0
    uint32_t* mov = find_prev_insn(opcode_stream-3, 0x20, 0xAA0003E0, 0xFFFFFFE0);

    uint8_t parent_rn = 0;
    if (mov &&
        (mov[-2]&0xFFE0FFFF) == 0xAA0003E0 && // MOV X0, Xn
        (mov[-1]&0xFC000000) == 0x94000000) { // BL vnode_getparent
#if DEBUG_DOUNMOUNT
        DEVLOG("Dounmount match for call to vnode_getparent at 0x%llx", xnu_rebase_va(xnu_ptr_to_va(opcode_stream)));
#endif
        parent_rn = *mov&0x1f;
    }

#if DEBUG_DOUNMOUNT
    DEVLOG("Dounmount tenative match at 0x%llx", xnu_rebase_va(xnu_ptr_to_va(opcode_stream)));
#endif

    // Check that we have code to release parent_vnode below
    // MOV W1, #2
    uint32_t* parent_lock = find_next_insn(opcode_stream, 0x100, 0x52800041, 0xFFFFFFFF);
    if (!parent_lock) parent_lock = find_next_insn(opcode_stream, 0x100, 0x321F03E1, 0xFFFFFFFF);
    if (!parent_lock) {
        DEVLOG("Dounmount no parent lock code");
        return false;
    }
#if DEBUG_DOUNMOUNT
    DEVLOG("Dounmount testing parent lock at 0x%llx", xnu_rebase_va(xnu_ptr_to_va(parent_lock)));
#endif

    uint32_t* call;
    if ((parent_lock[-1]&0xFFE0FFFF) == 0xAA0003E0 &&   // MOV X0, Xn
        (parent_lock[1] &0xFC000000) == 0x94000000) {   // BL lock_vnode_and_post
        call = parent_lock+1;
        if (!parent_rn) parent_rn = (parent_lock[-1]>>16)&0x1f;
    } else if ((parent_lock[1]&0xFFE0FFFF) == 0xAA0003E0 &&   // MOV X0, Xn
               (parent_lock[2]&0xFC000000) == 0x94000000) {   // BL lock_vnode_and_post
        if (!parent_rn) parent_rn = (parent_lock[1]>>16)&0x1f;
        call = parent_lock+2;
    } else {
        DEVLOG("Dounmount failed to find first call for parent_vp");
        return false;
    }

    if ( call[1] != (0xAA0003E0|(parent_rn<<16)) ||
        (call[2]&0xFC000000) != 0x94000000) {
        DEVLOG("Dounmount failed to find second call for parent_vp");
        return false;
    }

    if (dounmount_found) {
        panic("dounmount found twice!");
    }

    puts("KPF: Found dounmount");
    opcode_stream[0] = NOP;
#if !DEV_BUILD
    // Only disable in non-dev build on match so that when testing we ensure that the algorithm matches only a single place
    xnu_pf_disable_patch(patch);
#endif
    dounmount_found = true;
    return true;
}
void kpf_mac_dounmount_patch_0(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // This patches out a vnode_release so that we can unmount the rootfs etc without crashing the system
    // For that we search for the series of movs below to find _dounmount and then we patch out one call to vnode_rele inside of it
    // example from the i7 13.3 kernel:
    // 0xfffffff0072ad70c      e00317aa       mov x0, x23
    // 0xfffffff0072ad710      020080d2       movz x2, 0
    // 0xfffffff0072ad714      e32600d0       adrp x3, 0xfffffff00778b000
    // 0xfffffff0072ad718      63a01291       add x3, x3, 0x4a8
    // 0xfffffff0072ad71c      de8f0094       bl 0xfffffff0072d1694
    // 0xfffffff0072ad720      f80300aa       mov x24, x0
    // 0xfffffff0072ad724      80180035       cbnz w0, 0xfffffff0072ada34
    // 0xfffffff0072ad728      b8f642f9       ldr x24, [x21, 0x5e8] ; [0x5e8:4]=3
    // 0xfffffff0072ad72c      3f0318eb       cmp x25, x24
    // 0xfffffff0072ad730      c0020054       b.eq 0xfffffff0072ad788
    // 0xfffffff0072ad734      e00318aa       mov x0, x24
    // 0xfffffff0072ad738      3019fe97       bl sym._lck_mtx_lock_spin
    // 0xfffffff0072ad73c      01008052       movz w1, 0
    // 0xfffffff0072ad740      02008052       movz w2, 0
    // 0xfffffff0072ad744      e00318aa       mov x0, x24
    // 0xfffffff0072ad748      fcf5ff97       bl 0xfffffff0072aaf38
    // 0xfffffff0072ad74c      e00318aa       mov x0, x24
    // 0xfffffff0072ad750      091afe97       bl sym._IOLockUnlock
    // 0xfffffff0072ad754      a8f642f9       ldr x8, [x21, 0x5e8] ; [0x5e8:4]=3
    // 0xfffffff0072ad758      e8c204f9       str x8, [x23, 0x980]
    // 0xfffffff0072ad75c      01008052       movz w1, 0
    // 0xfffffff0072ad760      02008052       movz w2, 0
    // 0xfffffff0072ad764      03008052       movz w3, 0
    // 0xfffffff0072ad768      e00319aa       mov x0, x25
    // 0xfffffff0072ad76c      7bfaff97       bl 0xfffffff0072ac158 <- we patchfind this and then nop it (nfs_vfs_unmount call)
    // 0xfffffff0072ad770      e00319aa       mov x0, x25
    // 0xfffffff0072ad774      2119fe97       bl sym._lck_mtx_lock_spin
    // 0xfffffff0072ad778      e00319aa       mov x0, x25
    // 0xfffffff0072ad77c      75f6ff97       bl 0xfffffff0072ab150
    // r2 command:
    // /x 010080520200805203008052
    // This matches a small number of places, the callback identifies the correct place
    uint64_t matches[] = {
        0x52800001, // movz w1, 0
        0x52800002, // movz w2, 0
        0x52800003, // movz w3, 0
    };
    uint64_t masks[] = {
        0xFFFFFFFF,
        0xFFFFFFFF,
        0xFFFFFFFF,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "dounmount_patch", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_mac_dounmount_callback);
}
uint32_t* shellcode_area;
bool kpf_find_shellcode_area_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(shellcode_area)
    {
        DEVLOG("kpf_find_shellcode_area_callback: already ran, skipping...");
        return false;
    }
    shellcode_area = opcode_stream;
    puts("KPF: Found shellcode area, copying...");
    xnu_pf_disable_patch(patch);
    return true;
}
void kpf_find_shellcode_area(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // find a place inside of the executable region that has no opcodes in it (just zeros/padding)
    extern uint32_t sandbox_shellcode, sandbox_shellcode_end;
    uint32_t count = &sandbox_shellcode_end - &sandbox_shellcode;
    uint64_t matches[count];
    uint64_t masks[count];
    for (int i=0; i<count; i++) {
        matches[i] = 0;
        masks[i] = 0xFFFFFFFF;
    }
    xnu_pf_maskmatch(xnu_text_exec_patchset, "find_shellcode_area", matches, masks, count, true, (void*)kpf_find_shellcode_area_callback);
}
bool kpf_mac_vm_map_protect_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    puts("KPF: Found vm_map_protect");
    // tbnz w8, 9, * in C code this is:
    // if (map->map_disallow_new_exec == TRUE) {
    // and then we jump out of this so that we don't have these checks (no *WX and no new --X when the process has requested it)
    uint32_t* first_ldr = find_next_insn(&opcode_stream[0], 0x400, 0x37480000, 0xFFFF0000);
    if(!first_ldr)
    {
        DEVLOG("kpf_mac_vm_map_protect_callback: failed to find ldr");
        return false;
    }
    first_ldr++;
    uint32_t delta = first_ldr - (&opcode_stream[2]);
    delta &= 0x03ffffff;
    delta |= 0x14000000;
    opcode_stream[2] = delta;
    xnu_pf_disable_patch(patch);
    return true;
}

void kpf_mac_vm_map_protect_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // allow -wx vm_map_protects and new --x mappings even with map_disallow_new_exec set
    // this is done by patchfinding the place where vm_map_protect checks if the new permission contains both EXEC (4) and WRITE (2) -> 6
    // in C code this is:
    // if ((new_prot & VM_PROT_WRITE) &&
    // (new_prot & VM_PROT_EXECUTE) &&
    // [...]
    //      !(current->used_for_jit)) {
    // [...]
    //      printf("CODE SIGNING: %d[%s] %s can't have both write and exec at the same time\n",
    //      new_prot &= ~VM_PROT_EXECUTE;
    //#if VM_PROTECT_WX_FAIL
    //      vm_map_unlock(map);
    //      return KERN_PROTECTION_FAILURE;
    //#endif /* VM_PROTECT_WX_FAIL */
    // [...]
    // if (map->map_disallow_new_exec == TRUE) {
    //      if ((new_prot & VM_PROT_EXECUTE) ||
    //          ((current->protection & VM_PROT_EXECUTE) && (new_prot & VM_PROT_WRITE))) {
    //          vm_map_unlock(map);
    //          return KERN_PROTECTION_FAILURE;
    //      }
    //  }
    // as an example from i7 13.3:
    // 0xfffffff0071c62fc      3f01166b       cmp w9, w22
    // 0xfffffff0071c6300      c1020054       b.ne 0xfffffff0071c6358
    // ;-- hit13_1:
    // 0xfffffff0071c6304      c9061f12       and w9, w22, 6 <- patchfind this
    // 0xfffffff0071c6308      3f190071       cmp w9, 6
    // 0xfffffff0071c630c      81000054       b.ne 0xfffffff0071c631c
    // 0xfffffff0071c6310      6800a837       tbnz w8, 0x15, 0xfffffff0071c631c
    // 0xfffffff0071c6314      61a91094       bl sym._current_proc
    // 0xfffffff0071c6318      d67a1d12       and w22, w22, 0xfffffffb
    // 0xfffffff0071c631c      68364439       ldrb w8, [x19, 0x10d] ; [0x10d:4]=0
    // 0xfffffff0071c6320      a8000836       tbz w8, 1, 0xfffffff0071c6334
    // 0xfffffff0071c6324      b6011037       tbnz w22, 2, 0xfffffff0071c6358
    // 0xfffffff0071c6328      76000836       tbz w22, 1, 0xfffffff0071c6334
    // 0xfffffff0071c632c      284b40b9       ldr w8, [x25, 0x48] ; [0x48:4]=0x5458 ;
    // 0xfffffff0071c6330      48014837       tbnz w8, 9, 0xfffffff0071c6358 <- find this (map->map_disallow_new_exec == TRUE)
    // 0xfffffff0071c6334      290740f9       ldr x9, [x25, 8]    ; [0x8:4]=0xc000001 <- add a branch from the b.ne to here
    // r2 cmd:
    // /x 00061f1200190071:00FFFFFF00FFFFFF
    // or:
    // /x E003202A1f041f7200000054:E0FFE0FF1FFCFFFF000000FF
    uint64_t matches[] = {
        0x121f0600, // and w*, w*, 6
        0x71001900  // subs w*, w*, 6
    };
    uint64_t masks[] = {
        0xffffff00,
        0xffffff00
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vm_map_protect", matches, masks, sizeof(matches)/sizeof(uint64_t), false, (void*)kpf_mac_vm_map_protect_callback);
    uint64_t i_matches[] = {
        0x2A2003E0, // mvn w*, w*
        0x721F041F, // tst w*, 6
        0x54000000  // b.eq *
    };
    uint64_t i_masks[] = {
        0xFFE0FFE0,
        0xFFFFFC1F,
        0xff000000
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vm_map_protect2", i_matches, i_masks, sizeof(i_matches)/sizeof(uint64_t), false, (void*)kpf_mac_vm_map_protect_callback);
}
bool found_vm_fault_enter;
bool vm_fault_enter_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(found_vm_fault_enter)
    {
        DEVLOG("vm_fault_enter_callback: already ran, skipping...");
        return false;
    }
    DEVLOG("Trying vm_fault_enter at 0x%llx", xnu_ptr_to_va(opcode_stream));
    // Should be followed by a TB(N)Z Wx, #2 shortly
    if (!find_next_insn(opcode_stream, 0x18, 0x36100000, 0xFEF80000)) {
        // Wrong place...
        return false;
    }
    uint32_t *b_loc = 0;
    if (!(b_loc = find_prev_insn(opcode_stream, 0x80, 0x14000000, 0xFF000000))) {
        return false;
    }

    uint32_t *wanted_addr = b_loc+1;
    for (int i=2; i<20; i++) {
        uint32_t *try_loc = wanted_addr - i;
        // TBZ or CBZ
        if (((*try_loc|(i<<5))&0xFD07FFE0) == (0x34000000|i<<5)) {
            // Found it!
            *try_loc = NOP;
            puts("KPF: Found vm_fault_enter");
            found_vm_fault_enter = true;
            xnu_pf_disable_patch(patch);
            return true;
        }
    }
    DEVLOG("vm_fault_enter_callback: failed to find patch point");
    return false;
}

bool vm_fault_enter_callback14(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(found_vm_fault_enter)
    {
        DEVLOG("vm_fault_enter_callback: already ran, skipping...");
        return false;
    }
    DEVLOG("Trying vm_fault_enter at 0x%llx", xnu_ptr_to_va(opcode_stream));
    // r2 /x 4006805200000014:ffffffff000000ff
    // make sure this was preceeded by mov x0, 50 and a B
    uint32_t *mov;
    if (!(mov = find_prev_insn(opcode_stream, 0x18, 0x52800640, 0xffffffff)) || (mov[1]&0xff000000) != 0x14000000 ) {
        // This isn't our TBZ
        return false;
    }
    opcode_stream[0] = NOP;
    puts("KPF: Found vm_fault_enter");
    found_vm_fault_enter = true;
    xnu_pf_disable_patch(patch);
    return true;
}

void kpf_mac_vm_fault_enter_patch(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // this patch is in vm_fault_enter
    // there is a check for cs_bypass and if that's true it will just exit without validation
    // the opcode is tbz w*, 3, * (because it's the 4th bitflag) and we don't want to take that jump that's why we nop it
    // example from i7 13.3:
    // 0xfffffff0071b3e08      ba001836       tbz w26, 3, 0xfffffff0071b3e1c
    // 0xfffffff0071b3e0c      bf0313b8       stur wzr, [x29, -0xd0]
    // 0xfffffff0071b3e10      1c008052       movz w28, 0
    // 0xfffffff0071b3e14      b98356b8       ldur w25, [x29, -0x98]
    // 0xfffffff0071b3e18      0e010014       b 0xfffffff0071b4250
    // 0xfffffff0071b3e1c      09019837       tbnz w9, 0x13, 0xfffffff0071b3e3c
    // in C code:
    // if (cs_bypass) {
    //   /* code-signing is bypassed */
    //  cs_violation = FALSE;
    //  } else if (m->vmp_cs_tainted) {
    //  [...]
    // r2 cmd:
    // /x 000018361234567800008052:00ffffff0000000000ffffff
    // The problem with this patch was that on some 13.4 kernels they added an instruction between the tbz and movz
    // Because of that we decided to go with a more robuse patch
    // For that we first find the function by searching for the following:
    // 0xfffffff0071b3df0      99001036       tbz w25, 2, 0xfffffff0071b3e00
    // 0xfffffff0071b3df4      6900a036       tbz w9, 0x14, 0xfffffff0071b3e00
    // r2 cmd: /x 000010360000a036:0000ffff0000ffff
    // And then we search downwards for the tbz w*, 3, *  and nop it
    uint64_t matches[] = {
        0x37980000,  // TBNZ Wn, #0x13
        0x37900000   // TBNZ Wn, #0x12
    };
    uint64_t masks[] = {
        0xFFF80000,
        0xFFF80000
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vm_fault_enter", matches, masks, sizeof(matches)/sizeof(uint64_t), false, (void*)vm_fault_enter_callback);
    uint64_t matches_i[] = {
        0x37980000,  // TBNZ Wn, #0x13
        0x34000000,  // CBZ
        0x37900000   // TBNZ Wn, #0x12
    };
    uint64_t masks_i[] = {
        0xFFF80000,
        0xFF000000,
        0xFFF80000
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vm_fault_enter", matches_i, masks_i, sizeof(matches)/sizeof(uint64_t), false, (void*)vm_fault_enter_callback);
    uint64_t matches14[] = {
        0x36180000, // TBZ #3
        0x52800000, // MOV #0
    };
    uint64_t masks14[] = {
        0xFFF80000,
        0xFFFFFFE0,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vm_fault_enter", matches14, masks14, sizeof(matches14)/sizeof(uint64_t), false, (void*)vm_fault_enter_callback14);
    uint64_t matches14_alt[] = {
        0x36180000, // TBZ #3
        0xAA170210, // MOV Xd, Xn (both regs >= 16)
        0x52800000, // MOV #0
    };
    uint64_t masks14_alt[] = {
        0xFFF80000,
        0xFFFFFE10,
        0xFFFFFFE0,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vm_fault_enter", matches14_alt, masks14_alt, sizeof(matches14_alt)/sizeof(uint64_t), false, (void*)vm_fault_enter_callback14);
}

static bool nvram_inline_patch = false;
static uint32_t *nvram_patchpoint = NULL;
bool nvram_unlock_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(nvram_patchpoint || nvram_inline_patch)
    {
        panic("More than one hit for nvram_unlock");
    }

    nvram_patchpoint = find_next_insn(opcode_stream, 0x10, RET, 0xffffffff);
    return nvram_patchpoint != NULL;
}

bool nvram_unlock_inline_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(nvram_patchpoint || nvram_inline_patch)
    {
        panic("More than one hit for nvram_unlock");
    }

    // Most reliable marker of a stack frame seems to be "add x29, sp, 0x...".
    // And this function is HUGE, hence up to 2k insn.
    uint32_t *frame = find_prev_insn(opcode_stream, 2000, 0x910003fd, 0xff8003ff);
    if(!frame) return false;

    // Now find the insn that decrements sp. This can be either
    // "stp ..., ..., [sp, -0x...]!" or "sub sp, sp, 0x...".
    // Match top bit of imm on purpose, since we only want negative offsets.
    uint32_t  *start = find_prev_insn(frame, 10, 0xa9a003e0, 0xffe003e0);
    if(!start) start = find_prev_insn(frame, 10, 0xd10003ff, 0xff8003ff);
    if(!start) return false;

    start[0] = 0x52800020; // mov w0, 1
    start[1] = RET;

    nvram_inline_patch = true;
    return true;
}

void kpf_nvram_unlock(xnu_pf_patchset_t* xnu_text_exec_patchset)
{
    // Find IODTNVRAM::getOFVariablePerm().
    // Gonna patch its "ret" to branch to our shellcode, where we update
    // the return value if appropriate (see _nvram_shc in shellcode.S).

    // iOS 13 and below:
    uint64_t matches1[] = {
        0xf8418c00, // ldr x*, [x*, 0x18]!
        0xb5000000, // cbnz x*, 0x...
        0xb9400c00, // ldr w0, [x*, 0xc]
    };
    uint64_t masks1[] = {
        0xfffffc00,
        0xff000000,
        0xfffffc1f,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "nvram_unlock", matches1, masks1, sizeof(matches1)/sizeof(uint64_t), false, (void*)nvram_unlock_callback);

    // iOS 14.0 and 14.1:
    uint64_t matches2[] = {
        0xf8418c00, // ldr x*, [x*, 0x18]!
        0xb5000000, // cbnz x*, 0x...
        0xaa090000, // mov x*, x*
        0xb9400c00, // ldr w0, [x*, 0xc]
    };
    uint64_t masks2[] = {
        0xfffffc00,
        0xff000000,
        0xfffffc00,
        0xfffffc1f,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "nvram_unlock", matches2, masks2, sizeof(matches2)/sizeof(uint64_t), false, (void*)nvram_unlock_callback);

    // In iOS 14.2, IODTNVRAM saw a complete refactor. The virtual methods for
    // variable type/permission now just return 0, and there are dedicated
    // functions for white- and blacklisted variables. The blacklist has all
    // entried inlined as byte-by-byte comparisons like so:
    //     0xfffffff007710b8c      28444039       ldrb w8, [x1, 0x11]
    //     0xfffffff007710b90      1f890171       cmp w8, 0x62
    //     0xfffffff007710b94      c1030054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710b98      28484039       ldrb w8, [x1, 0x12]
    //     0xfffffff007710b9c      1fbd0171       cmp w8, 0x6f
    //     0xfffffff007710ba0      61030054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710ba4      284c4039       ldrb w8, [x1, 0x13]
    //     0xfffffff007710ba8      1fbd0171       cmp w8, 0x6f
    //     0xfffffff007710bac      01030054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710bb0      28504039       ldrb w8, [x1, 0x14]
    //     0xfffffff007710bb4      1fd10171       cmp w8, 0x74
    //     0xfffffff007710bb8      a1020054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710bbc      28544039       ldrb w8, [x1, 0x15]
    //     0xfffffff007710bc0      1fb50071       cmp w8, 0x2d
    //     0xfffffff007710bc4      41020054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710bc8      28584039       ldrb w8, [x1, 0x16]
    //     0xfffffff007710bcc      1fb90171       cmp w8, 0x6e
    //     0xfffffff007710bd0      e1010054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710bd4      285c4039       ldrb w8, [x1, 0x17]
    //     0xfffffff007710bd8      1fbd0171       cmp w8, 0x6f
    //     0xfffffff007710bdc      81010054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710be0      28604039       ldrb w8, [x1, 0x18]
    //     0xfffffff007710be4      1fb90171       cmp w8, 0x6e
    //     0xfffffff007710be8      21010054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710bec      28644039       ldrb w8, [x1, 0x19]
    //     0xfffffff007710bf0      1f8d0171       cmp w8, 0x63
    //     0xfffffff007710bf4      c1000054       b.ne 0xfffffff007710c0c
    //     0xfffffff007710bf8      28684039       ldrb w8, [x1, 0x1a]
    //     0xfffffff007710bfc      1f950171       cmp w8, 0x65
    //     0xfffffff007710c00      61000054       b.ne 0xfffffff007710c0c
    // The above code checks for the "boot-nonce" part of "com.apple.System.boot-nonce".
    // We find that bit specifically, then seek backwards to the start of the
    // function and just patch it to return true unconditionally.
    uint64_t matches3[] = {
        0x39404400, 0x7101881f, 0x54000001, // b
        0x39404800, 0x7101bc1f, 0x54000001, // o
        0x39404c00, 0x7101bc1f, 0x54000001, // o
        0x39405000, 0x7101d01f, 0x54000001, // t
        0x39405400, 0x7100b41f, 0x54000001, // -
        0x39405800, 0x7101b81f, 0x54000001, // n
        0x39405c00, 0x7101bc1f, 0x54000001, // o
        0x39406000, 0x7101b81f, 0x54000001, // n
        0x39406400, 0x71018c1f, 0x54000001, // c
        0x39406800, 0x7101941f, 0x54000001, // e
    };
    uint64_t masks3[] = {
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
        0xfffffc00, 0xfffffc1f, 0xff00001f,
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "nvram_unlock", matches3, masks3, sizeof(matches3)/sizeof(uint64_t), false, (void*)nvram_unlock_inline_callback);
}

uint32_t *vnode_gaddr;

bool vnode_getattr_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    if (vnode_gaddr) panic("vnode_getattr_callback: invoked twice");
    puts("KPF: Found vnode_getattr");
    vnode_gaddr = find_prev_insn(opcode_stream, 0x80, 0xd10000FF, 0xFF0000FF);
    xnu_pf_disable_patch(patch);
    return !!vnode_gaddr;
}

uint32_t repatch_ldr_x19_vnode_pathoff;
bool vnode_getpath_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(repatch_ldr_x19_vnode_pathoff)
    {
        DEVLOG("vnode_getpath_callback: already ran, skipping...");
        return false;
    }
    puts("KPF: Found vnode_getpath");
    repatch_ldr_x19_vnode_pathoff = opcode_stream[-2];
    xnu_pf_disable_patch(patch);
    return true;
}
uint64_t ret0_gadget;
bool ret0_gadget_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(ret0_gadget)
    {
        DEVLOG("ret0_gadget_callback: already ran, skipping...");
        return false;
    }
    puts("KPF: Found ret0 gadget");
    ret0_gadget = xnu_ptr_to_va(opcode_stream);
    xnu_pf_disable_patch(patch);
    return true;
}

uint32_t *vnode_lookup,
         *vnode_put,
         *vfs_context_current;

bool vnode_lookup_callback(struct xnu_pf_patch* patch, uint32_t* opcode_stream)
{
    if(vnode_lookup)
    {
        DEVLOG("vnode_lookup_callback: already ran, skipping...");
        return false;
    }
    uint32_t *try = &opcode_stream[8]+((opcode_stream[8]>>5)&0xFFF);
    if ((try[0]&0xFFE0FFFF) != 0xAA0003E0 ||    // MOV x0, Xn
        (try[1]&0xFC000000) != 0x94000000 ||    // BL _sfree
        (try[3]&0xFF000000) != 0xB4000000 ||    // CBZ
        (try[4]&0xFC000000) != 0x94000000 ) {   // BL _vnode_put
        DEVLOG("Failed match of vnode_lookup code at 0x%llx", kext_rebase_va(xnu_ptr_to_va(opcode_stream)));
        return false;
    }
    puts("KPF: Found vnode_lookup");
    vfs_context_current = follow_call(&opcode_stream[1]);
    vnode_lookup = follow_call(&opcode_stream[6]);
    vnode_put = follow_call(&try[4]);
    xnu_pf_disable_patch(patch);
    return true;
}

void kpf_find_shellcode_funcs(xnu_pf_patchset_t* xnu_text_exec_patchset) {
    // to find this with r2 run:
    // /x 00008192007fbef2:00ffffff00ffffff
    uint64_t matches[] = {
        0x92810000, // movn x*, 0x800
        0xf2be7f00  // movk x*, 0xf3f8, lsl 16
    };
    uint64_t masks[] = {
        0xffffff00,
        0xffffff00
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vnode_getattr", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)vnode_getattr_callback);

    uint64_t ii_matches[] = {
        0xaa1303e0, // mov x0, x19
        0,
        0xaa0003e1, // mov x1, x0
        0x52800002, // movz w2, 0
        0x52800003, // movz w3, 0
        0xaa1303e0  // mov x0, x19
    };
    uint64_t ii_masks[] = {
        0xffffffff,
        0,
        0xffffffff,
        0xffffffff,
        0xffffffff,
        0xffffffff
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vnode_getpath", ii_matches, ii_masks, sizeof(ii_matches)/sizeof(uint64_t), false, (void*)vnode_getpath_callback);
    uint64_t iii_matches[] = {
        0xaa1303e0, // mov x0, x19
        0,
        0xaa0003e1, // mov x1, x0
        0xaa1303e0, // mov x0, x19
        0x52800002, // movz w2, 0
        0x52800003  // movz w3, 0
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "vnode_getpath", iii_matches, ii_masks, sizeof(ii_matches)/sizeof(uint64_t), false, (void*)vnode_getpath_callback);

    uint64_t iiii_matches[] = {
        0xd2800000, // movz x0, 0
        RET
    };
    uint64_t iiii_masks[] = {
        0xffffffff,
        0xffffffff
    };
    xnu_pf_maskmatch(xnu_text_exec_patchset, "ret0_gadget", iiii_matches, iiii_masks, sizeof(iiii_masks)/sizeof(uint64_t), true, (void*)ret0_gadget_callback);
}

uint64_t traps_mask[] = { 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0, 0, 0xffffffffffffffff };
uint64_t traps_match[] = { 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0, 0x0000000000000000, 0x0000000000000000, 0x0000000000000004, 0, 0, 0x0000000000000005 };
bool mach_traps_callback(struct xnu_pf_patch* patch, uint64_t* mach_traps) {
    puts("KPF: Found mach traps");

    // for the task for pid routine we only need to patch the first branch that checks if the pid == 0
    // we just replace it with a nop
    // see vm_unix.c in xnu
    uint64_t tfp = xnu_rebase_va(mach_traps[45 * 4 + 1]);

    uint32_t* tfp0check = find_next_insn((uint32_t*)xnu_va_to_ptr(tfp), 0x20, 0x34000000, 0xff000000);
    if(!tfp0check)
    {
        DEVLOG("mach_traps_callback: failed to find tfp0check");
        return false;
    }

    tfp0check[0] = NOP;
    puts("KPF: Found tfp0");

    xnu_pf_disable_patch(patch);

    return true;
}
bool has_found_sbops = 0;
uint64_t* sbops;
bool sb_ops_callback(struct xnu_pf_patch* patch, uint64_t* sbops_stream) {
    puts("KPF: Found sbops");
    sbops = sbops_stream;
    has_found_sbops = true;
    xnu_pf_disable_patch(patch);
    return true;
}
bool kpf_apfs_patches_rename(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    puts("KPF: Found APFS rename");
    opcode_stream[3] = NOP;
    return true;
}

bool kpf_apfs_patches_mount(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    // cmp x0, x8
    uint32_t* f_apfs_privcheck = find_next_insn(opcode_stream, 0x10, 0xeb08001f, 0xFFFFFFFF);
    if (!f_apfs_privcheck) {
        DEVLOG("kpf_apfs_patches_mount: failed to find f_apfs_privcheck");
        return false;
    }
    puts("KPF: Found APFS mount");
    *f_apfs_privcheck = 0xeb00001f; // cmp x0, x0
    return true;
}
void kpf_apfs_patches(xnu_pf_patchset_t* patchset) {
    // there is a check in the apfs mount function that makes sure that the kernel task is calling this function (current_task() == kernel_task)
    // we also want to call it so we patch that check out
    // example from i7 13.3:
    // 0xfffffff00692e67c      e8034139       ldrb w8, [sp, 0x40] ; [0x40:4]=392 <- we patchfind this
    // 0xfffffff00692e680      08011b32       orr w8, w8, 0x20
    // 0xfffffff00692e684      e8030139       strb w8, [sp, 0x40]
    // 0xfffffff00692e688      e83b40b9       ldr w8, [sp, 0x38]  ; [0x38:4]=0
    // 0xfffffff00692e68c      e85301b9       str w8, [sp, 0x150]
    // 0xfffffff00692e690      e85741b9       ldr w8, [sp, 0x154] ; [0x154:4]=0x7c95
    // 0xfffffff00692e694      08010032       orr w8, w8, 1
    // 0xfffffff00692e698      e85701b9       str w8, [sp, 0x154]
    // 0xfffffff00692e69c      59550194       bl sym.stub._current_task_31
    // 0xfffffff00692e6a0      e83100b0       adrp x8, 0xfffffff006f6b000 <- kernel task
    // 0xfffffff00692e6a4      089544f9       ldr x8, [x8, 0x928] ; [0x928:4]=0x5458
    // 0xfffffff00692e6a8      080140f9       ldr x8, [x8]
    // 0xfffffff00692e6ac      1f0008eb       cmp x0, x8 <- cmp (patches to cmp x0, x0)
    // r2 cmd:
    // /x 0000003908011b3200000039000000b9:000000ffffffffff000000ff000000ff
    uint64_t matches[] = {
        0x39000000, // strb w*, [x*]
        0x321b0108, // orr w8, w8, 0x20
        0x39000000, // strb w*, [x*]
        0xb9000000  // str w*, [x*]
    };
    uint64_t masks[] = {
        0xff000000,
        0xffffffff,
        0xff000000,
        0xff000000,
    };
    xnu_pf_maskmatch(patchset, "apfs_patch_mount", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_apfs_patches_mount);
    // the rename function will prevent us from renaming a snapshot that's on the rootfs, so we will just patch that check out
    // example from i7 13.3
    // 0xfffffff0068f3d58      e02f00f9       str x0, [sp, 0x58]
    // 0xfffffff0068f3d5c      e01f00f9       str x0, [sp, 0x38]
    // 0xfffffff0068f3d60      08c44039       ldrb w8, [x0, 0x31] ; [0x31:4]=
    // 0xfffffff0068f3d64      68043037       tbnz w8, 6, 0xfffffff0068f3df0 <- patch this out
    // Since iOS 15, the "str" can also be "stur", so we mask out one of the upper bits to catch both,
    // and we apply a mask of 0x1d to the base register, to catch exactly x29 and sp.
    // r2 cmd:
    // /x a00300f8a00300f80000403900003037:a003c0fea003c0fe0000feff0000f8ff
    uint64_t i_matches[] = {
        0xf80003a0, // st(u)r x*, [x29/sp, *]
        0xf80003a0, // st(u)r x*, [x29/sp, *]
        0x39400000, // ldrb w*, [x*]
        0x37300000, // tbnz w*, 6, *
    };
    uint64_t i_masks[] = {
        0xfec003a0,
        0xfec003a0,
        0xfffe0000,
        0xfff80000,
    };
    xnu_pf_maskmatch(patchset, "apfs_patch_rename", i_matches, i_masks, sizeof(i_matches)/sizeof(uint64_t), true, (void*)kpf_apfs_patches_rename);
}
uint32_t* amfi_ret;
bool kpf_amfi_execve_tail(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    amfi_ret = find_next_insn(opcode_stream, 0x80, RET, 0xFFFFFFFF);
    if (!amfi_ret)
    {
        DEVLOG("kpf_amfi_execve_tail: failed to find amfi_ret");
        return false;
    }
    puts("KPF: Found AMFI execve hook");
    xnu_pf_disable_patch(patch);
    return true;
}
bool kpf_amfi_sha1(struct xnu_pf_patch* patch, uint32_t* opcode_stream) {
    uint32_t* cmp = find_next_insn(opcode_stream, 0x10, 0x7100081f, 0xFFFFFFFF); // cmp w0, 2
    if (!cmp) {
        DEVLOG("kpf_amfi_sha1: failed to find cmp");
        return false;
    }
    puts("KPF: Found AMFI hashtype check");
    xnu_pf_disable_patch(patch);
    *cmp = 0x6b00001f; // cmp w0, w0
    return true;
}

void kpf_find_offset_p_flags(uint32_t *proc_issetugid) {
    DEVLOG("Found kpf_find_offset_p_flags 0x%llx", xnu_ptr_to_va(proc_issetugid));
    if (!proc_issetugid) {
        panic("kpf_find_offset_p_flags called with no argument");
    }
    // FIND LDR AND READ OFFSET
    if((*proc_issetugid & 0xffc003c0) != 0xb9400000)
    {
        panic("kpf_find_offset_p_flags failed to find LDR");
    }
    offsetof_p_flags = ((*proc_issetugid>>10)&0xFFF)<<2;
    DEVLOG("Found offsetof_p_flags %x", offsetof_p_flags);
}

bool found_amfi_mac_syscall = false;
bool kpf_amfi_mac_syscall(struct xnu_pf_patch *patch, uint32_t *opcode_stream) {
    if(found_amfi_mac_syscall)
    {
        panic("amfi_mac_syscall found twice!");
    }
    // Our initial masking match is extremely broad and we have two of them so
    // we have to mark both as non-required, which means returning false does
    // nothing. But we panic on failure, so if we survive, we patched successfully.
    found_amfi_mac_syscall = true;

    bool foundit = false;
    uint32_t *rep = opcode_stream;
    for(size_t i = 0; i < 25; ++i)
    {
        if((rep[0] == 0x321c03e2 /* orr w2, wzr, 0x10 */ || rep[0] == 0x52800202 /* movz w2, 0x10 */))
        {
            foundit = true;
            puts("KPF: Found AMFI mac_syscall");
            break;
        }
        rep++;
    }
    if(!foundit)
    {
        panic_at(rep, "Failed to find w2 in mac_syscall");
    }
    uint32_t *copyin = find_next_insn(rep + 1, 2, 0x94000000, 0xfc000000); // bl
    if(!copyin)
    {
        panic_at(rep, "Failed to find copyin in mac_syscall");
    }
    uint32_t *bl = find_next_insn(copyin + 1, 10, 0x94000000, 0xfc000000);
    if(!bl)
    {
        panic_at(rep, "Failed to find check_dyld_policy_internal in mac_syscall");
    }
    uint32_t *check_dyld_policy_internal = follow_call(bl);
    if(!check_dyld_policy_internal)
    {
        panic_at(bl, "Failed to follow call to check_dyld_policy_internal");
    }
    // Find call to proc_issetuid
    uint32_t *ref = find_next_insn(check_dyld_policy_internal, 10, 0x94000000, 0xfc000000);
    if((ref[1] & 0xff00001f) != 0x34000000)
    {
        panic_at(check_dyld_policy_internal, "CBZ missing after call to proc_issetuid");
    }
    // Save offset of p_flags
    kpf_find_offset_p_flags(follow_call(ref));
    // Follow CBZ
    ref++;
    ref += sxt32(*ref >> 5, 19); // uint32 takes care of << 2
    uint32_t *proc_has_get_task_allow = find_next_insn(ref, 5, 0x94000000, 0xfc000000);
    if(!proc_has_get_task_allow)
    {
        panic_at(ref, "Failed to find proc_has_get_task_allow in check_dyld_policy_internal");
    }
    if((proc_has_get_task_allow[1] != 0x7100001f /* cmp w0, 0 */) && ((proc_has_get_task_allow[1] & 0xfff8001f) != 0x36000000 /* tbz w0, 0, ... */))
    {
        panic_at(check_dyld_policy_internal, "CMP/TBZ missing after call to proc_has_get_task_allow");
    }
    proc_has_get_task_allow[0] = 0x52800020; // MOV W0, #1
    return true;
}
void kpf_amfi_kext_patches(xnu_pf_patchset_t* patchset) {
    // this patch helps us find the return of the amfi function so that we can jump into shellcode from there and modify the cs flags
    // to do that we search for the sequence below also as an example from i7 13.3:
    // 0xfffffff005f340cc      00380b91       add x0, x0, 0x2ce
    // 0xfffffff005f340d0      48000014       b 0xfffffff005f341f0
    // 0xfffffff005f340d4      230c0094       bl sym.stub._cs_system_require_lv
    // 0xfffffff005f340d8      e80240b9       ldr w8, [x23]
    // 0xfffffff005f340dc      80000034       cbz w0, 0xfffffff005f340ec
    // 0xfffffff005f340e0      09408452       movz w9, 0x2200
    // 0xfffffff005f340e4      0801092a       orr w8, w8, w9
    // to find this with r2 run:
    // /x 00000034094084520801092a:000000FFFFFFFFFFFFFFFFFFFFFFFFFF
    uint64_t matches[] = {
        0x34000000, // cbz w*
        0x52844009, // movz w9, 0x2200
        0x2a090108  // orr w8, w8, w9
    };
    uint64_t masks[] = {
        0xff000000,
        0xffffffff,
        0xffffffff,
    };
    xnu_pf_maskmatch(patchset, "amfi_execve_tail", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_amfi_execve_tail);

    // this patch allows us to run binaries with SHA1 signatures
    // this is done by searching for the sequence below and then finding the cmp w0, 2 (hashtype) and turning that into a cmp w0, w0
    // Example from i7 13.3:
    // 0xfffffff005f36b30      2201d036       tbz w2, 0x1a, 0xfffffff005f36b54
    // 0xfffffff005f36b34      f30305aa       mov x19, x5
    // 0xfffffff005f36b38      f40304aa       mov x20, x4
    // 0xfffffff005f36b3c      f50303aa       mov x21, x3
    // 0xfffffff005f36b40      f60300aa       mov x22, x0
    // 0xfffffff005f36b44      e00301aa       mov x0, x1
    // 0xfffffff005f36b48      a1010094       bl sym.stub._csblob_get_hashtype
    // 0xfffffff005f36b4c      1f080071       cmp w0, 2
    // 0xfffffff005f36b50      61000054       b.ne 0xfffffff005f36b5c
    // to find this in r2 run (make sure to check if the address is aligned):
    // /x 0200d036:1f00f8ff
    uint64_t i_matches[] = {
        0x36d00002, // tbz w2, 0x1a, *
    };
    uint64_t i_masks[] = {
        0xfff8001f,
    };
    xnu_pf_maskmatch(patchset, "amfi_sha1",i_matches, i_masks, sizeof(i_matches)/sizeof(uint64_t), true, (void*)kpf_amfi_sha1);

    // this patch will patch out checks for get_task_allow inside of the mac_syscall
    // this is done by searching for the sequence below (both syscall numbers that are handled inside of the function), then following the call and patching out the get_task_allow check
    // this patch also provides the location to identify the offset of proc->p_flags which is used by the setuid shellcode
    // Example from i7 13.3:
    // 0xfffffff005f365a0      3f6c0171       cmp w1, 0x5b <- we first find this sequence
    // 0xfffffff005f365a4      e0020054       b.eq 0xfffffff005f36600
    // 0xfffffff005f365a8      3f680171       cmp w1, 0x5a
    // 0xfffffff005f365ac      41060054       b.ne 0xfffffff005f36674
    // 0xfffffff005f365b0      40e5054f       movi v0.16b, 0xaa
    // 0xfffffff005f365b4      e007803d       str q0, [sp, 0x10]
    // 0xfffffff005f365b8      ff0700f9       str xzr, [sp, 8]
    // 0xfffffff005f365bc      020600b4       cbz x2, 0xfffffff005f3667c
    // 0xfffffff005f365c0      f40300aa       mov x20, x0
    // 0xfffffff005f365c4      e1430091       add x1, sp, 0x10
    // 0xfffffff005f365c8      e00302aa       mov x0, x2
    // 0xfffffff005f365cc      e2031c32       orr w2, wzr, 0x10
    // 0xfffffff005f365d0      cf020094       bl sym.stub._copyin
    // 0xfffffff005f365d4      f30300aa       mov x19, x0
    // 0xfffffff005f365d8      40050035       cbnz w0, 0xfffffff005f36680
    // 0xfffffff005f365dc      e1230091       add x1, sp, 8
    // 0xfffffff005f365e0      e00314aa       mov x0, x20
    // 0xfffffff005f365e4      ed000094       bl 0xfffffff005f36998 <- then nops this and make sure x1 is -1
    // 0xfffffff005f365e8      e10f40f9       ldr x1, [sp, 0x18]  ; [0x18
    // 0xfffffff005f365ec      e0230091       add x0, sp, 8
    // 0xfffffff005f365f0      e2031d32       orr w2, wzr, 8 <- then this
    // 0xfffffff005f365f4      c9020094       bl sym.stub._copyout_1
    // to find this in r2 run:
    // /x 3f6c0171000000003f680171:FFFFFFFF00000000FFFFFFFF
    uint64_t ii_matches[] = {
        0x71016C3F, // cmp w1, 0x5b
        0,
        0x7101683F  // cmp w1, 0x5a
    };
    uint64_t ii_masks[] = {
        0xffffffff,
        0,
        0xffffffff,
    };
    xnu_pf_maskmatch(patchset, "amfi_mac_syscall", ii_matches, ii_masks, sizeof(ii_matches)/sizeof(uint64_t), false, (void*)kpf_amfi_mac_syscall);

    // iOS 15 changed to a switch/case:
    //
    // 0xfffffff00830e9cc      ff4303d1       sub sp, sp, 0xd0
    // 0xfffffff00830e9d0      f6570aa9       stp x22, x21, [sp, 0xa0]
    // 0xfffffff00830e9d4      f44f0ba9       stp x20, x19, [sp, 0xb0]
    // 0xfffffff00830e9d8      fd7b0ca9       stp x29, x30, [sp, 0xc0]
    // 0xfffffff00830e9dc      fd030391       add x29, sp, 0xc0
    // 0xfffffff00830e9e0      08a600b0       adrp x8, 0xfffffff0097cf000
    // 0xfffffff00830e9e4      1f2003d5       nop
    // 0xfffffff00830e9e8      083940f9       ldr x8, [x8, 0x70]
    // 0xfffffff00830e9ec      a8831df8       stur x8, [x29, -0x28]
    // 0xfffffff00830e9f0      d3098052       mov w19, 0x4e
    // 0xfffffff00830e9f4      28680151       sub w8, w1, 0x5a
    // 0xfffffff00830e9f8      1f290071       cmp w8, 0xa
    // 0xfffffff00830e9fc      88150054       b.hi 0xfffffff00830ecac
    // 0xfffffff00830ea00      f40302aa       mov x20, x2
    // 0xfffffff00830ea04      f50300aa       mov x21, x0
    // 0xfffffff00830ea08      296afff0       adrp x9, 0xfffffff007055000
    // 0xfffffff00830ea0c      29c13d91       add x9, x9, 0xf70
    // 0xfffffff00830ea10      8a000010       adr x10, 0xfffffff00830ea20
    // 0xfffffff00830ea14      2b696838       ldrb w11, [x9, x8]
    // 0xfffffff00830ea18      4a090b8b       add x10, x10, x11, lsl 2
    // 0xfffffff00830ea1c      40011fd6       br x10
    // 0xfffffff00830ea20      40e5054f       movi v0.16b, 0xaa
    // 0xfffffff00830ea24      e00f803d       str q0, [sp, 0x30]
    // 0xfffffff00830ea28      ff0f00f9       str xzr, [sp, 0x18]
    // 0xfffffff00830ea2c      f41300b4       cbz x20, 0xfffffff00830eca8
    // 0xfffffff00830ea30      e1c30091       add x1, sp, 0x30
    // 0xfffffff00830ea34      e00314aa       mov x0, x20
    // 0xfffffff00830ea38      02028052       mov w2, 0x10
    // 0xfffffff00830ea3c      8e3ee797       bl 0xfffffff007cde474
    // 0xfffffff00830ea40      f30300aa       mov x19, x0
    // 0xfffffff00830ea44      40130035       cbnz w0, 0xfffffff00830ecac
    // 0xfffffff00830ea48      e1630091       add x1, sp, 0x18
    // 0xfffffff00830ea4c      e00315aa       mov x0, x21
    // 0xfffffff00830ea50      7c020094       bl 0xfffffff00830f440
    // 0xfffffff00830ea54      e11f40f9       ldr x1, [sp, 0x38]
    // 0xfffffff00830ea58      e0630091       add x0, sp, 0x18
    // 0xfffffff00830ea5c      02018052       mov w2, 8
    // 0xfffffff00830ea60      50000014       b 0xfffffff00830eba0
    //
    // We find the "sub wN, w1, 0x5a", then the "mov w2, 0x10; bl ..." after that, then the "bl" after that.
    // /x 20680151:e0ffffff
    uint64_t iii_matches[] = {
        0x51016820, // sub wN, w1, 0x5a
    };
    uint64_t iii_masks[] = {
        0xffffffe0,
    };
    xnu_pf_maskmatch(patchset, "amfi_mac_syscall_alt", iii_matches, iii_masks, sizeof(iii_matches)/sizeof(uint64_t), false, (void*)kpf_amfi_mac_syscall);
}

void kpf_sandbox_kext_patches(xnu_pf_patchset_t* patchset) {
    uint64_t matches[] = {
        0x35000000, // CBNZ
        0x94000000, // BL _vfs_context_current
        0xAA0003E0, // MOV Xn, X0
        0xD1006002, // SUB
        0x00000000, // MOV X0, Xn || MOV W1, #0
        0x00000000, // MOV X0, Xn || MOV W1, #0
        0x94000000, // BL _vnode_lookup
        0xAA0003E0, // MOV Xn, X0
        0x35000000  // CBNZ
    };
    uint64_t masks[] = {
        0xFF000000,
        0xFC000000,
        0xFFFFFFE0,
        0xFFFFE01F,
        0x00000000,
        0x00000000,
        0xFC000000,
        0xFFFFFFE0,
        0xFF000000
    };
    xnu_pf_maskmatch(patchset, "vnode_lookup", matches, masks, sizeof(masks)/sizeof(uint64_t), true, (void*)vnode_lookup_callback);
}

bool kpf_md0_callback(struct xnu_pf_patch *patch, uint32_t *opcode_stream)
{
    // Find: cmp wN, 0x64
    uint32_t *cmp = find_next_insn(opcode_stream, 10, 0x7101901f, 0xfffffc1f);
    if(!cmp)
    {
        return false;
    }
    // Change first cmp to short-circuit
    *opcode_stream = (*opcode_stream & 0xffc003ff) | (0x64 << 10);
    return true;
}

void kpf_md0_patches(xnu_pf_patchset_t* patchset) {
    // This patch turns all md0 checks in kexts into dd0 checks so that they don't think we're restoring.
    // For that we search for the sequence below (example from i7 13.3):
    // 0xfffffff00617fa98      1fb50171       cmp w8, 0x6d
    // 0xfffffff00617fa9c      21010054       b.ne 0xfffffff00617fac0
    // 0xfffffff00617faa0      e8274039       ldrb w8, [sp, 9]
    // 0xfffffff00617faa4      1f910171       cmp w8, 0x64
    // 0xfffffff00617faa8      c1000054       b.ne 0xfffffff00617fac0

    // We can only match the first "cmp" here, because there can be
    // a varying number of instructions between the two "cmp"s.
    uint64_t matches[] = {
        0x7101b41f, // cmp wN, 0x6d
    };
    uint64_t masks[] = {
        0xfffffc1f,
    };
    xnu_pf_maskmatch(patchset, "md0_patch", matches, masks, sizeof(matches)/sizeof(uint64_t), true, (void*)kpf_md0_callback);
}

struct kerninfo *legacy_info;
char is_oldstyle_rd;
int gkpf_flags;

int gkpf_didrun = 0;
int gkpf_spin_on_fail = 1;

void command_kpf() {

    if (gkpf_didrun)
        puts("checkra1n KPF did run already! Behavior here is undefined.\n");
    gkpf_didrun++;

    xnu_pf_patchset_t* xnu_text_exec_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_32BIT);
    found_vm_fault_enter = false;
    kpf_has_done_mac_mount = false;
    vnode_gaddr = NULL;
    vfs_context_current = NULL;
    shellcode_area = NULL;
    offsetof_p_flags = -1;

    struct mach_header_64* hdr = xnu_header();

    // extern struct mach_header_64* xnu_pf_get_kext_header(struct mach_header_64* kheader, const char* kext_bundle_id);

    xnu_pf_patchset_t* apfs_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_32BIT);
    struct mach_header_64* apfs_header = xnu_pf_get_kext_header(hdr, "com.apple.filesystems.apfs");
    xnu_pf_range_t* apfs_text_exec_range = xnu_pf_section(apfs_header, "__TEXT_EXEC", "__text");
    kpf_apfs_patches(apfs_patchset);
    xnu_pf_emit(apfs_patchset);
    xnu_pf_apply(apfs_text_exec_range, apfs_patchset);
    xnu_pf_patchset_destroy(apfs_patchset);

    xnu_pf_patchset_t* amfi_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_32BIT);
    struct mach_header_64* amfi_header = xnu_pf_get_kext_header(hdr, "com.apple.driver.AppleMobileFileIntegrity");
    xnu_pf_range_t* amfi_text_exec_range = xnu_pf_section(amfi_header, "__TEXT_EXEC", "__text");
    kpf_amfi_kext_patches(amfi_patchset);
    xnu_pf_emit(amfi_patchset);
    xnu_pf_apply(amfi_text_exec_range, amfi_patchset);
    xnu_pf_patchset_destroy(amfi_patchset);

    xnu_pf_patchset_t* sandbox_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_32BIT);
    struct mach_header_64* sandbox_header = xnu_pf_get_kext_header(hdr, "com.apple.security.sandbox");
    xnu_pf_range_t* sandbox_text_exec_range = xnu_pf_section(sandbox_header, "__TEXT_EXEC", "__text");
    kpf_sandbox_kext_patches(sandbox_patchset);
    xnu_pf_emit(sandbox_patchset);
    xnu_pf_apply(sandbox_text_exec_range, sandbox_patchset);
    xnu_pf_patchset_destroy(sandbox_patchset);

    // TODO
    //struct mach_header_64* accessory_header = xnu_pf_get_kext_header(hdr, "com.apple.iokit.IOAccessoryManager");

    xnu_pf_patchset_t* kext_text_exec_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_32BIT);
    kpf_md0_patches(kext_text_exec_patchset);
    xnu_pf_emit(kext_text_exec_patchset);
    xnu_pf_apply_each_kext(hdr, kext_text_exec_patchset);
    xnu_pf_patchset_destroy(kext_text_exec_patchset);


    xnu_pf_range_t* text_exec_range = xnu_pf_section(hdr, "__TEXT_EXEC", "__text");
    struct mach_header_64* first_kext = xnu_pf_get_first_kext(hdr);
    if (first_kext) {
        xnu_pf_range_t* first_kext_text_exec_range = xnu_pf_section(first_kext, "__TEXT_EXEC", "__text");

        if (first_kext_text_exec_range) {
            uint64_t text_exec_end_real;
            uint64_t text_exec_end = text_exec_end_real = ((uint64_t) (text_exec_range->va)) + text_exec_range->size;
            uint64_t first_kext_p = ((uint64_t) (first_kext_text_exec_range->va));

            if (text_exec_end > first_kext_p && first_kext_text_exec_range->va > text_exec_range->va) {
                text_exec_end = first_kext_p;
            }

            text_exec_range->size -= text_exec_end_real - text_exec_end;
        }
    }
    xnu_pf_range_t* text_cstring_range = xnu_pf_section(hdr, "__TEXT", "__cstring");
    xnu_pf_range_t* plk_text_range = xnu_pf_section(hdr, "__PRELINK_TEXT", "__text");
    xnu_pf_patchset_t* xnu_data_const_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_64BIT);
    xnu_pf_range_t* data_const_range = xnu_pf_section(hdr, "__DATA_CONST", "__const");
    xnu_pf_range_t* plk_data_const_range = xnu_pf_section(hdr, "__PLK_DATA_CONST", "__data");

    uint64_t tick_0 = get_ticks();
    uint64_t tick_1;

    has_found_sbops = false;
    xnu_pf_maskmatch(xnu_data_const_patchset, "mach_traps",traps_match, traps_mask, sizeof(traps_match)/sizeof(uint64_t), true, (void*)mach_traps_callback);
    xnu_pf_ptr_to_data(xnu_data_const_patchset, xnu_slide_value(hdr), text_cstring_range, "Seatbelt sandbox policy", strlen("Seatbelt sandbox policy")+1, false, (void*)sb_ops_callback);
    xnu_pf_emit(xnu_data_const_patchset);
    xnu_pf_apply(data_const_range, xnu_data_const_patchset);
    xnu_pf_patchset_destroy(xnu_data_const_patchset);
    bool is_unified = true;

    if (!has_found_sbops) {
        is_unified = false;
        if (!plk_text_range) panic("no plk_text_range");
        xnu_pf_patchset_t* xnu_plk_data_const_patchset = xnu_pf_patchset_create(XNU_PF_ACCESS_64BIT);
        xnu_pf_ptr_to_data(xnu_plk_data_const_patchset, xnu_slide_value(hdr), plk_text_range, "Seatbelt sandbox policy", strlen("Seatbelt sandbox policy")+1, true, (void*)sb_ops_callback);
        xnu_pf_emit(xnu_plk_data_const_patchset);
        xnu_pf_apply(plk_data_const_range, xnu_plk_data_const_patchset);
        xnu_pf_patchset_destroy(xnu_plk_data_const_patchset);
    }

    const char kmap_port_string_14[] = "\"userspace has control access to a \" \"kernel map %p through task %p\""; // iOS 14 had broken panic strings
    const char *kmap_port_string_14_match = memmem(text_cstring_range->cacheable_base, text_cstring_range->size, kmap_port_string_14, strlen(kmap_port_string_14));

    kpf_dyld_patch(xnu_text_exec_patchset);
    kpf_amfi_patch(xnu_text_exec_patchset);
    kpf_mac_mount_patch(xnu_text_exec_patchset);
    kpf_conversion_patch(xnu_text_exec_patchset);
    kpf_mac_dounmount_patch_0(xnu_text_exec_patchset);
    kpf_mac_vm_map_protect_patch(xnu_text_exec_patchset);
    kpf_mac_vm_fault_enter_patch(xnu_text_exec_patchset);
    kpf_nvram_unlock(xnu_text_exec_patchset);
    kpf_find_shellcode_area(xnu_text_exec_patchset);
    kpf_find_shellcode_funcs(xnu_text_exec_patchset);
    if(kmap_port_string_14_match) // iOS 14 only
    {
        kpf_convert_port_to_map_patch(xnu_text_exec_patchset);
    }

    xnu_pf_emit(xnu_text_exec_patchset);
    xnu_pf_apply(text_exec_range, xnu_text_exec_patchset);
    xnu_pf_patchset_destroy(xnu_text_exec_patchset);

    if (!found_amfi_mac_syscall) panic("no amfi_mac_syscall");
    if (!dounmount_found) panic("no dounmount");
    if (!repatch_ldr_x19_vnode_pathoff) panic("no repatch_ldr_x19_vnode_pathoff");
    if (!shellcode_area) panic("no shellcode area?");
    if (!has_found_sbops) panic("no sbops?");
    if (!amfi_ret) panic("no amfi_ret?");
    if (!vnode_lookup) panic("no vnode_lookup?");
    DEVLOG("Found vnode_lookup: 0x%llx", xnu_rebase_va(xnu_ptr_to_va(vnode_lookup)));
    if (!vnode_put) panic("no vnode_put?");
    DEVLOG("Found vnode_put: 0x%llx", xnu_rebase_va(xnu_ptr_to_va(vnode_put)));
    if (!dyld_hook_addr) panic("no dyld_hook_addr?");
    if (offsetof_p_flags == -1) panic("no p_flags?");
    if (!found_vm_fault_enter) panic("no vm_fault_enter");
    if (!vfs_context_current) panic("missing patch: vfs_context_current");

    uint32_t delta = (&shellcode_area[1]) - amfi_ret;
    delta &= 0x03ffffff;
    delta |= 0x14000000;
    *amfi_ret = delta;

    uint64_t sandbox_shellcode_p = xnu_ptr_to_va(shellcode_area);

    struct mac_policy_ops* ops = xnu_va_to_ptr(kext_rebase_va(sbops[3]));
    uint64_t ret_zero = ((ret0_gadget - xnu_slide_value(hdr)) & 0xFFFFFFFF);
    uint64_t open_shellcode = ((sandbox_shellcode_p - xnu_slide_value(hdr)) & 0xFFFFFFFF);

#define PATCH_OP(ops, op, val)         \
    if (ops->op) {                     \
        ops->op &= 0xFFFFFFFF00000000; \
        ops->op |= val;                \
    }

    PATCH_OP(ops, mpo_mount_check_mount, ret_zero);
    PATCH_OP(ops, mpo_mount_check_remount, ret_zero);
    PATCH_OP(ops, mpo_mount_check_umount, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_write, ret_zero);
    PATCH_OP(ops, mpo_file_check_mmap, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_rename, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_access, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_chroot, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_create, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_deleteextattr, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_exchangedata, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_exec, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_getattrlist, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_getextattr, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_ioctl, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_link, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_listextattr, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_open, open_shellcode);
    PATCH_OP(ops, mpo_vnode_check_readlink, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_setattrlist, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_setextattr, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_setflags, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_setmode, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_setowner, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_setutimes, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_stat, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_truncate, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_unlink, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_fsgetpath, ret_zero);
    PATCH_OP(ops, mpo_vnode_check_getattr, ret_zero);
    PATCH_OP(ops, mpo_mount_check_stat, ret_zero);
    PATCH_OP(ops, mpo_proc_check_get_cs_info, ret_zero);
    PATCH_OP(ops, mpo_proc_check_set_cs_info, ret_zero);
    uint64_t update_execve = ops->mpo_cred_label_update_execve;
    PATCH_OP(ops, mpo_cred_label_update_execve, open_shellcode+8);

    update_execve = kext_rebase_va(update_execve);

    extern uint32_t sandbox_shellcode, sandbox_shellcode_end, sandbox_shellcode_setuid_patch, sandbox_shellcode_ptrs, dyld_hook_shellcode;
    uint32_t* shellcode_from = &sandbox_shellcode;
    uint32_t* shellcode_end = &sandbox_shellcode_end;
    uint32_t* shellcode_to = shellcode_area;
    // Identify where the LDR/STR insns that will need to be patched will be
    uint32_t* repatch_sandbox_shellcode_setuid_patch = &sandbox_shellcode_setuid_patch - shellcode_from + shellcode_to;
    uint64_t* repatch_sandbox_shellcode_ptrs = (uint64_t*)(&sandbox_shellcode_ptrs - shellcode_from + shellcode_to);
    dyld_hook = &dyld_hook_shellcode - shellcode_from + shellcode_to;

    while(shellcode_from < shellcode_end)
    {
        *shellcode_to++ = *shellcode_from++;
    }
    if (repatch_sandbox_shellcode_ptrs[0] != 0x4141413341414132) {
        panic("Shellcode corruption");
    }
    // Patch offset into LDR and STR p->p_flags
    repatch_sandbox_shellcode_setuid_patch[0] |= ((offsetof_p_flags>>2)&0x1ff)<<10;
    repatch_sandbox_shellcode_setuid_patch[2] |= ((offsetof_p_flags>>2)&0x1ff)<<10;

    // Patch shellcode pointers
    repatch_sandbox_shellcode_ptrs[0] = update_execve;
    repatch_sandbox_shellcode_ptrs[1] = xnu_ptr_to_va(vnode_gaddr);
    repatch_sandbox_shellcode_ptrs[2] = xnu_ptr_to_va(vfs_context_current);
    repatch_sandbox_shellcode_ptrs[3] = xnu_ptr_to_va(vnode_lookup);
    repatch_sandbox_shellcode_ptrs[4] = xnu_ptr_to_va(vnode_put);

    uint32_t* repatch_vnode_shellcode = &shellcode_area[4];
    *repatch_vnode_shellcode = repatch_ldr_x19_vnode_pathoff;

    delta = (dyld_hook) - dyld_hook_addr;
    delta &= 0x03ffffff;
    delta |= 0x94000000;
    *dyld_hook_addr = delta;
    DEVLOG("dyld_hook_addr: 0x%llx -> 0x%llx base 0x%llx", xnu_ptr_to_va(dyld_hook_addr), xnu_ptr_to_va(dyld_hook), xnu_ptr_to_va(shellcode_to));

    if(nvram_patchpoint)
    {
        uint64_t nvram_patch_from = xnu_ptr_to_va(nvram_patchpoint);
        uint64_t nvram_patch_to = xnu_ptr_to_va(shellcode_to);
        int64_t nvram_off = nvram_patch_to - nvram_patch_from;
        if(nvram_off > 0x7fffffcLL || nvram_off < -0x8000000LL)
        {
            panic("nvram_unlock jump too far: 0x%llx", nvram_off);
        }
        extern uint32_t nvram_shc[], nvram_shc_end[];
        shellcode_from = nvram_shc;
        shellcode_end = nvram_shc_end;
        while(shellcode_from < shellcode_end)
        {
            *shellcode_to++ = *shellcode_from++;
        }
        nvram_patchpoint[0] = 0x14000000 | (((uint64_t)nvram_off >> 2) & 0x3ffffff);
    }
#if !DEV_BUILD
    // Treat this patch as optional in release
    else if(!nvram_inline_patch)
    {
        panic("Missing patch: nvram_unlock");
    }
#endif

    if (!kpf_has_done_mac_mount) {
        panic("Missing patch: mac_mount");
    }

    char *snapshotString = (char*)memmem((unsigned char *)text_cstring_range->cacheable_base, text_cstring_range->size, (uint8_t *)"com.apple.os.update-", strlen("com.apple.os.update-"));
    if (!snapshotString) snapshotString = (char*)memmem((unsigned char *)plk_text_range->cacheable_base, plk_text_range->size, (uint8_t *)"com.apple.os.update-", strlen("com.apple.os.update-"));
    if (!snapshotString) panic("no snapshot string");

    *snapshotString = 'x';
    puts("KPF: Disabled snapshot temporarily");

    if (!is_oldstyle_rd && ramdisk_buf) {
        puts("KPF: Found ramdisk, appending kernelinfo");

        ramdisk_buf = realloc(ramdisk_buf, ramdisk_size + 0x10000);

        *(uint32_t*)(ramdisk_buf) = ramdisk_size;

        struct kerninfo *info = (struct kerninfo*)(ramdisk_buf+ramdisk_size);
        bzero(info, sizeof(struct kerninfo));
        info->size = sizeof(struct kerninfo);
        info->base = xnu_slide_value(hdr) + 0xFFFFFFF007004000ULL;
        info->slide = xnu_slide_value(hdr);
        info->flags = gkpf_flags;

        ramdisk_size += 0x10000;
    } else if (is_oldstyle_rd) {
        legacy_info->base = xnu_slide_value(hdr) + 0xFFFFFFF007004000ULL;
        legacy_info->slide = xnu_slide_value(hdr);
        if (checkrain_option_enabled(legacy_info->flags, checkrain_option_verbose_boot))
            gBootArgs->Video.v_display = 0;
    }
    tick_1 = get_ticks();
    printf("KPF: Applied patchset in %llu ms\n", (tick_1 - tick_0) / TICKS_IN_1MS);
}
void kpf_flags(const char* cmd, char* args) {
    uint32_t nflags = 0;
    if (args[0] != 0) {
        nflags = strtoul(args, NULL, 16);
        printf("setting kpf_flags to %x\n", nflags);
        gkpf_flags = nflags;
    } else {
        printf("kpf_flags: %x\n", gkpf_flags);
    }
}
void kpf_do_autoboot() {
    queue_rx_string("bootx\n");
}
void kpf_autoboot() {
    DEVLOG("XNU slide: 0x%llx", xnu_slide_value(xnu_header()));

    char lol[9];
    strcpy(lol, "EDSKRDSK");
    lol[0] = 'R';
    char* ramdisk = memmem(loader_xfer_recv_data, autoboot_count, lol, 8);
    if (ramdisk) {
        printf("Found old-style rdsk!\n");
        uint32_t rdsksz = *(uint32_t*)(ramdisk + 8);
        if (rdsksz > autoboot_count) {
            printf("corrupted oldstyle rdsk\n");
            return;
        }
        ramdisk_buf = malloc(rdsksz + 0x10000);
        memcpy(ramdisk_buf, ramdisk + 12, rdsksz + 0x10000);

        ramdisk_size = rdsksz + 0x10000;

        char should_populate_kerninfo = 0;
        struct kerninfo *info = (struct kerninfo*)(ramdisk_buf+rdsksz);
        if (info->size == sizeof(struct kerninfo)) {
            should_populate_kerninfo = 1;
        } else {
            printf("Detected corrupted kerninfo!\n");
            return;
        }
        queue_rx_string("xargs ");
        queue_rx_string(info->bootargs);
        is_oldstyle_rd = 1;
        legacy_info = info;
        if (checkrain_option_enabled(legacy_info->flags, checkrain_option_pongo_shell))
        {
            printf("Pongo shell requested, stopping here!\n");
            queue_rx_string("\n");
            return;
        }
    } else
        queue_rx_string("xargs serial=3");

    queue_rx_string("\nsep auto\n");
    command_register("shell", "kickstarts auto-boot", kpf_do_autoboot);
}

void module_entry() {
    puts("");
    puts("");
    puts("#==================");
    puts("#");
    puts("# checkra1n kpf " CHECKRAIN_VERSION);
    puts("#");
    puts("# Proudly written in nano");
    puts("# (c) 2019-2021 Kim Jong Cracks");
    puts("#");
    puts("# This software is not for sale");
    puts("# If you purchased this, please");
    puts("# report the seller.");
    puts("#");
    puts("# Get it for free at https://checkra.in");
    puts("#");
    puts("#====  Made by  ===");
    puts("# argp, axi0mx, danyl931, jaywalker, kirb, littlelailo, nitoTV");
    puts("# never_released, nullpixel, pimskeks, qwertyoruiop, sbingner, siguza");
    puts("#==== Thanks to ===");
    puts("# haifisch, jndok, jonseals, xerub, lilstevie, psychotea, sferrini");
    puts("# Cellebrite (ih8sn0w, cjori, ronyrus et al.)");
    puts("#==================");

    preboot_hook = command_kpf;
    command_register("kpf_flags", "set flags for kernel patchfinder", kpf_flags);
    command_register("autoboot", "checkra1n-kpf autoboot hook", kpf_autoboot);
    command_register("kpf", "running checkra1n-kpf without booting (use bootux afterwards)", command_kpf);
}
char* module_name = "checkra1n-kpf2-12.0,14.5";

struct pongo_exports exported_symbols[] = {
    {.name = 0, .value = 0}
};
