#include "kernel_patchfinder.h"
#include "titan.h"
#include "info.h"
#include "arm64.h"

#include <libjailbreak/libjailbreak.h>

#include <mach-o/loader.h>

static struct s_PatchFinderContext {
    struct mach_header_64 *header;
    void *load_commands;
} gPatchfinderContext = { 0 };

int kpf_init(void) {
    gPatchfinderContext.header = malloc(sizeof(struct mach_header_64));
    if (gPatchfinderContext.header == NULL) {
        printf("ERROR: failed to allocate memory for Mach-O header\n");
        return -1;
    }

    kreadbuf(kconstant(base), gPatchfinderContext.header, sizeof(struct mach_header_64));
    
    gPatchfinderContext.load_commands = malloc(gPatchfinderContext.header->sizeofcmds);
    if (gPatchfinderContext.load_commands == NULL) {
        printf("ERROR: failed to allocate memory for Mach-O load commands\n");
        free(gPatchfinderContext.header);
        gPatchfinderContext.header = NULL;
        return -1;
    }

    kreadbuf(kconstant(base) + sizeof(struct mach_header_64), gPatchfinderContext.load_commands, gPatchfinderContext.header->sizeofcmds);

    return 0;
}

int kpf_find_fileset_partial(const char *name, size_t name_len, uint64_t *baseOut) {
    struct mach_header_64 *header = gPatchfinderContext.header;
    struct load_command *cmd = (struct load_command *)gPatchfinderContext.load_commands;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_FILESET_ENTRY) {
            struct fileset_entry_command *fsc = (struct fileset_entry_command *)cmd;
            uint32_t name_off = fsc->entry_id.offset;
            uint32_t size = fsc->cmdsize;
            if (name_off >= 0x20 && size > name_off) {
                const char *name_va = (const char *)((uintptr_t)fsc + name_off);
                if (strncmp(name_va, name, (size - name_off) <= name_len ? (size - name_off) : name_len) == 0) {
                    *baseOut = fsc->vmaddr;
                    return 0;
                }
            }
        }
        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }

    return -1;
}

int kpf_find_fileset(const char *name, uint64_t *baseOut) {
    return kpf_find_fileset_partial(name, strlen(name), baseOut);
}

fileset_entry_t *kpf_fileset_entry_init(uint64_t va, const char *name) {
    fileset_entry_t *entry = malloc(sizeof(fileset_entry_t));
    if (entry == NULL) {
        printf("ERROR: failed to allocate memory for fileset entry\n");
        return NULL;
    }
    entry->base = va;
    entry->name = name;

    struct mach_header_64 header;
    kreadbuf(va, &header, sizeof(struct mach_header_64));

    struct load_command *cmd = malloc(header.sizeofcmds);
    if (cmd == NULL) {
        printf("ERROR: failed to allocate memory for Mach-O load commands\n");
        free(entry);
        return NULL;
    }

    kreadbuf(va + sizeof(struct mach_header_64), cmd, header.sizeofcmds);
    void *cmds = cmd;

    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            // printf("Found segment %s spanning 0x%llX -> 0x%llX\n", seg->segname, seg->vmaddr - titan_kconstant(slide), seg->vmaddr + seg->vmsize - titan_kconstant(slide));
            if (strcmp(seg->segname, "__TEXT_EXEC") == 0) {
                entry->text_exec = seg->vmaddr;
                entry->text_exec_size = seg->vmsize;
            } else if (strcmp(seg->segname, "__DATA") == 0) {
                entry->data = seg->vmaddr;
                entry->data_size = seg->vmsize;
            }
        }
        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }

    free(cmds);

    return entry;
}

void kpf_fileset_entry_deinit(fileset_entry_t *entry) {
    free(entry);
}

