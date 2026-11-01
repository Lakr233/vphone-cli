#ifndef VPHONE_MACH_PORTS_COMPAT_H
#define VPHONE_MACH_PORTS_COMPAT_H
#include <mach/mach.h>
kern_return_t vp_mach_ports_register_compat(task_t task, mach_port_array_t ports, mach_msg_type_number_t count);
kern_return_t vp_mach_ports_lookup_compat(task_t task, mach_port_array_t *ports, mach_msg_type_number_t *count);
#endif
