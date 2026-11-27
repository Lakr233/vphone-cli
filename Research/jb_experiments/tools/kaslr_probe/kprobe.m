// kprobe: пробник утечки указателей ядра через неинициализированные поля структур Mach/proc_info API.
// Вывод: stdout и tmp/out.txt. Запуск на устройстве:
//   devicectl device process launch --console <device> me.strelov.kprobe
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor.h>
#include <mach/processor_info.h>
#include <mach/vm_region.h>
// mach_vm.h в iOS SDK не поддерживается — объявляем вручную.
kern_return_t mach_vm_region_recurse(vm_map_t target_task, mach_vm_address_t *address,
                                                mach_vm_size_t *size, natural_t *depth,
                                                vm_region_recurse_info_t info, mach_msg_type_number_t *infoCnt);
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *g_out;
#define LOG(...) do { printf(__VA_ARGS__); fprintf(g_out, __VA_ARGS__); fflush(stdout); fflush(g_out); } while (0)

// Диапазоны kernel-указателей по методике: A15 (0xfffffff0...) и A19 (0xfffffe00...).
static const uint64_t KMIN_A15 = 0xfffffff000000000ULL, KMAX_A15 = 0xfffffff0ffffffffULL;
static const uint64_t KMIN_A19 = 0xfffffe0000000000ULL, KMAX_A19 = 0xfffffe00ffffffffULL;
static int inRange(uint64_t v) { return (v >= KMIN_A15 && v <= KMAX_A15) || (v >= KMIN_A19 && v <= KMAX_A19); }

static size_t g_hits = 0, g_varying = 0;

static kern_return_t f_host_cpu(void *buf, mach_msg_type_number_t *c, int flavor)
{
    natural_t ncpu = 0;
    return host_processor_info(mach_host_self(), flavor, &ncpu, (processor_info_array_t *)buf, c);
}
static void free_probe(void)
{
    for (int fl = 1; fl <= 20; fl++) {
        processor_info_array_t a = NULL, b = NULL; mach_msg_type_number_t ca = 0, cb = 0; natural_t na = 0;
        kern_return_t ra = f_host_cpu(&a, &ca, fl), rb = f_host_cpu(&b, &cb, fl);
        size_t n = (size_t)(ca < cb ? ca : cb) / 2;
        if (ra == KERN_SUCCESS) for (size_t i = 0; i < n; i++) {
            uint64_t va = ((uint64_t *)a)[i], vb = ((uint64_t *)b)[i];
            if (inRange(va) || inRange(vb)) {
                int vary = va != vb; g_hits++; g_varying += vary;
                LOG("HIT host_processor_info flavor=%d off=+%zu value=0x%016llx other=0x%016llx vary=%d\n", fl, i * 8, (unsigned long long)va, (unsigned long long)vb, vary);
            }
        }
        LOG("host_processor_info flavor=%d rc=%d size=%u ncpu=%u\n", fl, ra, ca * 4, na);
        if (ra == KERN_SUCCESS) vm_deallocate(mach_task_self(), (vm_address_t)a, ca * 4);
        if (rb == KERN_SUCCESS) vm_deallocate(mach_task_self(), (vm_address_t)b, cb * 4);
    }
}

// Двухпроходный метод: один и тот же вызов в два буфера, заполненных 0xAA; печатаем rc, размер
// и все 8-байтовые слова, попадающие в kernel-диапазон (с признаком vary, если они отличаются).
typedef kern_return_t (*fill_fn)(void *buf, mach_msg_type_number_t *count, int flavor);

static void probe(const char *api, int flavor, size_t cap, fill_fn fn)
{
    uint64_t *a = malloc(cap), *b = malloc(cap);
    memset(a, 0xAA, cap); memset(b, 0xAA, cap);
    mach_msg_type_number_t ca = (mach_msg_type_number_t)(cap / 4), cb = ca;
    kern_return_t ra = fn(a, &ca, flavor), rb = fn(b, &cb, flavor);
    size_t sa = (size_t)ca * 4, n = cap / 8;
    for (size_t i = 0; i < n; i++) {
        if (inRange(a[i]) || inRange(b[i])) {
            int vary = (a[i] != b[i]);
            g_hits++;
            if (vary) g_varying++;
            LOG("HIT %s flavor=%d rc=%d/%d size=%zu off=+%zu value=0x%016llx other=0x%016llx vary=%d\n",
                api, flavor, ra, rb, sa, i * 8, (unsigned long long)a[i], (unsigned long long)b[i], vary);
        }
    }
    LOG("%s flavor=%d rc=%d size=%zu words=%zu\n", api, flavor, ra, sa, n);
    if (ra == KERN_SUCCESS && sa) {
        size_t dumpn = sa + 64; if (dumpn > cap) dumpn = cap;
        LOG("DUMP %s flavor=%d bytes=%zu:", api, flavor, dumpn);
        const unsigned char *p = (const unsigned char *)a;
        for (size_t i = 0; i < dumpn; i++) LOG("%02x", p[i]);
        LOG("\n");
    }
    free(a); free(b);
}