uint64_t kpf_fileset_entry_patchfind_text(fileset_entry_t *entry, uint32_t insns[], uint32_t masks[], int insn_count) {
    uint64_t va = entry->text_exec;

    while (va < entry->text_exec + entry->text_exec_size) {
        bool found = true;
        for (int i = 0; i < insn_count; i++) {
            uint32_t insn = kread32(va + (i * 4));
            if ((insn & masks[i]) != (insns[i] & masks[i])) {
                found = false;
                break;
            }
        }
        if (found) {
            return va;
        }
        va += 4;
    }
    return 0;
}

uint64_t kpf_fileset_entry_patchfind_data(fileset_entry_t *entry, uint8_t data[], uint8_t masks[], size_t data_len) {
    uint64_t va = entry->data;

    while (va < entry->data + entry->data_size) {
        bool found = true;
        for (size_t i = 0; i < data_len; i++) {
            uint8_t byte = kread8(va + i);
            if ((byte & masks[i]) != (data[i] & masks[i])) {
                found = false;
                break;
            }
        }
        if (found) {
            return va;
        }
        va += 1;
    }
    return 0;
}

void kpf_deinit(void) {
    if (gPatchfinderContext.header) {
        free(gPatchfinderContext.header);
        gPatchfinderContext.header = NULL;
    }
    if (gPatchfinderContext.load_commands) {
        free(gPatchfinderContext.load_commands);
        gPatchfinderContext.load_commands = NULL;
    }
}

