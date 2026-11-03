#include "VPhoneMachPortsCompat.h"
#include "VPhoneMachPortsRPC.h"
#include <unistd.h>

// Match libsyscall/mach/task.c in XNU 12377.41.6. iOS 16's public API uses
// out-of-line port arrays, while this kernel accepts three inline descriptors.
kern_return_t vp_mach_ports_register_compat(task_t task, mach_port_array_t ports,
    mach_msg_type_number_t count) {
    if (count > 3) return KERN_INVALID_ARGUMENT;
    mach_port_t slots[3] = {MACH_PORT_NULL, MACH_PORT_NULL, MACH_PORT_NULL};
    for (mach_msg_type_number_t i = 0; i < count; i++) slots[i] = ports[i];
    return vp_mach_ports_register3(task, slots[0], slots[1], slots[2]);
}

kern_return_t vp_mach_ports_lookup_compat(task_t task, mach_port_array_t *ports,
    mach_msg_type_number_t *count) {
    vm_address_t address = 0;
    vm_size_t size = 3 * sizeof(mach_port_t);
    kern_return_t kr = vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return kr;
    mach_port_array_t slots = (mach_port_array_t)address;
    kr = vp_mach_ports_lookup3(task, &slots[0], &slots[1], &slots[2]);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), address, size);
        return kr;
    }
    *ports = slots;
    *count = 3;
    return KERN_SUCCESS;
}

#ifndef VP_MACH_PORTS_COMPAT_TEST
static int selected(void) {
    return access("/usr/lib/vphone-ios16-mach-ports", F_OK) == 0;
}
static kern_return_t vpRegister(task_t task, mach_port_array_t ports,
    mach_msg_type_number_t count) {
    return selected() ? vp_mach_ports_register_compat(task, ports, count)
                      : mach_ports_register(task, ports, count);
}
static kern_return_t vpLookup(task_t task, mach_port_array_t *ports,
    mach_msg_type_number_t *count) {
    return selected() ? vp_mach_ports_lookup_compat(task, ports, count)
                      : mach_ports_lookup(task, ports, count);
}
__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *replacee;
} vpPortsInterpose[] = {
    {(const void *)vpRegister, (const void *)mach_ports_register},
    {(const void *)vpLookup, (const void *)mach_ports_lookup},
};
#endif