static kern_return_t f_host_info(void *buf, mach_msg_type_number_t *c, int flavor) { return host_info(mach_host_self(), flavor, (host_info_t)buf, c); }
static kern_return_t f_host_stats(void *buf, mach_msg_type_number_t *c, int flavor) { return host_statistics(mach_host_self(), flavor, (host_info_t)buf, c); }
static kern_return_t f_host_stats64(void *buf, mach_msg_type_number_t *c, int flavor) { return host_statistics64(mach_host_self(), flavor, (host_info64_t)buf, c); }
static kern_return_t f_task_info(void *buf, mach_msg_type_number_t *c, int flavor) { return task_info(mach_task_self(), flavor, (task_info_t)buf, c); }
// int proc_info(int32_t callnum, int32_t flavor, uint64_t arg, uint32_t pid, void *buffer, int32_t buffersize)
// callnum: 2 = PROC_INFO_CALL_PIDINFO, 3 = PROC_INFO_CALL_PIDEXTINFO, 4 = PROC_INFO_CALL_KERNMSGBUFS
static kern_return_t f_proc_info(void *buf, mach_msg_type_number_t *c, int flavor)
{
    // callnum 2/3: flavor=1 фиксированный (перебор flavors отдельно через f_proc_info_flavors), для callnum 4 flavor игнорируется, arg = buffer index (0)
    int callnum = flavor;   // сюда передаём callnum как "flavor"
    long rc = syscall(SYS_proc_info, callnum, /*flavor*/1, /*arg*/0, (uint32_t)getpid(), buf, (int32_t)*c * 4);
    if (rc < 0) { int e = errno; LOG("proc_info callnum=%d errno=%d (%s)\n", callnum, e, strerror(e)); return (kern_return_t)-1; }
    *c = (mach_msg_type_number_t)rc;
    return KERN_SUCCESS;
}
static kern_return_t f_processor_info(void *buf, mach_msg_type_number_t *c, int flavor)
{
    host_t host = HOST_NULL;
    return processor_info(PROCESSOR_NULL, flavor, &host, (processor_info_t)buf, c);
}
static kern_return_t f_proc_info_flavors(void *buf, mach_msg_type_number_t *c, int flavor)
{
    long rc = syscall(SYS_proc_info, 2 /*PROC_INFO_CALL_PIDINFO*/, flavor, 0, (uint32_t)getpid(), buf, (int32_t)*c * 4);
    if (rc < 0) return (kern_return_t)-1;
    *c = (mach_msg_type_number_t)rc;
    return KERN_SUCCESS;
}

// mach_port_kernel_object: имя и адрес kernel-объекта, стоящего за портом.
static void probe_kobj(void)
{
    mach_port_t ports[3] = { mach_task_self(), mach_host_self(), 0 };
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ports[2]);
    for (int p = 0; p < 3; p++) {
        unsigned otype = 0, oaddr = 0;
        kern_return_t rc = mach_port_kernel_object(mach_task_self(), ports[p], &otype, &oaddr);
        LOG("mach_port_kernel_object port=%d rc=%d obj_type=%u obj_addr=0x%x range=%d\n",
            p, rc, otype, oaddr, inRange(oaddr));
        if (inRange(oaddr)) g_hits++;
    }
    mach_port_destroy(mach_task_self(), ports[2]);
}

// Контроль: mach_vm_region_recurse по собственному адресному пространству (ожидаем KERN_SUCCESS).
static void probe_vm_region(void)
{
    mach_vm_address_t addr = 0; mach_vm_size_t size; vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt;
    natural_t depth = 0; int regions = 0;
    while (1) {
        cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t rc = mach_vm_region_recurse(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt);
        if (rc != KERN_SUCCESS) { LOG("mach_vm_region_recurse rc=%d after %d regions\n", rc, regions); return; }
        if (++regions == 1) LOG("mach_vm_region_recurse rc=0 first addr=0x%llx size=%llu depth=%u\n",
                                 (unsigned long long)addr, (unsigned long long)size, depth);
        addr += size;
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"out.txt"];
        g_out = fopen(path.fileSystemRepresentation, "w");
        if (!g_out) g_out = stderr;
        LOG("kprobe start pid=%d\n", getpid());
        for (int fl = 1; fl <= 20; fl++) probe("host_info", fl, 4096, f_host_info);
        for (int fl = 1; fl <= 20; fl++) probe("host_statistics", fl, 4096, f_host_stats);
        for (int fl = 1; fl <= 20; fl++) probe("host_statistics64", fl, 4096, f_host_stats64);
        for (int fl = 1; fl <= 20; fl++) probe("task_info", fl, 4096, f_task_info);
        for (int fl = 1; fl <= 20; fl++) probe("proc_info", fl, 4096, f_proc_info_flavors);
        for (int cn = 2; cn <= 4; cn++) {
            char nm[32]; snprintf(nm, sizeof nm, "proc_info_call%d", cn);
            for (int fl = 1; fl <= 20; fl++) probe(nm, fl, 4096, f_proc_info);
        }
        free_probe();
        for (int fl = 1; fl <= 20; fl++) probe("processor_info", fl, 16384, f_processor_info);
        probe_kobj();
        probe_vm_region();
        LOG("SUMMARY %zu kernel-range hits, %zu varying\n", g_hits, g_varying);
        if (g_out != stderr) fclose(g_out);
        exit(0);
    }
}