// IOGPUDeviceUserClient::s_delete_command_queue -> IOGPUDeviceUserClient.IOGPUDevice
static int kpf_find_delete_command_queue(fileset_entry_t *iogpu) {
    uint32_t insns[4] = {
        0xF9401048,
        0xB9400100,
        0xF9400008, // LDR Xt, [Xn, #offset]
        0xF9400000,
    };
    uint32_t masks[4] = {
        0xFFFFFFFF,
        0xFFFFFFE0,
        0xFFC0001F,
        0xFFC0001F,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(iogpu, insns, masks, 4);
    if (!hit) {
        printf("ERROR: failed to find IOGPUDeviceUserClient::s_delete_command_queue()\n");
        return -1;
    }
    titan_koffsetof(IOGPUDeviceUserClient, IOGPUDevice) = arm64_decode_ldr_str_off(kread32(hit + 8));
    return 0;
}

// IOGPUMemoryMap::freeGPUVirtualAddress -> IOGPUMemoryMap.GPUVirtualAddress
static int kpf_find_free_gpu_va(fileset_entry_t *iogpu) {
    uint32_t insns[1] = {
        0xF2F5F020, // MOVK Xt, #0xAF81, LSL #48
    };
    uint32_t masks[1] = {
        0xFFFFFFE0,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(iogpu, insns, masks, 1);
    if (!hit) {
        printf("ERROR: failed to find IOGPUMemoryMap::freeGPUVirtualAddress()\n");
        return -1;
    }
    for (int i = 0; i < 10; i++) {
        uint32_t insn = kread32(hit + (i * 4));
        if ((insn & 0xFFC0001F) == 0xF900001F) { // STR Xt, [Xn, #offset]
            titan_koffsetof(IOGPUMemoryMap, GPUVirtualAddress) = arm64_decode_ldr_str_off(insn);
            break;
        }
    }
    if (!titan_koffsetof(IOGPUMemoryMap, GPUVirtualAddress)) {
        printf("ERROR: failed to find IOGPUMemoryMap->GPUVirtualAddress offset\n");
        return -1;
    }
    return 0;
}

// AGXCommandQueue::processKernelCommand -> IOGPUDevice.MDSID_map / IOGPUDevice.IOGPU / IOGPU.dsids_supported
static int kpf_find_process_kernel_command(fileset_entry_t *agxg) {
    uint32_t insns[5] = {
        0xF9400000, // LDR
        0xB4000000, // CBZ
        0xF9400000, // LDR
        0xB9400000, // LDR
        0x34000000, // CBZ
    };
    uint32_t masks[5] = {
        0xFFC00000,
        0xFF000000,
        0xFFC00000,
        0xFFC00000,
        0xFF000000,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(agxg, insns, masks, 5);
    if (!hit) {
        printf("ERROR: failed to find AGXCommandQueue::processKernelCommand()\n");
        return -1;
    }
    titan_koffsetof(IOGPUDevice, MDSID_map) = arm64_decode_ldr_str_off(kread32(hit));
    titan_koffsetof(IOGPUDevice, IOGPU) = arm64_decode_ldr_str_off(kread32(hit + 8));
    titan_koffsetof(IOGPU, dsids_supported) = arm64_decode_ldr_str_off(kread32(hit + 12));
    return 0;
}

// AGXCommandQueue::processKernelCommand fence sequence -> IOGPU.fence_value / IOGPU.IOGPUMemoryMap / IOGPU.buffer_offset
static int kpf_find_fence_offsets(fileset_entry_t *agxg) {
    uint32_t insns[6] = {
        0x52800008,
        0xB8686809,
        0x11040129,
        0xB8286809,
        0x52800008,
        0x8B000000,
    };
    uint32_t masks[6] = {
        0xFFE0001F,
        0xFFFFFC1F,
        0xFFFFFFFF,
        0xFFFFFC1F,
        0xFFE0001F,
        0xFFE0FC00,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(agxg, insns, masks, 6);
    if (!hit) {
        printf("ERROR: failed to find AGXCommandQueue::processKernelCommand() fence sequence\n");
        return -1;
    }
    titan_koffsetof(IOGPU, fence_value) = (kread32(hit) >> 5) & 0xFFFF;

    uint32_t idx = 1;
    bool found_mov_already = false;
    while (idx < 50) {
        uint32_t cur_insn = kread32(hit + (idx++ * 4));
        if ((cur_insn & 0xFFE0001F) == 0x52800008) {
            if (found_mov_already) {
                titan_koffsetof(IOGPU, IOGPUMemoryMap) = ((cur_insn >> 5) & 0xFFFF);
                break;
            }
            found_mov_already = true;
        }
    }
    if (!titan_koffsetof(IOGPU, IOGPUMemoryMap)) {
        printf("ERROR: failed to find IOGPU->IOGPUMemoryMap offset\n");
        return -1;
    }

    while (idx < 50) {
        uint32_t cur_insn = kread32(hit + (idx++ * 4));
        if (cur_insn == 0xF2E63531) {
            uint32_t target_ldr = kread32(hit + ((idx - 1) * 4) + 8);
            titan_koffsetof(IOGPU, buffer_offset) = arm64_decode_ldr_str_off(target_ldr);
            break;
        }
    }
    if (!titan_koffsetof(IOGPU, buffer_offset)) {
        printf("ERROR: failed to find offset (unknown3)\n");
        return -1;
    }
    return 0;
}

// IOGPUDevice::create_shmem -> IOGPUDevice.IOGPUNamespace
static int kpf_find_create_shmem(fileset_entry_t *iogpu) {
    uint32_t insns[7] = {
        0xF900001F,
        0xB900001F,
        0xB900001F,
        0x00000000,
        0x00000000,
        0x00000000,
        0x14000000,
    };
    uint32_t masks[7] = {
        0xFFFFFC1F,
        0xFFFFFC1F,
        0xFFFFFC1F,
        0x00000000,
        0x00000000,
        0x00000000,
        0xFC000000,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(iogpu, insns, masks, 7);
    if (!hit) {
        printf("ERROR: failed to find IOGPUDevice::create_shmem()\n");
        return -1;
    }
    // Find branch to IOGPUNamespace::addObject(IOGPUObject *) then the LDR for the namespace
    uint32_t idx = 0;
    while (idx < 30) {
        uint32_t insn = kread32(hit + (idx++ * 4));
        if ((insn >> 26) == 37) {
            uint32_t namespace_ldr = kread32(hit + (idx * 4) - 12);
            titan_koffsetof(IOGPUDevice, IOGPUNamespace) = arm64_decode_ldr_str_off(namespace_ldr);
            break;
        }
    }
    if (!titan_koffsetof(IOGPUDevice, IOGPUNamespace)) {
        printf("ERROR: failed to find IOGPUDevice->IOGPUNamespace offset\n");
        return -1;
    }
    return 0;
}

// IOGPUWeakNamespace::alloc_handles -> IOGPUWeakNamespace.handles
static int kpf_find_alloc_handles(fileset_entry_t *iogpu) {
    uint32_t insns[5] = {
        0xF9000000,
        0xB4000000,
        0x00000000,
        0x94000000,
        0xF9000000,
    };
    uint32_t masks[5] = {
        0xFFC0001F,
        0xFF00001F,
        0x00000000,
        0xFC000000,
        0xFFC0001F,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(iogpu, insns, masks, 5);
    if (!hit) {
        printf("ERROR: failed to find IOGPUWeakNamespace::alloc_handles()\n");
        return -1;
    }
    titan_koffsetof(IOGPUWeakNamespace, handles) = arm64_decode_ldr_str_off(kread32(hit));
    return 0;
}

// IOGPUKernelMappedMemory::getKernelData -> IOGPUDeviceShmem.map
static int kpf_find_get_kernel_data(fileset_entry_t *iogpu) {
    uint32_t insns[2] = {
        0x11000000,
        0x29000000,
    };
    uint32_t masks[2] = {
        0xFFC00000,
        0xFFC00000,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(iogpu, insns, masks, 2);
    if (!hit) {
        printf("ERROR: failed to find IOGPUKernelMappedMemory::getKernelData()\n");
        return -1;
    }
    titan_koffsetof(IOGPUDeviceShmem, map) = arm64_decode_ldr_str_off(kread32(hit + 12));
    return 0;
}

// IOMemoryMap::wireRange -> IOMemoryMap.fAddress
static int kpf_find_wire_range(fileset_entry_t *kernel) {
    uint32_t insns[2] = {
        0xF9400008,
        0x8B020108,
    };
    uint32_t masks[2] = {
        0xFFC003FF,
        0xFFFFFFFF,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(kernel, insns, masks, 2);
    if (!hit) {
        printf("ERROR: failed to find IOMemoryMap::wireRange()\n");
        return -1;
    }
    titan_koffsetof(IOMemoryMap, fAddress) = arm64_decode_ldr_str_off(kread32(hit));
    return 0;
}

// AGXDeviceUserClient vtable -> gTitanContext.IOGPUDeviceUserClient_vtable
static int kpf_find_userclient_vtable(fileset_entry_t *agxg) {
    /*
     MOVK X17, #0xCDA1,LSL#48
     PACDA X16, X17
     STR X16, [X0]
     STRB WZR, [X0,#0x130]
    */
    uint32_t insns[4] = {
        0xF2F9B431,
        0xDAC10A30,
        0xF9000010,
        0x3904C01F,
    };
    uint32_t masks[4] = {
        0xFFFFFFFF,
        0xFFFFFFFF,
        0xFFFFFFFF,
        0xFFFFFFFF,
    };
    uint64_t hit = kpf_fileset_entry_patchfind_text(agxg, insns, masks, 4);
    if (!hit) {
        printf("ERROR: failed to find AGXDeviceUserClient vtable reference\n");
        return -1;
    }
    uint32_t idx = 0;
    while (idx < 30) {
        uint32_t cur_insn = kread32(hit - (idx++ * 4));
        if ((cur_insn & 0x1F000000) == 0x10000000) { // ADRP+ADD of AGXDeviceUserClient vtable
            uint64_t adrp_add_addr = (hit - ((idx - 1) * 4));
            gTitanContext.IOGPUDeviceUserClient_vtable = arm64_decode_adrp_add(adrp_add_addr, kread32(adrp_add_addr), kread32(adrp_add_addr + 4));
            break;
        }
    }
    if (!gTitanContext.IOGPUDeviceUserClient_vtable) {
        printf("ERROR: failed to find IOGPUDeviceUserClient vtable\n");
        return -1;
    }
    return 0;
}

int kpf_run(void) {
    int ret = -1;
    fileset_entry_t *iogpu_entry = NULL, *agxg_entry = NULL, *kernel_entry = NULL;

    if (kpf_init() != 0) {
        return -1;
    }

    uint64_t iogpu_base = 0, agxg_base = 0, kernel_base = 0;
    if (kpf_find_fileset("com.apple.iokit.IOGPUFamily", &iogpu_base) != 0) {
        printf("ERROR: failed to find com.apple.iokit.IOGPUFamily fileset\n");
        goto fail;
    }
    if (kpf_find_fileset_partial("com.apple.AGXG", strlen("com.apple.AGXG"), &agxg_base) != 0) {
        printf("ERROR: failed to find com.apple.AGXG fileset\n");
        goto fail;
    }
    if (kpf_find_fileset("com.apple.kernel", &kernel_base) != 0) {
        printf("ERROR: failed to find com.apple.kernel fileset\n");
        goto fail;
    }

    iogpu_entry = kpf_fileset_entry_init(iogpu_base, "com.apple.iokit.IOGPUFamily");
    agxg_entry = kpf_fileset_entry_init(agxg_base, "com.apple.AGXG");
    kernel_entry = kpf_fileset_entry_init(kernel_base, "com.apple.kernel");
    if (iogpu_entry == NULL || agxg_entry == NULL || kernel_entry == NULL) {
        printf("ERROR: failed to initialise fileset entries\n");
        goto fail;
    }

    if (kpf_find_delete_command_queue(iogpu_entry) != 0) goto fail;
    if (kpf_find_free_gpu_va(iogpu_entry) != 0) goto fail;
    if (kpf_find_process_kernel_command(agxg_entry) != 0) goto fail;
    if (kpf_find_fence_offsets(agxg_entry) != 0) goto fail;
    if (kpf_find_create_shmem(iogpu_entry) != 0) goto fail;
    if (kpf_find_alloc_handles(iogpu_entry) != 0) goto fail;
    if (kpf_find_get_kernel_data(iogpu_entry) != 0) goto fail;
    if (kpf_find_wire_range(kernel_entry) != 0) goto fail;
    if (kpf_find_userclient_vtable(agxg_entry) != 0) goto fail;

    printf("KPF results:\n");
    printf("IOGPUDeviceUserClient->IOGPUDevice offset: 0x%llX\n", titan_koffsetof(IOGPUDeviceUserClient, IOGPUDevice));
    printf("IOGPUMemoryMap->GPUVirtualAddress offset: 0x%llX\n", titan_koffsetof(IOGPUMemoryMap, GPUVirtualAddress));
    printf("IOGPUDevice->MDSID_map offset: 0x%llX\n", titan_koffsetof(IOGPUDevice, MDSID_map));
    printf("IOGPUDevice->IOGPU offset: 0x%llX\n", titan_koffsetof(IOGPUDevice, IOGPU));
    printf("IOGPU->dsids_supported offset: 0x%llX\n", titan_koffsetof(IOGPU, dsids_supported));
    printf("IOGPU->fence_value offset: 0x%llX\n", titan_koffsetof(IOGPU, fence_value));
    printf("IOGPU->IOGPUMemoryMap offset: 0x%llX\n", titan_koffsetof(IOGPU, IOGPUMemoryMap));
    printf("IOGPU->buffer_offset offset: 0x%llX\n", titan_koffsetof(IOGPU, buffer_offset));
    printf("IOGPUDevice->IOGPUNamespace offset: 0x%llX\n", titan_koffsetof(IOGPUDevice, IOGPUNamespace));
    printf("IOGPUWeakNamespace->handles offset: 0x%llX\n", titan_koffsetof(IOGPUWeakNamespace, handles));

    ret = 0;

fail:
    if (iogpu_entry) kpf_fileset_entry_deinit(iogpu_entry);
    if (agxg_entry) kpf_fileset_entry_deinit(agxg_entry);
    if (kernel_entry) kpf_fileset_entry_deinit(kernel_entry);
    kpf_deinit();
    return ret;
}
