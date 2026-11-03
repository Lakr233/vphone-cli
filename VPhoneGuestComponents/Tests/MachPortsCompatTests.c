#include "VPhoneMachPortsCompat.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    mach_port_t port = MACH_PORT_NULL;
    assert(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS);
    assert(mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
    assert(vp_mach_ports_register_compat(mach_task_self(), &port, 1) == KERN_SUCCESS);
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t count = 0;
    assert(vp_mach_ports_lookup_compat(mach_task_self(), &ports, &count) == KERN_SUCCESS);
    assert(count == 3 && ports[0] == port && ports[1] == MACH_PORT_NULL && ports[2] == MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), ports[0]);
    vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(*ports));
    assert(vp_mach_ports_register_compat(mach_task_self(), &port, 4) == KERN_INVALID_ARGUMENT);
    assert(vp_mach_ports_register_compat(mach_task_self(), NULL, 0) == KERN_SUCCESS);
    assert(vp_mach_ports_lookup_compat(mach_task_self(), &ports, &count) == KERN_SUCCESS);
    assert(count == 3 && !ports[0] && !ports[1] && !ports[2]);
    vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(*ports));
    mach_port_deallocate(mach_task_self(), port);
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    puts("Mach port register/lookup round-trip, empty slots and count bound passed");
    return 0;
}
